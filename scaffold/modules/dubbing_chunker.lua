-- modules/dubbing_chunker.lua
-- NS-B M1 Part 2 — auto-chunk long source audio dla Scribe diarize (8min limit).
-- Phase 7 (2026-06-11): sparametryzowany przez opts — Voice Replacement reuse'uje
-- planning/render dla STS >290s split (inne targety, mono, własny subdir).
-- Brak opts = zachowanie dubbingowe bajt-w-bajt.
--
-- Strategy: render source via AudioAccessor → scan amplitude → find silence
-- candidates near target chunk boundaries → cut at silences (or hard cut on
-- fallback). Output: per-chunk PCM WAV w reasonate_tmp/dub_chunks/<project_guid>/
-- chunk_<idx>.wav.
--
-- Why AudioAccessor (read-only): respect invariant #2 source nigdy nie modyfikowany
-- — chunker DECODE's source, NIE używa SplitMediaItem na source itemach.
-- Output WAVs używane TYLKO do STT upload, NIE są inserted na REAPER timeline.
--
-- Boundary algorithm (per spec §10.2 + Flow A point 5):
--   target_chunk_secs = 480  (Scribe diarize hard limit per provider docs)
--   safe_chunk_secs   = 450  (leave 30s margin dla speech crossing boundary)
--   silence_search    = 60   (look 60s before/after target → find quiet gap)
--   silence_thresh    = 0.012 (~-38dB linear; below = silence; mirror splice.lua)
--   min_silence_dur   = 1.0  (must be ≥1s of contiguous silence to qualify)
--
-- Fallback: jeśli żaden silence w window → hard cut na safe_chunk_secs.

local util     = require 'modules.util'
local accessor = require 'modules.audio_accessor'

local M = {}

----------------------------------------------------------------------------
-- Tunables (exposed dla testing/tweaking, NIE config — internal constants)
----------------------------------------------------------------------------
M.TARGET_CHUNK_SECS  = 480     -- Scribe diarize 8min hard limit
M.SAFE_CHUNK_SECS    = 420     -- target boundary; W2 M1 fix: 450 + search 60
                               -- dawało kawałek do 510s > limit Scribe 480
                               -- (latentne od NS-B M1, KNOWN-ISSUES) —
                               -- safe+search MUSI być ≤ TARGET (test guard)
M.SILENCE_SEARCH     = 60      -- look ±60s for silence near target
M.SILENCE_THRESHOLD  = 0.012   -- linear, ~-38dB
M.MIN_SILENCE_SECS   = 1.0     -- must be ≥1s silence gap
M.PEAK_RATE          = 100     -- 100Hz scan = 10ms resolution (cheap)

local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

local function chunks_root(project_guid, subdir)
  local p = tmp_dir() .. path_sep() .. (subdir or 'dub_chunks')
            .. path_sep() .. (project_guid or 'unknown')
  util.mkdir_p(p)
  return p
end

----------------------------------------------------------------------------
-- Resolve source audio for given REAPER item (active take only — Dubbing
-- NIE supportuje multi-take source items). Returns (path, source_obj, t0_in_src,
-- duration_secs) lub (nil, err).
--
-- Item-relative window używamy bo source plik może być longer than visible item
-- region (REAPER trim/section). User-selected item dyktuje co transcribujemy.
----------------------------------------------------------------------------
local function open_item_audio(item)
  if not item then return nil, 'nil item' end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil, 'no audio take' end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil, 'no source' end
  local item_len  = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
  local item_offs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
  local playrate  = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1.0
  if playrate <= 0 then playrate = 1.0 end
  -- "Visible" source span: source-time = [item_offs .. item_offs + item_len*playrate]
  local span = item_len * playrate
  if span <= 0 then return nil, 'zero visible span' end
  return src, item_offs, span, take
end

----------------------------------------------------------------------------
-- Scan amplitude w window [t0, t1] z source. Buffer layout per PCM_Source_GetPeaks:
-- buf[0 .. n*nch-1] = MAX peaks, buf[n*nch .. 2*n*nch-1] = MIN peaks.
-- Returns table of amplitude values (one per peak slot, max(|max|, |min|) per slot)
-- indexed 1-based. Size = n samples (NOT n*nch — pre-mixed do mono).
----------------------------------------------------------------------------
local function scan_amplitude(src, t0, t1, peak_rate)
  peak_rate = peak_rate or M.PEAK_RATE
  local nch = (reaper.GetMediaSourceNumChannels and reaper.GetMediaSourceNumChannels(src)) or 1
  if nch <= 0 then nch = 1 end
  local dur = t1 - t0
  if dur <= 0 then return {} end
  local n = math.floor(dur * peak_rate + 0.5)
  if n <= 0 then return {} end
  local buf = reaper.new_array(n * nch * 2)
  buf.clear()
  local rv = reaper.PCM_Source_GetPeaks(src, peak_rate, t0, nch, n, 0, buf)
  if not rv or rv == 0 then return nil end  -- caller fallback
  local out = {}
  local max_off = 0
  local min_off = n * nch
  for i = 0, n - 1 do
    local max_a = 0
    for c = 0, nch - 1 do
      local mx = math.abs(buf[1 + max_off + i * nch + c] or 0)
      local mn = math.abs(buf[1 + min_off + i * nch + c] or 0)
      if mx > max_a then max_a = mx end
      if mn > max_a then max_a = mn end
    end
    out[i + 1] = max_a
  end
  return out, peak_rate
end

----------------------------------------------------------------------------
-- Find best silence cut point near target_t. Strategy:
-- 1. Scan [target_t - SILENCE_SEARCH, target_t + SILENCE_SEARCH].
-- 2. Find contiguous runs where amplitude < SILENCE_THRESHOLD for ≥MIN_SILENCE_SECS.
-- 3. Pick run with center closest to target_t.
-- 4. Cut point = center of that run.
-- 5. No qualifying run → return target_t (hard cut fallback).
--
-- t_source_lo + t_source_hi = absolute clip bounds we can't exceed.
----------------------------------------------------------------------------
-- Pure core (Phase 7: wydzielone z find_silence_cut dla headless testów):
-- amps = tablica amplitud (1-based, peak_rate próbek/s, start = search_lo).
-- Zwraca center_t najlepszego silent runa (najbliżej target_t) albo nil.
function M.pick_silence_run(amps, peak_rate, search_lo, target_t, threshold, min_silence_secs)
  if not amps or #amps == 0 then return nil end
  local min_run_samples = math.floor(min_silence_secs * peak_rate)
  local best_center = nil
  local best_dist = math.huge
  local run_start = nil
  for i = 1, #amps do
    if amps[i] < threshold then
      if not run_start then run_start = i end
    else
      if run_start and (i - run_start) >= min_run_samples then
        local center = run_start + (i - run_start) * 0.5
        local center_t = search_lo + center / peak_rate
        local dist = math.abs(center_t - target_t)
        if dist < best_dist then
          best_dist = dist
          best_center = center_t
        end
      end
      run_start = nil
    end
  end
  -- Trailing run check
  if run_start and (#amps - run_start + 1) >= min_run_samples then
    local center = run_start + (#amps - run_start) * 0.5
    local center_t = search_lo + center / peak_rate
    local dist = math.abs(center_t - target_t)
    if dist < best_dist then
      best_center = center_t
    end
  end
  return best_center
end

local function find_silence_cut(src, target_t, t_source_lo, t_source_hi, opts)
  opts = opts or {}
  local search      = opts.search_secs      or M.SILENCE_SEARCH
  local threshold   = opts.silence_threshold or M.SILENCE_THRESHOLD
  local min_silence = opts.min_silence_secs or M.MIN_SILENCE_SECS
  local search_lo = math.max(t_source_lo, target_t - search)
  local search_hi = math.min(t_source_hi, target_t + search)
  if search_hi - search_lo < min_silence then
    return target_t, false   -- not enough room
  end
  local amps, peak_rate = scan_amplitude(src, search_lo, search_hi, M.PEAK_RATE)
  if not amps or #amps == 0 then
    return target_t, false   -- peaks unavailable → hard cut
  end
  local best_center = M.pick_silence_run(amps, peak_rate, search_lo, target_t,
    threshold, min_silence)
  if best_center then
    return best_center, true   -- found silence cut
  end
  return target_t, false       -- fallback hard cut
end

----------------------------------------------------------------------------
-- Render source region [t_start_in_src .. t_end_in_src] do 16-bit PCM WAV.
-- Re-uses audio_accessor.render_visible_to_wav helper'a — ale ten activates
-- on whole take. Tutaj musimy render arbitrary region z source, więc używamy
-- bezpośrednio AudioAccessor API jak audio_accessor robi, ale z custom bounds.
--
-- Output path: caller-provided. Returns (ok, err).
----------------------------------------------------------------------------
local function render_region_to_wav(take, t_start_in_src, t_end_in_src, output_path, force_mono)
  if not take then return false, 'nil take' end
  if t_end_in_src <= t_start_in_src then return false, 'zero duration' end

  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return false, 'no source' end
  local sr  = reaper.GetMediaSourceSampleRate(src)
  local nch = reaper.GetMediaSourceNumChannels(src)
  if not sr or sr <= 0 then return false, 'invalid sample rate' end
  if not nch or nch <= 0 then return false, 'invalid channel count' end
  -- Phase 7: STS upload — mono downmix (GetAudioAccessorSamples miesza do
  -- żądanej liczby kanałów). Połowa rozmiaru pliku; output STS i tak mono.
  if force_mono then nch = 1 end

  local accessor_obj = reaper.CreateTakeAudioAccessor(take)
  if not accessor_obj then return false, 'CreateTakeAudioAccessor failed' end

  -- AudioAccessor coords = item timeline, ALE jego start time = item position
  -- + (item_offs effective). Najprościej: użyjmy source-relative t_start/t_end
  -- minus item_offs jako accessor-time offset. Take playrate translation:
  -- accessor_t = (source_t - item_offs) / playrate + accessor_start_time.
  --
  -- For Dubbing chunker — zakładamy playrate=1.0 (typical dla long source mixed
  -- file; chunker tylko dla mixed long sources, nie dla pitch-shifted material).
  -- Jeśli playrate != 1, user dostanie zniekształcony chunk content — known
  -- limitation, document w KNOWN-ISSUES.
  local item_offs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
  local accessor_start = reaper.GetAudioAccessorStartTime(accessor_obj)
  local accessor_end   = reaper.GetAudioAccessorEndTime(accessor_obj)

  local t_offset = accessor_start - item_offs
  local read_t0 = t_start_in_src + t_offset
  local read_t1 = t_end_in_src + t_offset
  if read_t0 < accessor_start - 0.001 then read_t0 = accessor_start end
  if read_t1 > accessor_end + 0.001 then read_t1 = accessor_end end
  local duration = read_t1 - read_t0
  if duration <= 0 then
    reaper.DestroyAudioAccessor(accessor_obj)
    return false, 'zero accessor duration for chunk'
  end
  local total_frames = math.floor(duration * sr + 0.5)
  if total_frames <= 0 then
    reaper.DestroyAudioAccessor(accessor_obj)
    return false, 'zero frames'
  end

  util.mkdir_p(tmp_dir())
  local f, oerr = io.open(output_path, 'wb')
  if not f then
    reaper.DestroyAudioAccessor(accessor_obj)
    return false, 'cannot open output: ' .. tostring(oerr)
  end

  -- WAV header (16-bit PCM)
  local function pack_le_u32(v) return string.pack('<I4', v) end
  local function pack_le_u16(v) return string.pack('<I2', v) end
  local bits_per_sample  = 16
  local bytes_per_sample = 2
  local block_align      = nch * bytes_per_sample
  local byte_rate        = sr * block_align
  local data_size        = total_frames * block_align
  f:write('RIFF', pack_le_u32(36 + data_size), 'WAVE',
          'fmt ', pack_le_u32(16), pack_le_u16(1), pack_le_u16(nch),
          pack_le_u32(sr), pack_le_u32(byte_rate),
          pack_le_u16(block_align), pack_le_u16(bits_per_sample),
          'data', pack_le_u32(data_size))

  -- Stream samples w 1s chunks (compromise memory/calls).
  local CHUNK_SECS = 1.0
  local frames_per_chunk = math.min(total_frames, math.floor(sr * CHUNK_SECS))
  local buf = reaper.new_array(frames_per_chunk * nch)
  local frames_done = 0
  local err_msg = nil

  -- Sub-pack int16 (mirror audio_accessor pattern but inline — chunker independent module)
  local function int16_pack(arr, n_total_samples)
    local parts = {}
    local SUBCHUNK = 4096
    local fmt_full = '<' .. string.rep('h', SUBCHUNK)
    local i = 1
    while i <= n_total_samples do
      local n_this = math.min(SUBCHUNK, n_total_samples - i + 1)
      local ints = {}
      for k = 0, n_this - 1 do
        local s = arr[i + k] or 0
        if s >  1.0 then s =  1.0 end
        if s < -1.0 then s = -1.0 end
        local v = math.floor(s * 32767 + (s >= 0 and 0.5 or -0.5))
        if v >  32767 then v =  32767 end
        if v < -32768 then v = -32768 end
        ints[k + 1] = v
      end
      if n_this == SUBCHUNK then
        parts[#parts + 1] = string.pack(fmt_full, table.unpack(ints))
      else
        parts[#parts + 1] = string.pack('<' .. string.rep('h', n_this), table.unpack(ints))
      end
      i = i + n_this
    end
    return table.concat(parts)
  end

  while frames_done < total_frames do
    local frames_left = total_frames - frames_done
    local frames_this = math.min(frames_per_chunk, frames_left)
    local samples_this = frames_this * nch
    local t_pos = read_t0 + frames_done / sr
    buf.clear()
    local rv = reaper.GetAudioAccessorSamples(accessor_obj, sr, nch, t_pos, frames_this, buf)
    if rv == -1 then
      err_msg = 'GetAudioAccessorSamples returned -1'
      break
    end
    f:write(int16_pack(buf, samples_this))
    frames_done = frames_done + frames_this
  end

  reaper.DestroyAudioAccessor(accessor_obj)
  f:close()

  if err_msg then
    os.remove(output_path)
    return false, err_msg
  end
  return true, nil
end

----------------------------------------------------------------------------
-- Public: plan_chunks(item, project_guid)
--
-- Returns chunks_plan = [{idx, t_start_in_src, t_end_in_src, output_path, duration}].
-- t_start/end_in_src = source-relative seconds (compatible z STT word.start/end
-- post-merge — chunker stores OFFSET dodatkowo żeby merger w speaker_match
-- mógł skonwertować chunk-local timestamps na global source timeline).
--
-- Single-chunk return gdy span ≤ TARGET_CHUNK_SECS (chunker stays out of way).
-- Multi-chunk return gdy span > TARGET_CHUNK_SECS — silence-aware cuts.
----------------------------------------------------------------------------
function M.plan_chunks(item, project_guid, opts)
  opts = opts or {}
  local target_secs    = opts.target_secs    or M.TARGET_CHUNK_SECS
  local safe_secs      = opts.safe_secs      or M.SAFE_CHUNK_SECS
  local min_chunk_secs = opts.min_chunk_secs or 60
  local src, item_offs, span, take = open_item_audio(item)
  if not src then return nil, item_offs end  -- item_offs == err msg w fail path
  local source_lo = item_offs
  local source_hi = item_offs + span
  local root = chunks_root(project_guid, opts.subdir)

  -- Single chunk path
  if span <= target_secs then
    return {
      {
        idx              = 1,
        t_start_in_src   = source_lo,
        t_end_in_src     = source_hi,
        output_path      = root .. path_sep() .. ('chunk_001.wav'),
        duration         = span,
        is_only_chunk    = true,
      }
    }, nil
  end

  -- Multi-chunk path
  local chunks = {}
  local cursor = source_lo
  local idx = 0
  while cursor < source_hi - 0.1 do
    idx = idx + 1
    local target = cursor + safe_secs
    local t_end
    local found_silence = false
    if target >= source_hi then
      t_end = source_hi
    else
      local cut_t, ok = find_silence_cut(src, target, cursor + min_chunk_secs, source_hi, opts)
      t_end = cut_t
      found_silence = ok
    end
    if t_end <= cursor + 0.1 then
      -- Defensive: prevent zero-length chunks (find_silence_cut bug or extreme edge)
      t_end = math.min(cursor + safe_secs, source_hi)
    end
    chunks[#chunks + 1] = {
      idx              = idx,
      t_start_in_src   = cursor,
      t_end_in_src     = t_end,
      output_path      = root .. path_sep() .. ('chunk_%03d.wav'):format(idx),
      duration         = t_end - cursor,
      found_silence    = found_silence,
    }
    cursor = t_end
  end
  return chunks, nil
end

----------------------------------------------------------------------------
-- Public: render_chunk(item, chunk_plan_entry) → ok, err
--
-- Renders single chunk WAV per plan entry. Re-uses item's take (so playrate /
-- AudioAccessor coordination respected). Idempotent — skips render gdy output
-- file exists z reasonable size (>1KB sanity check).
----------------------------------------------------------------------------
function M.render_chunk(item, chunk, opts)
  if not item or not chunk then return false, 'nil args' end
  if not chunk.output_path then return false, 'no output path' end
  if util.file_exists(chunk.output_path) and (util.file_size(chunk.output_path) or 0) > 1024 then
    return true, nil  -- cache hit
  end
  local _, _, _, take = open_item_audio(item)
  if not take then return false, 'no take' end
  return render_region_to_wav(take, chunk.t_start_in_src, chunk.t_end_in_src,
    chunk.output_path, opts and opts.force_mono)
end

----------------------------------------------------------------------------
-- Public: chunks_root_for(project_guid) — exposed dla cleanup helpers.
----------------------------------------------------------------------------
function M.chunks_root_for(project_guid)
  return chunks_root(project_guid)
end

return M
