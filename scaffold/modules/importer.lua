-- modules/importer.lua
-- Wstawia wynik konwersji STS na sąsiedni track ([AI]-suffix). Pisze P_EXT
-- na source (converted=1, voice_id, seed, ...) i na output (is_output=1,
-- source_item_guid). Nigdy nie modyfikuje source itema poza P_EXT i kolorem.

local helpers = require 'modules.reaper_helpers'
local colors  = require 'modules.colors'
local config  = require 'modules.config'
local json    = require 'modules.lib.json'

local M = {}

----------------------------------------------------------------------------
-- get_or_create_output_track: znajdź zapisany albo stwórz nowy pod source.
-- Returns: (track, nil) | (nil, err_message)
--
-- Layout (config.get_output_layout()):
--   'folder' (default): source becomes I_FOLDERDEPTH=1 (parent), AI track
--     gets prev_depth-1. Outer folder enclosing source pozostaje intact —
--     nowy AI track zamyka oba poziomy gdy source był ostatni w outer folderze.
--     Abort gdy source już jest folder parentem (manual layout user'a).
--   'flat': legacy sibling layout (pre-2026-05-10).
----------------------------------------------------------------------------
function M.get_or_create_output_track(source_track)
  local _, existing_guid = reaper.GetSetMediaTrackInfo_String(
    source_track, 'P_EXT:Reasonate.output_track_guid', '', false)
  if existing_guid ~= '' then
    local tr = helpers.find_track_by_guid(existing_guid)
    if tr then return tr end
  end

  local layout = config.get_output_layout()

  -- Edge case: source już jest folder parentem (user ręcznie zorganizował) —
  -- abort, nie ruszamy manual layoutu. Tylko folder mode; flat wsadza zawsze.
  if layout == 'folder' and helpers.is_track_folder_parent(source_track) then
    return nil, 'Track is already a folder parent. Place AI track manually inside, or switch layout to "Flat" in Settings.'
  end

  local prev_depth = helpers.get_track_folder_depth(source_track)

  -- IP_TRACKNUMBER jest 1-based; InsertTrackAtIndex jest 0-based.
  -- Wartość 1-based = 0-based "po source" (czyli wsadza tuż POD source).
  local source_idx = math.floor(reaper.GetMediaTrackInfo_Value(source_track, 'IP_TRACKNUMBER'))
  reaper.InsertTrackAtIndex(source_idx, true)
  local new_track = reaper.GetTrack(0, source_idx)

  local _, source_name = reaper.GetSetMediaTrackInfo_String(source_track, 'P_NAME', '', false)
  local out_name = (source_name ~= '' and source_name or 'Track') .. ' [AI]'
  reaper.GetSetMediaTrackInfo_String(new_track, 'P_NAME', out_name, true)

  -- Track color = output (purple)
  local rgb = colors.PALETTE.output.rgb
  reaper.SetMediaTrackInfo_Value(new_track, 'I_CUSTOMCOLOR',
    reaper.ColorToNative(rgb[1], rgb[2], rgb[3]) | 0x1000000)

  if layout == 'folder' then
    -- Source opens folder, AI closes it (+ wszystkie outer levels jakie
    -- source poprzednio zamykał). Sum-preserving: source +1 → +2 delta;
    -- new_track delta = prev_depth - 1, równoważy.
    helpers.set_track_folder_depth(source_track, 1)
    helpers.set_track_folder_depth(new_track,    prev_depth - 1)
  end

  -- Save link source → output (track-level P_EXT)
  local new_guid = reaper.GetTrackGUID(new_track)
  reaper.GetSetMediaTrackInfo_String(
    source_track, 'P_EXT:Reasonate.output_track_guid', new_guid, true)

  return new_track
end

----------------------------------------------------------------------------
-- import_result: wstawia output mp3 jako item na output_track + ustawia P_EXT
--
-- conv_meta: {
--   voice_id, voice_name, model_id, seed, voice_settings_json (string),
--   conversion_time (unix, optional — default os.time())
-- }
-- Returns: new output item, output track
----------------------------------------------------------------------------
local function build_peaks(source_obj)
  if reaper.PCM_Source_BuildPeaks(source_obj, 0) > 0 then
    local safety = 1000
    while reaper.PCM_Source_BuildPeaks(source_obj, 1) > 0 and safety > 0 do
      safety = safety - 1
    end
    reaper.PCM_Source_BuildPeaks(source_obj, 2)
  end
end

local function take_name(conv_meta)
  if conv_meta.multi_take then
    -- Timestamp odróżnia kolejne iteracje (re-convert po zmianie ustawień).
    -- Dla variants w jednym batchu importy są async (sekundy odstępu) → też
    -- distinct. HH:MM:SS bo variants mogą lecieć w tej samej minucie.
    local ts = os.date('%H:%M:%S', conv_meta.conversion_time or os.time())
    return ('%s · %s'):format(conv_meta.voice_name or '?', ts)
  end
  return 'AI: ' .. (conv_meta.voice_name or '?')
end

----------------------------------------------------------------------------
-- Append-take mode (multi_take=true): dodaj kolejny take do ISTNIEJĄCEGO
-- output itema. Idempotent: jeśli output nie istnieje, fall-through do replace.
----------------------------------------------------------------------------
local function append_take_to_existing(prev_out, output_path, conv_meta)
  local new_take  = reaper.AddTakeToMediaItem(prev_out)
  local source_obj = reaper.PCM_Source_CreateFromFile(output_path)
  if not source_obj then
    error('PCM_Source_CreateFromFile failed for: ' .. output_path)
  end
  reaper.SetMediaItemTake_Source(new_take, source_obj)
  build_peaks(source_obj)
  reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME', take_name(conv_meta), true)
  -- Aktywuj ten take (REAPER pokazuje wybrany jako visible)
  reaper.SetActiveTake(new_take)
  reaper.UpdateItemInProject(prev_out)
  reaper.UpdateArrange()
  return prev_out, reaper.GetMediaItemTrack(prev_out)
end

function M.import_result(source_item, output_path, conv_meta)
  local source_track = reaper.GetMediaItemTrack(source_item)
  local source_pos   = reaper.GetMediaItemInfo_Value(source_item, 'D_POSITION')

  local output_track, layout_err = M.get_or_create_output_track(source_track)
  if not output_track then
    error(layout_err or 'failed to create output track')
  end

  -- Existing output (jeśli był poprzednio konwertowany)
  local prev_out
  do
    local _, prev_out_guid = reaper.GetSetMediaItemInfo_String(
      source_item, 'P_EXT:Reasonate.output_item_guid', '', false)
    if prev_out_guid ~= '' then
      prev_out = helpers.find_item_by_guid(prev_out_guid)
    end
  end

  -- Multi-take: dodaj take do istniejącego output zamiast usuwać
  if conv_meta.multi_take and prev_out then
    -- Update P_EXT na source itemie (latest variant info — seed itd.)
    local source_guid = helpers.item_guid(source_item)
    reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.seed',
      tostring(conv_meta.seed or 0), true)
    reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.conversion_time',
      tostring(conv_meta.conversion_time or os.time()), true)
    return append_take_to_existing(prev_out, output_path, conv_meta)
  end

  -- Replace mode: usuń stary output (single-take re-convert)
  if prev_out then
    reaper.DeleteTrackMediaItem(reaper.GetMediaItemTrack(prev_out), prev_out)
  end

  -- Stwórz item + take
  local new_item = reaper.AddMediaItemToTrack(output_track)
  local new_take = reaper.AddTakeToMediaItem(new_item)
  local source_obj = reaper.PCM_Source_CreateFromFile(output_path)
  if not source_obj then
    reaper.DeleteTrackMediaItem(output_track, new_item)
    error('PCM_Source_CreateFromFile failed for: ' .. output_path)
  end
  reaper.SetMediaItemTake_Source(new_take, source_obj)
  reaper.SetMediaItemPosition(new_item, source_pos, false)
  build_peaks(source_obj)

  -- Length: faktyczna długość mp3 (ElevenLabs może lekko zmienić)
  local out_src_len = reaper.GetMediaSourceLength(source_obj)
  reaper.SetMediaItemLength(new_item, out_src_len, false)

  reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME', take_name(conv_meta), true)

  -- Output item P_EXT
  local source_guid = helpers.item_guid(source_item)
  reaper.GetSetMediaItemInfo_String(new_item, 'P_EXT:Reasonate.is_output', '1', true)
  reaper.GetSetMediaItemInfo_String(new_item, 'P_EXT:Reasonate.source_item_guid', source_guid, true)

  -- Source item P_EXT (oznaczenie "converted" + meta)
  reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.converted',     '1', true)
  reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.voice_id',      conv_meta.voice_id   or '', true)
  reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.voice_name',    conv_meta.voice_name or '', true)
  reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.model_id',      conv_meta.model_id   or '', true)
  reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.seed',          tostring(conv_meta.seed or 0), true)
  reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.output_item_guid', helpers.item_guid(new_item), true)
  reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.original_guid', source_guid, true)
  reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.conversion_time',
    tostring(conv_meta.conversion_time or os.time()), true)

  -- Source identity (do needs_conversion w Phase 6)
  if conv_meta.source_path then
    reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.source_path',
      conv_meta.source_path, true)
  end
  if conv_meta.source_size then
    reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.source_size',
      tostring(conv_meta.source_size), true)
  end
  if conv_meta.source_length then
    reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.source_length',
      tostring(conv_meta.source_length), true)
  end

  if conv_meta.voice_settings then
    local ok, encoded = pcall(json.encode, conv_meta.voice_settings)
    if ok then
      reaper.GetSetMediaItemInfo_String(source_item, 'P_EXT:Reasonate.voice_settings',
        encoded, true)
    end
  end

  -- Recolor — source = converted (green), output = output (purple).
  -- Ich statusy z get_item_status zwrócą teraz odpowiednio.
  colors.apply_to_item(source_item, 'converted')
  colors.apply_to_item(new_item, 'output')

  reaper.UpdateItemInProject(source_item)
  reaper.UpdateItemInProject(new_item)
  reaper.UpdateArrange()

  return new_item, output_track
end

----------------------------------------------------------------------------
-- Phase 7 (2026-06-11): import pojedynczego KAWAŁKA długiego itemu (>290s).
-- Wynik = N przylegających itemów na output tracku (cięcia w ciszy, pozycje
-- 1:1 ze źródłem), zgrupowanych wspólnym I_GROUPID (user decision: kawałki
-- obok siebie, NIE glue). Bookkeeping na source P_EXT:
--   chunk_plan_hash    — hash boundaries; zmiana = stale → cleanup starych
--   output_chunk_guids — JSON map { [index_str] = guid, _group = group_id }
-- converted=1 dopiero gdy mapa kompletna (count kawałków); do tego czasu
-- needs_conversion zwraca true (check 1) — przerwany batch wznawia się
-- z cache per chunk.
----------------------------------------------------------------------------
local function next_free_group_id()
  local max_g = 0
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local g = reaper.GetMediaItemInfo_Value(reaper.GetMediaItem(0, i), 'I_GROUPID') or 0
    if g > max_g then max_g = g end
  end
  return math.floor(max_g) + 1
end

function M.import_chunk_result(source_item, output_path, conv_meta)
  local ck = conv_meta.chunk
  if not ck or not ck.index or not ck.count then
    error('import_chunk_result: missing chunk meta')
  end
  local source_track = reaper.GetMediaItemTrack(source_item)
  local source_pos   = reaper.GetMediaItemInfo_Value(source_item, 'D_POSITION')
  local output_track, layout_err = M.get_or_create_output_track(source_track)
  if not output_track then
    error(layout_err or 'failed to create output track')
  end

  local function get_src(key)
    local _, v = reaper.GetSetMediaItemInfo_String(
      source_item, 'P_EXT:Reasonate.' .. key, '', false)
    return v
  end
  local function set_src(key, val)
    reaper.GetSetMediaItemInfo_String(
      source_item, 'P_EXT:Reasonate.' .. key, val, true)
  end

  local map = {}
  do
    local raw = get_src('output_chunk_guids')
    if raw ~= '' then
      local ok, decoded = pcall(json.decode, raw)
      if ok and type(decoded) == 'table' then map = decoded end
    end
  end

  -- Plan się zmienił (source edited / pierwszy chunked convert) → sprzątnij
  -- WSZYSTKIE stare outputy (chunk itemy z mapy + ewentualny legacy single).
  if get_src('chunk_plan_hash') ~= ck.plan_hash then
    for k, guid in pairs(map) do
      if k ~= '_group' then
        local it = helpers.find_item_by_guid(guid)
        if it then reaper.DeleteTrackMediaItem(reaper.GetMediaItemTrack(it), it) end
      end
    end
    map = {}
    local prev_guid = get_src('output_item_guid')
    if prev_guid ~= '' then
      local prev = helpers.find_item_by_guid(prev_guid)
      if prev then reaper.DeleteTrackMediaItem(reaper.GetMediaItemTrack(prev), prev) end
      set_src('output_item_guid', '')
    end
    set_src('chunk_plan_hash', ck.plan_hash)
    set_src('converted', '')   -- pending aż wszystkie kawałki wylądują
  end

  local prev_chunk
  do
    local g = map[tostring(ck.index)]
    if g and g ~= '' then prev_chunk = helpers.find_item_by_guid(g) end
  end

  local new_item
  if conv_meta.multi_take and prev_chunk then
    append_take_to_existing(prev_chunk, output_path, conv_meta)
    new_item = prev_chunk
  else
    if prev_chunk then
      reaper.DeleteTrackMediaItem(reaper.GetMediaItemTrack(prev_chunk), prev_chunk)
    end
    new_item = reaper.AddMediaItemToTrack(output_track)
    local new_take = reaper.AddTakeToMediaItem(new_item)
    local source_obj = reaper.PCM_Source_CreateFromFile(output_path)
    if not source_obj then
      reaper.DeleteTrackMediaItem(output_track, new_item)
      error('PCM_Source_CreateFromFile failed for: ' .. output_path)
    end
    reaper.SetMediaItemTake_Source(new_take, source_obj)
    reaper.SetMediaItemPosition(new_item, source_pos + (ck.offset_secs or 0), false)
    build_peaks(source_obj)
    local out_src_len = reaper.GetMediaSourceLength(source_obj)
    reaper.SetMediaItemLength(new_item, out_src_len, false)
    reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME',
      ('%s (part %d/%d)'):format(take_name(conv_meta), ck.index, ck.count), true)
    local source_guid = helpers.item_guid(source_item)
    reaper.GetSetMediaItemInfo_String(new_item, 'P_EXT:Reasonate.is_output', '1', true)
    reaper.GetSetMediaItemInfo_String(new_item, 'P_EXT:Reasonate.source_item_guid', source_guid, true)
    reaper.GetSetMediaItemInfo_String(new_item, 'P_EXT:Reasonate.chunk_index', tostring(ck.index), true)
    reaper.GetSetMediaItemInfo_String(new_item, 'P_EXT:Reasonate.chunk_count', tostring(ck.count), true)
    colors.apply_to_item(new_item, 'output')
  end

  -- Wspólna grupa REAPER — kawałki przesuwają się razem.
  local group_id = tonumber(map._group)
  if not group_id then
    group_id = next_free_group_id()
    map._group = group_id
  end
  reaper.SetMediaItemInfo_Value(new_item, 'I_GROUPID', group_id)

  map[tostring(ck.index)] = helpers.item_guid(new_item)
  do
    local ok, encoded = pcall(json.encode, map)
    if ok then set_src('output_chunk_guids', encoded) end
  end

  -- Komplet kawałków → source converted + pełna meta (mirror import_result).
  local have = 0
  for k in pairs(map) do
    if k ~= '_group' then have = have + 1 end
  end
  if have >= ck.count then
    local source_guid = helpers.item_guid(source_item)
    set_src('converted', '1')
    set_src('voice_id',   conv_meta.voice_id   or '')
    set_src('voice_name', conv_meta.voice_name or '')
    set_src('model_id',   conv_meta.model_id   or '')
    set_src('seed', tostring(conv_meta.seed or 0))
    -- output_item_guid = kawałek 1 (legacy single-output konsumenci: audition
    -- ▶ AI gra od pierwszego kawałka, needs_conversion check 3).
    set_src('output_item_guid', map['1'] or '')
    set_src('original_guid', source_guid)
    set_src('conversion_time', tostring(conv_meta.conversion_time or os.time()))
    if conv_meta.source_path then set_src('source_path', conv_meta.source_path) end
    if conv_meta.source_size then set_src('source_size', tostring(conv_meta.source_size)) end
    if conv_meta.source_length then set_src('source_length', tostring(conv_meta.source_length)) end
    if conv_meta.voice_settings then
      local ok, encoded = pcall(json.encode, conv_meta.voice_settings)
      if ok then set_src('voice_settings', encoded) end
    end
    colors.apply_to_item(source_item, 'converted')
  end

  reaper.UpdateItemInProject(source_item)
  reaper.UpdateItemInProject(new_item)
  reaper.UpdateArrange()
  return new_item, output_track
end

----------------------------------------------------------------------------
-- Migration helper: convert linked source/AI sibling pairs to folder layout.
--
-- Skanuje wszystkie tracki, dla każdego z `P_EXT.output_track_guid` znajduje
-- linked AI track. Jeśli pasuje pattern (AI immediately after source, source
-- nie jest folder parentem) → set source=1, AI=ai_prev_depth-1.
--
-- enumerate_only=true → zwróć tylko liczniki bez modyfikacji (do Settings preview).
-- Returns: { migrated=N, skipped=N, already_folder=N }
----------------------------------------------------------------------------
local function find_link_pairs()
  -- Pre-build index: track_guid → (track, idx)
  local idx_by_guid = {}
  local i = 0
  for tr in helpers.iter_tracks() do
    idx_by_guid[reaper.GetTrackGUID(tr)] = { tr = tr, idx = i }
    i = i + 1
  end

  local pairs_list = {}
  for tr in helpers.iter_tracks() do
    local _, ai_guid = reaper.GetSetMediaTrackInfo_String(
      tr, 'P_EXT:Reasonate.output_track_guid', '', false)
    if ai_guid ~= '' then
      local ai_info = idx_by_guid[ai_guid]
      if ai_info then
        local src_idx = idx_by_guid[reaper.GetTrackGUID(tr)].idx
        pairs_list[#pairs_list + 1] = {
          source = tr,
          ai     = ai_info.tr,
          adjacent = (ai_info.idx == src_idx + 1),
        }
      end
    end
  end
  return pairs_list
end

function M.scan_migration(enumerate_only)
  local result = { migrated = 0, skipped = 0, already_folder = 0, total = 0 }
  local pairs_list = find_link_pairs()
  result.total = #pairs_list

  for _, p in ipairs(pairs_list) do
    local src_depth = helpers.get_track_folder_depth(p.source)
    if src_depth == 1 then
      -- Already a folder parent — assume already migrated (or user-organized)
      result.already_folder = result.already_folder + 1
    elseif not p.adjacent then
      -- AI nie jest immediately after source — user moved tracks; skip.
      result.skipped = result.skipped + 1
    else
      if not enumerate_only then
        -- Sum-preserving: source delta = (1 - src_depth); AI compensates with
        -- -(source delta) → ai_new = ai_depth - 1 + src_depth. Edge case gdy
        -- source był last w outer folderze (src_depth=-1): AI dostaje -2,
        -- zamykając INNER (właśnie otwarty) AND OUTER (był closed przez
        -- source's old -1). Bez termu src_depth outer never closes →
        -- broken project layout.
        local ai_depth = helpers.get_track_folder_depth(p.ai)
        helpers.set_track_folder_depth(p.source, 1)
        helpers.set_track_folder_depth(p.ai,     ai_depth - 1 + src_depth)
      end
      result.migrated = result.migrated + 1
    end
  end

  return result
end

function M.count_migratable()
  return M.scan_migration(true)
end

function M.migrate_to_folder_layout()
  return M.scan_migration(false)
end

return M
