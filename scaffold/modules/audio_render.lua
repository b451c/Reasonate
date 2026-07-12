-- modules/audio_render.lua
-- Faza 4: detekcja "simple item" (item == source).
-- Phase 11.x: render fallback przez AudioAccessor dla trimmed/playrate/fade —
--   non-destructive, tmp WAV w reasonate_tmp/, source plik nietknięty.
--   FX dalej rejected (zaszywanie FX w audio może zaskoczyć user'a).
-- Phase 7 (2026-06-11): itemy >290s dzielone na kawałki cięte w ciszy
--   (plan_sts_chunks + prepare_chunk_for_api; silnik = dubbing_chunker
--   z parametrami STS). Wynik importowany jako N zgrupowanych itemów.

local helpers   = require 'modules.reaper_helpers'
local accessor  = require 'modules.audio_accessor'
local util      = require 'modules.util'
local chunker   = require 'modules.dubbing_chunker'

local M = {}

local SUPPORTED_EXTS = {
  mp3 = true, wav = true, flac = true, m4a = true, ogg = true,
}

----------------------------------------------------------------------------
-- is_simple_item: czy item można wysłać DIRECT bez glue/render
-- Returns: simple (bool), source_path or nil, error_msg or nil
----------------------------------------------------------------------------
function M.is_simple_item(item)
  if not helpers.is_audio_item(item) then
    return false, nil, 'item is MIDI or has no take'
  end
  local take = reaper.GetActiveTake(item)

  if reaper.TakeFX_GetCount(take) > 0 then
    return false, nil, 'take has FX (Phase 4 supports only simple items)'
  end
  if reaper.GetMediaItemInfo_Value(item, 'D_FADEINLEN') > 0.01 then
    return false, nil, 'item has fade-in'
  end
  if reaper.GetMediaItemInfo_Value(item, 'D_FADEOUTLEN') > 0.01 then
    return false, nil, 'item has fade-out'
  end
  if reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') > 0.01 then
    return false, nil, 'take has source start offset'
  end
  if math.abs(reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') - 1.0) > 0.001 then
    return false, nil, 'take has non-1.0 playrate'
  end

  local src = reaper.GetMediaItemTake_Source(take)
  local src_len = reaper.GetMediaSourceLength(src)
  local item_len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  if math.abs(src_len - item_len) > 0.05 then
    return false, nil,
      ('item length %.2fs ≠ source length %.2fs (item is trimmed)')
        :format(item_len, src_len)
  end

  local path = reaper.GetMediaSourceFileName(src, '')
  if path == '' then
    return false, nil, 'source has no file path (in-project / generated audio)'
  end
  local ext = path:match('%.([^./\\]+)$')
  if ext then ext = ext:lower() end
  if not SUPPORTED_EXTS[ext or ''] then
    return false, nil,
      ('unsupported audio format: .%s (need mp3/wav/flac/m4a/ogg)')
        :format(ext or '?')
  end

  return true, path, nil
end

----------------------------------------------------------------------------
-- prepare_audio_for_api: zwraca ścieżkę pliku do wysłania.
--
-- Trzy ścieżki:
--   1. Simple item (== source) → direct path do source pliku
--   2. Trimmed/fade/playrate (renderable, no FX) → render via AudioAccessor
--      do tmp WAV w reasonate_tmp/, return ścieżkę do WAV
--   3. FX / inne nieobsługiwane → return nil + error
--
-- Returns: input_path (string), err (string or nil), render_info (table or nil)
--   render_info gdy rendered: { item_offs, item_length, playrate } — caller
--   używa tych pól w cache.compute_key żeby trimmed variants miały distinct
--   cache key.
----------------------------------------------------------------------------
function M.prepare_audio_for_api(item)
  local simple, path, err = M.is_simple_item(item)
  if simple then return path, nil, nil end

  -- Try AudioAccessor render fallback
  local renderable, rerr = accessor.is_renderable(item)
  if not renderable then
    -- Surface BOTH errors — pierwsza (is_simple_item) wskazuje co było wrong,
    -- druga (is_renderable) dlaczego nie możemy renderować
    return nil, err .. ' (cannot auto-render: ' .. tostring(rerr) .. ')'
  end

  local render_path = accessor.cache_path_for(item)
  if not render_path then return nil, 'cannot compute render cache path' end

  -- Cache hit (same item geometry + source identity = same hash)
  if not util.file_exists(render_path) or (util.file_size(render_path) or 0) < 100 then
    local rok, rerr2 = accessor.render_visible_to_wav(item, render_path)
    if not rok then return nil, 'render failed: ' .. tostring(rerr2) end
  end

  local take = reaper.GetActiveTake(item)
  return render_path, nil, {
    item_offs   = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0,
    item_length = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0,
    playrate    = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1,
  }
end

----------------------------------------------------------------------------
-- Length validation (STS limit 300s, używamy 290s margin)
----------------------------------------------------------------------------
local STS_MAX_SECONDS = 290

function M.item_too_long(item)
  local len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  if len > STS_MAX_SECONDS then
    return true, len, ('item is %.1fs > %ds STS limit'):format(len, STS_MAX_SECONDS)
  end
  return false, len, nil
end

----------------------------------------------------------------------------
-- Phase 7: chunked STS dla itemów >290s.
--
-- Plan: silence-aware cuts via dubbing_chunker z parametrami STS —
-- safe 265s + search ±25s daje twardy max 290s na kawałek (STS limit 300s
-- z marginesem). Boundaries deterministyczne per source → te same ścieżki
-- WAV i klucze cache przy ponownym Convert (przerwany batch wznawia się
-- z cache za darmo).
----------------------------------------------------------------------------
M.STS_CHUNK_OPTS = {
  target_secs      = STS_MAX_SECONDS,
  safe_secs        = 265,
  search_secs      = 25,    -- safe + search ≤ STS_MAX (twardy limit per chunk)
  min_silence_secs = 0.35,
  min_chunk_secs   = 60,
  subdir           = 'vr_chunks',
  force_mono       = true,  -- połowa rozmiaru uploadu; output STS i tak mono
}
local STS_CHUNK_OPTS = M.STS_CHUNK_OPTS

-- Deterministyczny namespace per source identity + widoczna geometria —
-- kopie itemu (ten sam plik/region) współdzielą render cache.
local function chunk_namespace(item)
  local take = reaper.GetActiveTake(item)
  local info = helpers.item_source_info(item)
  local offs = take and reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
  local len  = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
  local key  = ('%s|%d|%.3f|%.3f'):format(
    info and info.path or '?', info and info.size or 0, offs, len)
  return ('%08x'):format(util.simple_hash(key))
end

-- plan_sts_chunks(item) → chunks[], err. Każdy chunk dostaje offset_secs
-- (timeline offset względem początku itemu; playrate=1 wymuszony w M1 —
-- mirror ograniczenia dubbing_chunker, patrz KNOWN-ISSUES).
function M.plan_sts_chunks(item)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil, 'no audio take' end
  local playrate = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1.0
  if math.abs(playrate - 1.0) > 0.001 then
    return nil, 'long items with playrate != 1.0 not supported yet (reset rate or split manually)'
  end
  if reaper.TakeFX_GetCount(take) > 0 then
    return nil, 'long items with take FX not supported (render/bypass FX first)'
  end
  local item_offs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
  local chunks, err = chunker.plan_chunks(item, chunk_namespace(item), STS_CHUNK_OPTS)
  if not chunks then return nil, err end
  for _, ch in ipairs(chunks) do
    ch.offset_secs = ch.t_start_in_src - item_offs
  end
  return chunks, nil
end

-- Hash planu cięć — wykrywa zmianę boundaries (source edited / re-trim).
-- Importer czyści stare chunk itemy gdy hash się różni.
function M.chunk_plan_hash(chunks)
  local parts = {}
  for _, ch in ipairs(chunks) do
    parts[#parts + 1] = ('%.3f-%.3f'):format(ch.t_start_in_src, ch.t_end_in_src)
  end
  return ('%08x'):format(util.simple_hash(table.concat(parts, '|')))
end

-- Render kawałka do mono WAV (idempotent — render_chunk skipuje istniejący
-- plik). Returns (input_path, err, render_info) — render_info mirror
-- prepare_audio_for_api (foldowany do cache key per chunk).
function M.prepare_chunk_for_api(item, chunk)
  local ok, err = chunker.render_chunk(item, chunk, STS_CHUNK_OPTS)
  if not ok then return nil, ('chunk %d render: %s'):format(chunk.idx, tostring(err)) end
  return chunk.output_path, nil, {
    item_offs   = chunk.t_start_in_src,
    item_length = chunk.duration,
    playrate    = 1.0,
  }
end

return M
