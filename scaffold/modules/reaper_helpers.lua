-- modules/reaper_helpers.lua
-- Jedyny moduł który dotyka REAPER API bezpośrednio (poza GUI + colors.lua,
-- który ma własne uzasadnienie — koloruje I_CUSTOMCOLOR).
--
-- Faza 1: track iteration + P_EXT helpers.
-- Faza 2: item iteration + status detection (P_EXT-based).

local json = require 'modules.lib.json'

local M = {}

----------------------------------------------------------------------------
-- Voice settings defaults (z CLAUDE.md / docs/03)
----------------------------------------------------------------------------
local DEFAULT_VOICE_SETTINGS = {
  stability         = 0.5,
  similarity_boost  = 0.75,
  style             = 0.0,
  use_speaker_boost = true,
  speed             = 1.0,  -- ElevenLabs voice_settings.speed (v2/turbo/multilingual);
                            -- REST API range 0.25-4.0, safe zone 0.7-1.2 (Agents cap),
                            -- Flash bypasses speed for performance. Default 1.0 = native rate.
}

function M.default_voice_settings()
  return {
    stability         = DEFAULT_VOICE_SETTINGS.stability,
    similarity_boost  = DEFAULT_VOICE_SETTINGS.similarity_boost,
    style             = DEFAULT_VOICE_SETTINGS.style,
    use_speaker_boost = DEFAULT_VOICE_SETTINGS.use_speaker_boost,
    speed             = DEFAULT_VOICE_SETTINGS.speed,
  }
end

----------------------------------------------------------------------------
-- P_EXT keys
-- 2026-05-10: namespace ReaCast → Reasonate. Legacy keys w P_EXT:ReaCast.*
-- są transparentnie migrowane przy odczycie (lazy: gdy nowy klucz pusty
-- a stary niepusty → kopiujemy do nowego, czyścimy stary).
----------------------------------------------------------------------------
local PEXT_NS     = 'Reasonate'
local PEXT_NS_OLD = 'ReaCast'

local function pext_key(suffix)     return 'P_EXT:' .. PEXT_NS     .. '.' .. suffix end
local function pext_key_old(suffix) return 'P_EXT:' .. PEXT_NS_OLD .. '.' .. suffix end

-- Track-level
local KEY_TRACK_VOICE_ID   = pext_key('voice_id')
local KEY_TRACK_VOICE_NAME = pext_key('voice_name')
local KEY_TRACK_ROLE       = pext_key('role')

-- Item-level (faza 2 czyta tylko; pisać będą fazy 4-5)
local KEY_ITEM_CONVERTED   = pext_key('converted')
local KEY_ITEM_ERROR       = pext_key('error')
local KEY_ITEM_IS_OUTPUT   = pext_key('is_output')

----------------------------------------------------------------------------
-- Internal helpers — z lazy migration ReaCast → Reasonate.
-- Reading: jeśli new pusty, sprawdzamy old; znajdziemy → kopiujemy do new
-- + czyścimy old. Nigdy nie tracimy danych. Po pełnej migracji projektu
-- old keys znikają samodzielnie.
----------------------------------------------------------------------------
local function track_pext_suffix(key)
  -- key = 'P_EXT:Reasonate.voice_id' → 'voice_id'
  return key:match('^P_EXT:[^%.]+%.(.+)$')
end

local function get_track_string(tr, key)
  local _, val = reaper.GetSetMediaTrackInfo_String(tr, key, '', false)
  if val ~= '' then return val end
  -- Try legacy namespace as fallback + migrate
  local suffix = track_pext_suffix(key)
  if suffix then
    local _, old_val = reaper.GetSetMediaTrackInfo_String(tr, pext_key_old(suffix), '', false)
    if old_val ~= '' then
      reaper.GetSetMediaTrackInfo_String(tr, key, old_val, true)
      reaper.GetSetMediaTrackInfo_String(tr, pext_key_old(suffix), '', true)
      return old_val
    end
  end
  return val
end

local function set_track_string(tr, key, val)
  reaper.GetSetMediaTrackInfo_String(tr, key, val or '', true)
end

local function get_item_string(item, key)
  local _, val = reaper.GetSetMediaItemInfo_String(item, key, '', false)
  if val ~= '' then return val end
  local suffix = track_pext_suffix(key)
  if suffix then
    local _, old_val = reaper.GetSetMediaItemInfo_String(item, pext_key_old(suffix), '', false)
    if old_val ~= '' then
      reaper.GetSetMediaItemInfo_String(item, key, old_val, true)
      reaper.GetSetMediaItemInfo_String(item, pext_key_old(suffix), '', true)
      return old_val
    end
  end
  return val
end

-- Public helpers dla innych modułów które wcześniej miały inline P_EXT access.
function M.pext_track_get(tr, suffix)
  return get_track_string(tr, pext_key(suffix))
end
function M.pext_track_set(tr, suffix, val)
  set_track_string(tr, pext_key(suffix), val)
end
function M.pext_item_get(item, suffix)
  return get_item_string(item, pext_key(suffix))
end
function M.pext_item_set(item, suffix, val)
  reaper.GetSetMediaItemInfo_String(item, pext_key(suffix), val or '', true)
end

----------------------------------------------------------------------------
-- Track iteration & info
----------------------------------------------------------------------------
function M.iter_tracks()
  local i = -1
  local n = reaper.CountTracks(0)
  return function()
    i = i + 1
    if i >= n then return nil end
    return reaper.GetTrack(0, i)
  end
end

function M.track_index(tr)
  return math.floor(reaper.GetMediaTrackInfo_Value(tr, 'IP_TRACKNUMBER'))
end

function M.track_name(tr)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
  return name
end

function M.set_track_name(tr, name)
  reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', name or '', true)
end

function M.track_guid(tr)
  return reaper.GetTrackGUID(tr)
end

-- Folder depth: 1 = parent (opens), 0 = sibling, -N = closes N levels.
function M.get_track_folder_depth(tr)
  return math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH'))
end

function M.set_track_folder_depth(tr, d)
  reaper.SetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH', d)
end

function M.is_track_folder_parent(tr)
  return M.get_track_folder_depth(tr) == 1
end

function M.track_item_count(tr)
  return reaper.CountTrackMediaItems(tr)
end

----------------------------------------------------------------------------
-- Track-level voice mapping (P_EXT)
----------------------------------------------------------------------------
function M.get_track_voice(tr)
  local id   = get_track_string(tr, KEY_TRACK_VOICE_ID)
  local name = get_track_string(tr, KEY_TRACK_VOICE_NAME)
  if id == '' then id = nil end
  if name == '' then name = nil end
  return id, name
end

function M.set_track_voice(tr, voice_id, voice_name)
  set_track_string(tr, KEY_TRACK_VOICE_ID,   voice_id   or '')
  set_track_string(tr, KEY_TRACK_VOICE_NAME, voice_name or '')
end

function M.clear_track_voice(tr)
  set_track_string(tr, KEY_TRACK_VOICE_ID,   '')
  set_track_string(tr, KEY_TRACK_VOICE_NAME, '')
end

function M.get_track_role(tr)
  local r = get_track_string(tr, KEY_TRACK_ROLE)
  if r == '' then return nil end
  return r
end

function M.set_track_role(tr, role)
  set_track_string(tr, KEY_TRACK_ROLE, role or '')
end

----------------------------------------------------------------------------
-- Phase 11 (Dialog Repair): voice clone fields per track.
-- Independent od voice_id (track może mieć cast voice_id + auto IVC clone).
-- Resolution preference: track_voice → clone → none (patrz voice_clone.lua).
----------------------------------------------------------------------------
local KEY_TRACK_VOICE_CLONE_ID            = 'P_EXT:Reasonate.voice_clone_id'
local KEY_TRACK_VOICE_CLONE_CREATED_AT    = 'P_EXT:Reasonate.voice_clone_created_at'
local KEY_TRACK_VOICE_CLONE_SOURCE_PATH   = 'P_EXT:Reasonate.voice_clone_source_path'
local KEY_TRACK_VOICE_CLONE_FALLBACK_ID   = 'P_EXT:Reasonate.voice_clone_fallback_id'
local KEY_TRACK_VOICE_CLONE_FALLBACK_NAME = 'P_EXT:Reasonate.voice_clone_fallback_name'

function M.get_track_voice_clone(tr)
  local id   = get_track_string(tr, KEY_TRACK_VOICE_CLONE_ID)
  local at   = get_track_string(tr, KEY_TRACK_VOICE_CLONE_CREATED_AT)
  local src  = get_track_string(tr, KEY_TRACK_VOICE_CLONE_SOURCE_PATH)
  if id == '' then return nil end
  return { voice_id = id, created_at = tonumber(at), source_path = src }
end

function M.set_track_voice_clone(tr, voice_id, source_path)
  set_track_string(tr, KEY_TRACK_VOICE_CLONE_ID,          voice_id    or '')
  set_track_string(tr, KEY_TRACK_VOICE_CLONE_CREATED_AT,  tostring(os.time()))
  set_track_string(tr, KEY_TRACK_VOICE_CLONE_SOURCE_PATH, source_path or '')
end

function M.clear_track_voice_clone(tr)
  set_track_string(tr, KEY_TRACK_VOICE_CLONE_ID,          '')
  set_track_string(tr, KEY_TRACK_VOICE_CLONE_CREATED_AT,  '')
  set_track_string(tr, KEY_TRACK_VOICE_CLONE_SOURCE_PATH, '')
end

function M.get_track_voice_clone_fallback(tr)
  local id   = get_track_string(tr, KEY_TRACK_VOICE_CLONE_FALLBACK_ID)
  local name = get_track_string(tr, KEY_TRACK_VOICE_CLONE_FALLBACK_NAME)
  if id == '' then return nil end
  return { voice_id = id, name = name }
end

function M.set_track_voice_clone_fallback(tr, voice_id, name)
  set_track_string(tr, KEY_TRACK_VOICE_CLONE_FALLBACK_ID,   voice_id or '')
  set_track_string(tr, KEY_TRACK_VOICE_CLONE_FALLBACK_NAME, name     or '')
end

----------------------------------------------------------------------------
-- Per-track voice settings (override defaults). nil = use defaults.
----------------------------------------------------------------------------
local KEY_TRACK_VOICE_SETTINGS = 'P_EXT:Reasonate.voice_settings'

function M.get_track_voice_settings(tr)
  local raw = get_track_string(tr, KEY_TRACK_VOICE_SETTINGS)
  if raw == '' then return nil end
  local ok, decoded = pcall(json.decode, raw)
  if ok and type(decoded) == 'table' then return decoded end
  return nil
end

function M.set_track_voice_settings(tr, settings)
  if not settings then
    set_track_string(tr, KEY_TRACK_VOICE_SETTINGS, '')
    return
  end
  set_track_string(tr, KEY_TRACK_VOICE_SETTINGS, json.encode(settings))
end

-- Effective settings = override (jeśli ustawiony) lub defaults.
function M.effective_voice_settings(tr)
  local override = M.get_track_voice_settings(tr)
  if override then
    return {
      stability         = override.stability         or DEFAULT_VOICE_SETTINGS.stability,
      similarity_boost  = override.similarity_boost  or DEFAULT_VOICE_SETTINGS.similarity_boost,
      style             = override.style             or DEFAULT_VOICE_SETTINGS.style,
      use_speaker_boost = override.use_speaker_boost ~= false,  -- default true
      speed             = override.speed             or DEFAULT_VOICE_SETTINGS.speed,
    }
  end
  return M.default_voice_settings()
end

-- Numerical equality (~ε=0.001) — uniknięcie różnic encoding/order.
function M.settings_equal(a, b)
  local A = a or DEFAULT_VOICE_SETTINGS
  local B = b or DEFAULT_VOICE_SETTINGS
  if math.abs((A.stability or 0.5) - (B.stability or 0.5)) > 0.001 then return false end
  if math.abs((A.similarity_boost or 0.75) - (B.similarity_boost or 0.75)) > 0.001 then return false end
  if math.abs((A.style or 0) - (B.style or 0)) > 0.001 then return false end
  if math.abs((A.speed or 1.0) - (B.speed or 1.0)) > 0.001 then return false end
  local a_boost = A.use_speaker_boost ~= false
  local b_boost = B.use_speaker_boost ~= false
  if a_boost ~= b_boost then return false end
  return true
end

----------------------------------------------------------------------------
-- NS-C: per-track Voice Isolator flag.
-- '1' = pre-process audio przez /v1/audio-isolation przed wysyłką do
-- Convert / STT / IVC clone training. Default '' (=off).
----------------------------------------------------------------------------
local KEY_TRACK_ISOLATE = 'P_EXT:Reasonate.isolate_audio'

function M.get_track_isolate_flag(tr)
  if not tr then return false end
  return get_track_string(tr, KEY_TRACK_ISOLATE) == '1'
end

function M.set_track_isolate_flag(tr, enabled)
  set_track_string(tr, KEY_TRACK_ISOLATE, enabled and '1' or '')
end

----------------------------------------------------------------------------
-- Per-item user color override (Phase 11.x redesign).
-- Flaga P_EXT:Reasonate.user_color = '1' znaczy "user wybrał kolor manualnie" —
-- state.lua auto-kolorowanie statusu szanuje flagę i NIE nadpisuje
-- I_CUSTOMCOLOR. Brak flagi → auto-status palette (stary behavior).
----------------------------------------------------------------------------
local PEXT_USER_COLOR = 'P_EXT:Reasonate.user_color'

function M.get_item_user_color_flag(item)
  if not item then return false end
  local _, v = reaper.GetSetMediaItemInfo_String(item, PEXT_USER_COLOR, '', false)
  return v == '1'
end

function M.set_item_user_color(item, native)
  if not item or not native or native == 0 then return end
  reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', native)
  reaper.GetSetMediaItemInfo_String(item, PEXT_USER_COLOR, '1', true)
end

function M.clear_item_user_color(item)
  if not item then return end
  reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', 0)
  reaper.GetSetMediaItemInfo_String(item, PEXT_USER_COLOR, '', true)
end

-- Bulk operations dla track-level swatch popup.
function M.bulk_set_track_items_color(tr, native)
  if not tr or not native or native == 0 then return 0 end
  local count = 0
  for it in M.iter_track_items(tr) do
    if M.is_audio_item(it) then
      M.set_item_user_color(it, native)
      count = count + 1
    end
  end
  return count
end

function M.bulk_clear_track_items_color(tr)
  if not tr then return 0 end
  local count = 0
  for it in M.iter_track_items(tr) do
    if M.is_audio_item(it) then
      M.clear_item_user_color(it)
      count = count + 1
    end
  end
  return count
end

function M.track_info(tr)
  local voice_id, voice_name = M.get_track_voice(tr)
  return {
    -- obj USUNIĘTE M7 (2026-07-11, user OK) — nikt nie czytał, a surowy
    -- MediaTrack* trzymany między klatkami to przynęta na use-after-free.
    guid       = M.track_guid(tr),
    index      = M.track_index(tr),
    name       = M.track_name(tr),
    role       = M.get_track_role(tr),
    voice_id   = voice_id,
    voice_name = voice_name,
    item_count = M.track_item_count(tr),
  }
end

-- T1 (UX-POLISH 2026-07): link source → output track. Output track sam
-- nie nosi markera — konsument (state.rebuild_tracks) buduje odwrotną mapę.
function M.get_track_output_guid(tr)
  local _, guid = reaper.GetSetMediaTrackInfo_String(
    tr, 'P_EXT:Reasonate.output_track_guid', '', false)
  return (guid ~= '' and guid) or nil
end

function M.find_track_by_guid(guid)
  for tr in M.iter_tracks() do
    if M.track_guid(tr) == guid then return tr end
  end
  return nil
end

----------------------------------------------------------------------------
-- Recording helpers (Phase 11.x — track recording z poziomu Reasonate).
----------------------------------------------------------------------------

-- arm_track_only(target) → prev_arm_states (table {guid → 0/1})
-- Disarmuje WSZYSTKIE inne tracki + arms target. Zwraca poprzedni stan
-- każdego tracka żeby restore_arm_state mógł odtworzyć po stop.
function M.arm_track_only(target)
  if not target then return {} end
  local prev = {}
  for tr in M.iter_tracks() do
    local guid = M.track_guid(tr)
    local cur  = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_RECARM') or 0)
    prev[guid] = cur
    if tr == target then
      if cur ~= 1 then
        reaper.SetMediaTrackInfo_Value(tr, 'I_RECARM', 1)
      end
    else
      if cur ~= 0 then
        reaper.SetMediaTrackInfo_Value(tr, 'I_RECARM', 0)
      end
    end
  end
  return prev
end

-- Restore arm states (called po stop record).
function M.restore_arm_states(prev)
  if not prev then return end
  for guid, val in pairs(prev) do
    local tr = M.find_track_by_guid(guid)
    if tr then
      reaper.SetMediaTrackInfo_Value(tr, 'I_RECARM', val or 0)
    end
  end
end

-- Position edit cursor for record start. Logika:
--   1. Default: respect aktualną pozycję cursor user'a (zwykle kliknięcie
--      timeline gdzie chce żeby zaczęło się nagrywanie).
--   2. Safety override: jeśli cursor leży WEWNĄTRZ istniejącego itema na
--      target track → push za koniec tego itema + gap (zapobiega overlap).
--   3. seekplay=true — play head też skacze, transport startuje z target_pos.
-- Returns the position set.
function M.position_cursor_for_record(track, gap_secs)
  if not track then return 0 end
  gap_secs = gap_secs or 0.5
  local cur = reaper.GetCursorPosition() or 0
  local target_pos = cur

  -- Sprawdź czy cursor jest wewnątrz któregokolwiek itema na track →
  -- push za koniec żeby nie nakładać.
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(it, 'D_POSITION') or 0
    local len = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH') or 0
    if cur >= pos - 0.001 and cur < pos + len then
      target_pos = pos + len + gap_secs
      break
    end
  end

  reaper.SetEditCurPos(target_pos, false, true)  -- seekplay=true
  return target_pos
end

-- Set track recording input + monitor + record mode (per CLAUDE.md sane defaults).
function M.configure_track_for_record(track, input, monitor)
  if not track then return end
  reaper.SetMediaTrackInfo_Value(track, 'I_RECINPUT', input or 0)
  reaper.SetMediaTrackInfo_Value(track, 'I_RECMON',   monitor or 1)
  -- I_RECMODE: 0 = output (stereo), 1 = stereo, 2 = none, 3 = stereo OOB,
  -- 4 = MIDI output, 5 = mono. Dla audio recording chcemy 0 (stereo) lub 5 (mono).
  -- Heurystyka: jeśli input >= 1024 → stereo; inaczej mono.
  local is_stereo = (input or 0) >= 1024
  reaper.SetMediaTrackInfo_Value(track, 'I_RECMODE', is_stereo and 0 or 5)
end

-- Read input peak meter (0..1, where 1.0 = 0 dB). channel 0 = first audio chan.
function M.track_peak_db(track, channel)
  if not track then return -120 end
  local linear = reaper.Track_GetPeakInfo(track, channel or 0) or 0
  if linear <= 0.000001 then return -120 end
  return 20 * math.log(linear, 10)  -- linear → dB
end

-- Recording state detection
function M.is_reaper_recording()
  local s = reaper.GetPlayState() or 0
  return (s & 4) ~= 0
end

-- Last item on track (po stop record — newly created)
function M.last_item_on_track(track)
  if not track then return nil end
  local n = reaper.CountTrackMediaItems(track)
  if n == 0 then return nil end
  return reaper.GetTrackMediaItem(track, n - 1)
end

----------------------------------------------------------------------------
-- Item iteration & info
----------------------------------------------------------------------------
function M.iter_track_items(tr)
  local i = -1
  local n = reaper.CountTrackMediaItems(tr)
  return function()
    i = i + 1
    if i >= n then return nil end
    return reaper.GetTrackMediaItem(tr, i)
  end
end

function M.item_guid(item)
  local _, g = reaper.GetSetMediaItemInfo_String(item, 'GUID', '', false)
  return g
end

-- Linear scan; ok dla projektów <1000 itemów. Phase 9 polish może dodać cache.
function M.find_item_by_guid(guid)
  if not guid or guid == '' then return nil end
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local it = reaper.GetMediaItem(0, i)
    local _, g = reaper.GetSetMediaItemInfo_String(it, 'GUID', '', false)
    if g == guid then return it end
  end
  return nil
end

----------------------------------------------------------------------------
-- Source info: ścieżka, długość, rozmiar pliku (do cache key + needs_conversion)
----------------------------------------------------------------------------
function M.item_source_info(item)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  local path = reaper.GetMediaSourceFileName(src, '')
  local length = reaper.GetMediaSourceLength(src)
  local size
  if path and path ~= '' then
    local f = io.open(path, 'rb')
    if f then size = f:seek('end'); f:close() end
  end
  return { path = path, length = length, size = size }
end

----------------------------------------------------------------------------
-- needs_conversion: zgodnie z docs/02-data-model.md algorytm.
-- current_voice_id: voice_id aktualnie przypisany do TRACKU (porównujemy z P_EXT.voice_id).
-- Returns: needs (bool), reason (string or nil)
----------------------------------------------------------------------------
function M.needs_conversion(item, current_voice_id, current_settings)
  local function getp(key)
    -- Use migration-aware getter (Reasonate.* → fallback Reasonate.* + migrate)
    return get_item_string(item, pext_key(key))
  end

  -- 1. Nigdy nie konwertowany
  if getp('converted') ~= '1' then return true, 'new' end

  -- 2. GUID się zmienił (split/duplicate)
  local orig_guid    = getp('original_guid')
  local current_guid = M.item_guid(item)
  if orig_guid ~= '' and orig_guid ~= current_guid then
    return true, 'split_or_duplicate'
  end

  -- 3. Output item zniknął
  local out_guid = getp('output_item_guid')
  if out_guid ~= '' and not M.find_item_by_guid(out_guid) then
    return true, 'output_missing'
  end

  -- 3b. Phase 7: chunked output — KTÓRYKOLWIEK kawałek zniknął → reconvert.
  -- Mapa index→guid pisana przez importer.import_chunk_result; klucz
  -- '_group' = REAPER I_GROUPID, nie item.
  local chunk_raw = getp('output_chunk_guids')
  if chunk_raw ~= '' then
    local ok, map = pcall(json.decode, chunk_raw)
    if ok and type(map) == 'table' then
      for k, guid in pairs(map) do
        if k ~= '_group' and not M.find_item_by_guid(guid) then
          return true, 'chunk_missing'
        end
      end
    end
  end

  -- 4. Voice się zmienił
  local prev_voice_id = getp('voice_id')
  if current_voice_id and prev_voice_id ~= '' and prev_voice_id ~= current_voice_id then
    return true, 'voice_changed'
  end

  -- 5. Voice settings się zmieniły (porównanie numeryczne)
  if current_settings then
    local prev_raw = getp('voice_settings')
    local prev = nil
    if prev_raw ~= '' then
      local ok, decoded = pcall(json.decode, prev_raw)
      if ok and type(decoded) == 'table' then prev = decoded end
    end
    if not M.settings_equal(prev, current_settings) then
      return true, 'voice_settings_changed'
    end
  end

  -- 6. Source się zmienił (path/size/length)
  local info = M.item_source_info(item)
  if not info then return true, 'no_source' end

  local prev_path = getp('source_path')
  if prev_path ~= '' and prev_path ~= info.path then
    return true, 'source_path_changed'
  end

  local prev_size = tonumber(getp('source_size'))
  if prev_size and info.size and prev_size ~= info.size then
    return true, 'source_size_changed'
  end

  local prev_length = tonumber(getp('source_length'))
  if prev_length and info.length and math.abs(prev_length - info.length) > 0.05 then
    return true, 'source_length_changed'
  end

  return false, nil
end

function M.is_audio_item(item)
  local take = reaper.GetActiveTake(item)
  if not take then return false end
  return not reaper.TakeIsMIDI(take)
end

----------------------------------------------------------------------------
-- Item status (P_EXT-based read; faza 6 doda 'stale' detection)
----------------------------------------------------------------------------
function M.get_item_status(item)
  if get_item_string(item, KEY_ITEM_IS_OUTPUT) == '1' then
    return 'output'
  end
  if get_item_string(item, KEY_ITEM_ERROR) ~= '' then
    return 'error'
  end
  if get_item_string(item, KEY_ITEM_CONVERTED) == '1' then
    return 'converted'
  end
  return 'new'
end

----------------------------------------------------------------------------
-- resolve_root_source(src) → root PCM source.
-- Section/reverse wrappers mają parent chain — schodzimy do root pliku.
-- Wydzielone (audit M2-2, 2026-06-10) z 3 identycznych kopii pętli
-- (stt.item_audio_path / dubbing.resolve_source_path_for_mixed /
-- repair.compute_stt_cache_key) — magiczna stała depth=4 żyła w 3 plikach.
----------------------------------------------------------------------------
local SOURCE_UNWRAP_MAX_DEPTH = 4

function M.resolve_root_source(src)
  local depth = 0
  while src and depth < SOURCE_UNWRAP_MAX_DEPTH do
    local parent = reaper.GetMediaSourceParent and reaper.GetMediaSourceParent(src)
    if not parent then break end
    src = parent
    depth = depth + 1
  end
  return src
end

----------------------------------------------------------------------------
-- NS-F M2 v3.1: per-voice TTS pace baseline (SYLABY/sec @ speed=1.0;
-- jednostka zmieniona z chars/sec 2026-06-10 W1.2 — patrz tempo_math.lua).
--
-- Used dla tempo-matched speed calculation: gdy user edytuje Repair, plugin
-- estymuje pace speakera w okolicach edycji (z words_tbl) i ustawia
-- voice_settings.speed tak żeby TTS grał w tym samym tempie. Bez kalibracji
-- default tempo_math.DEFAULT_BASELINE (~4.5 syl/s).
--
-- Persistence: GlobalExtState (per-voice, cross-project). Każda edycja
-- aktualizuje baseline running EMA (alpha=0.3) z observed pace forced_align.
-- Po 3-5 edycjach baseline stabilizuje się dla tego voice'a + language combo.
----------------------------------------------------------------------------
-- Matematyka (default/alpha/sanity bounds/EMA) wydzielona do
-- modules/tempo_math.lua (pure Lua, headless-testable — tests/run.lua).
-- Tu zostaje wyłącznie persistence przez ExtState.
local tempo_math = require 'modules.tempo_math'
-- Prefix 'voice_tempo_syl_' od 2026-06-10 (W1.2 zmiana jednostki na sylaby).
-- Stare klucze 'voice_tempo_<id>' (chars/sec) celowo osierocone — inna
-- jednostka, wartości nieprzeliczalne 1:1 (zależą od chars/syl ratio tekstu);
-- baseline uczy się od nowa w 2-3 edycjach.
local VOICE_TEMPO_KEY_PREFIX = 'voice_tempo_syl_'

function M.get_voice_tempo_baseline(voice_id)
  if not voice_id or voice_id == '' then return tempo_math.DEFAULT_BASELINE end
  local raw = reaper.GetExtState('Reasonate', VOICE_TEMPO_KEY_PREFIX .. voice_id)
  local n = tonumber(raw)
  if n and n > tempo_math.SANITY_MIN and n < tempo_math.SANITY_MAX then return n end
  return tempo_math.DEFAULT_BASELINE
end

function M.update_voice_tempo_baseline(voice_id, observed_chars_per_sec)
  if not voice_id or voice_id == '' then return end
  local current = M.get_voice_tempo_baseline(voice_id)
  local new_val, updated = tempo_math.ema_update(current, observed_chars_per_sec)
  if not updated then return end
  reaper.SetExtState('Reasonate', VOICE_TEMPO_KEY_PREFIX .. voice_id,
    string.format('%.3f', new_val), true)
end

function M.clear_voice_tempo_baseline(voice_id)
  if not voice_id or voice_id == '' then return end
  reaper.DeleteExtState('Reasonate', VOICE_TEMPO_KEY_PREFIX .. voice_id, true)
end

return M
