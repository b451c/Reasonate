-- modules/stt.lua
-- Phase 11 (Dialog Repair) — Scribe STT integration.
--
-- API: ElevenLabs Scribe (POST /v1/speech-to-text, multipart/form-data).
-- Sync call (krótki freeze GUI; ~3-10s typical). Kandydat na async w Phase
-- 11.x jeśli user'owie zgłoszą tarcie; na razie sync trzymamy spójnie z
-- fetch_voices i prostą logiką.
--
-- Cache 2-tier:
--   1. Item P_EXT (Reasonate.transcript_json + transcript_hash) — szybki, per-project
--   2. File cache <resource>/Scripts/reasonate_tmp/stt_<8hex>.json — per source file,
--      reusable między projektami / instancjami Reasonate
-- Cache key = DJB2(source_path + '|' + file_size). Plik się zmienia → inny
-- size → cache miss → re-transcribe.

local api  = require 'modules.api'
local cfg  = require 'modules.config'
local util = require 'modules.util'
local json = require 'modules.lib.json'

local M = {}

local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

----------------------------------------------------------------------------
-- Cache key + path
--
-- Legacy form: cache_key(audio_path) → hash(path + file_size).
-- Stable across sessions for same file, ale wymaga że audio_path istnieje
-- (file_size = 0 dla missing files → różny hash niż gdy plik istnieje).
--
-- Geometry form: cache_key(source_path, render_info={item_offs, item_length,
-- playrate}) → hash purely z source identity + item bounds. NIE wymaga
-- pliku — można sprawdzić cache PRZED rendering tmp WAV. Używane przez
-- Repair mode dla trimowanych itemów (renderujemy visible region do
-- tmp WAV, cache key opiera się na geometrii item'u, NIE na rendered file).
----------------------------------------------------------------------------
function M.cache_key(audio_path, render_info)
  if not audio_path or audio_path == '' then return nil end
  if render_info then
    local seed = ('%s|%.6f|%.6f|%.6f'):format(
      audio_path,
      tonumber(render_info.item_offs)   or 0,
      tonumber(render_info.item_length) or 0,
      tonumber(render_info.playrate)    or 1)
    -- I10 (M0): language w seedzie TYLKO gdy caller poda pole (Repair).
    -- Callers bez .language (Dubbing dubbing_panel) zachowują legacy keys —
    -- zero cache invalidation poza Repair namespace.
    if render_info.language ~= nil then
      seed = seed .. '|lang=' .. tostring(render_info.language)
    end
    return string.format('%08x', util.simple_hash(seed))
  end
  local size = util.file_size(audio_path) or 0
  local h = util.simple_hash(audio_path .. '|' .. tostring(size))
  return string.format('%08x', h)
end

function M.cache_path_for(audio_path, render_info)
  local key = M.cache_key(audio_path, render_info)
  if not key then return nil end
  util.mkdir_p(tmp_dir())
  return tmp_dir() .. path_sep() .. 'stt_' .. key .. '.json'
end

function M.cache_path_for_key(cache_key_str)
  if not cache_key_str or cache_key_str == '' then return nil end
  util.mkdir_p(tmp_dir())
  return tmp_dir() .. path_sep() .. 'stt_' .. cache_key_str .. '.json'
end

-- NS-G (2026-05-14): diarize cache parallel namespace. Regular STT + diarized
-- STT mają inną semantykę (diarize=true daje speaker_id per word; bez diarize
-- nie). Trzymanie w jednym cache slot → overwrite każdym call → utrata diarize
-- info. Per spec Option B: separate P_EXT keys (diarize_transcript_*) +
-- separate file cache path prefix (stt_diarize_<hash>.json).
function M.cache_path_for_diarize_key(cache_key_str)
  if not cache_key_str or cache_key_str == '' then return nil end
  util.mkdir_p(tmp_dir())
  return tmp_dir() .. path_sep() .. 'stt_diarize_' .. cache_key_str .. '.json'
end

----------------------------------------------------------------------------
-- File cache load/save
----------------------------------------------------------------------------
function M.load_file_cache(audio_path)
  local path = M.cache_path_for(audio_path)
  if not path or not util.file_exists(path) then return nil end
  local content = util.read_file(path)
  if not content or content == '' then return nil end
  local ok, decoded = pcall(json.decode, content)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded, content
end

function M.save_file_cache(audio_path, transcript)
  local path = M.cache_path_for(audio_path)
  if not path then return false, 'no cache path' end
  local ok, encoded = pcall(json.encode, transcript)
  if not ok then return false, 'json encode failed' end
  if not util.write_file(path, encoded) then
    return false, 'cannot write ' .. path
  end
  return true, encoded
end

-- Repair mode: load/save cache by explicit key (geometry-stable, NIE file-based).
function M.load_file_cache_by_key(cache_key_str)
  local path = M.cache_path_for_key(cache_key_str)
  if not path or not util.file_exists(path) then return nil end
  local content = util.read_file(path)
  if not content or content == '' then return nil end
  local ok, decoded = pcall(json.decode, content)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded, content
end

function M.save_file_cache_by_key(cache_key_str, transcript)
  local path = M.cache_path_for_key(cache_key_str)
  if not path then return false, 'no cache path' end
  local ok, encoded = pcall(json.encode, transcript)
  if not ok then return false, 'json encode failed' end
  if not util.write_file(path, encoded) then
    return false, 'cannot write ' .. path
  end
  return true, encoded
end

-- Convenience: check cache (P_EXT + file) by explicit key. Returns transcript+source or nil.
-- Used przez Repair mode dla cache-aware "Transcribe" button (check cache PRZED rendering tmp WAV).
function M.check_cache_for_item(item, cache_key_str)
  if not item or not cache_key_str then return nil, nil end
  -- Tier 1: P_EXT
  local p = M.read_item_cache(item, cache_key_str)
  if p then return p, 'p_ext' end
  -- Tier 2: file cache by key
  local fc, fc_raw = M.load_file_cache_by_key(cache_key_str)
  if fc then
    -- Promote do P_EXT dla future faster reads
    M.write_item_cache(item, fc_raw, cache_key_str)
    return fc, 'file_cache'
  end
  return nil, nil
end

-- NS-G: diarize-cache equivalent w parallel namespace.
function M.load_diarize_cache_by_key(cache_key_str)
  local path = M.cache_path_for_diarize_key(cache_key_str)
  if not path or not util.file_exists(path) then return nil end
  local content = util.read_file(path)
  if not content or content == '' then return nil end
  local ok, decoded = pcall(json.decode, content)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded, content
end

function M.save_diarize_cache_by_key(cache_key_str, transcript)
  local path = M.cache_path_for_diarize_key(cache_key_str)
  if not path then return false, 'no cache path' end
  local ok, encoded = pcall(json.encode, transcript)
  if not ok then return false, 'json encode failed' end
  if not util.write_file(path, encoded) then
    return false, 'cannot write ' .. path
  end
  return true, encoded
end

----------------------------------------------------------------------------
-- P_EXT helpers
----------------------------------------------------------------------------
local function ext_get(item, key)
  local _, v = reaper.GetSetMediaItemInfo_String(item, 'P_EXT:Reasonate.' .. key, '', false)
  return v
end

local function ext_set(item, key, value)
  reaper.GetSetMediaItemInfo_String(item, 'P_EXT:Reasonate.' .. key, tostring(value or ''), true)
end

function M.write_item_cache(item, transcript_json_str, hash_key)
  if not item then return end
  ext_set(item, 'transcript_hash', hash_key or '')
  ext_set(item, 'transcript_json', transcript_json_str or '')
  ext_set(item, 'transcript_fetched_at', tostring(os.time()))
end

function M.read_item_cache(item, expected_hash)
  if not item then return nil end
  local hash = ext_get(item, 'transcript_hash')
  if not hash or hash == '' then return nil end
  if expected_hash and hash ~= expected_hash then return nil end
  local raw = ext_get(item, 'transcript_json')
  if not raw or raw == '' then return nil end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

-- NS-G: P_EXT diarize cache w parallel namespace (different key prefix).
function M.write_item_diarize_cache(item, transcript_json_str, hash_key)
  if not item then return end
  ext_set(item, 'diarize_transcript_hash', hash_key or '')
  ext_set(item, 'diarize_transcript_json', transcript_json_str or '')
  ext_set(item, 'diarize_transcript_fetched_at', tostring(os.time()))
end

function M.read_item_diarize_cache(item, expected_hash)
  if not item then return nil end
  local hash = ext_get(item, 'diarize_transcript_hash')
  if not hash or hash == '' then return nil end
  if expected_hash and hash ~= expected_hash then return nil end
  local raw = ext_get(item, 'diarize_transcript_json')
  if not raw or raw == '' then return nil end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

-- NS-G follow-up: user-defined speaker labels per item (Repair tab rename).
-- P_EXT JSON map: { speaker_0 = 'Mati', speaker_1 = 'Host' }. Persists across
-- REAPER sessions. Empty map = use default 'Speaker N' labels.
function M.write_item_speaker_labels(item, labels_map)
  if not item then return end
  local ok, encoded = pcall(json.encode, labels_map or {})
  if not ok then return end
  ext_set(item, 'speaker_labels_json', encoded)
end

function M.read_item_speaker_labels(item)
  if not item then return {} end
  local raw = ext_get(item, 'speaker_labels_json')
  if not raw or raw == '' then return {} end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= 'table' then return {} end
  return decoded
end

-- T7 (UX-POLISH): casting mówców per item (Repair "Cast voices") —
-- P_EXT JSON map: { speaker_0 = { voice_id, voice_name } }. Kopie itemu
-- niosą casting; mówcy NAZWANI idą dodatkowo do Cast Registry (cross-mode).
function M.write_item_speaker_voices(item, voices_map)
  if not item then return end
  local ok, encoded = pcall(json.encode, voices_map or {})
  if not ok then return end
  ext_set(item, 'speaker_voices_json', encoded)
end

function M.read_item_speaker_voices(item)
  if not item then return {} end
  local raw = ext_get(item, 'speaker_voices_json')
  if not raw or raw == '' then return {} end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= 'table' then return {} end
  local out = {}
  for sid, v in pairs(decoded) do
    if type(v) == 'table' and type(v.voice_id) == 'string' and v.voice_id ~= '' then
      out[sid] = { voice_id = v.voice_id, voice_name = v.voice_name or '' }
    end
  end
  return out
end

-- NS-G: check diarize cache (P_EXT + file) by explicit key. Used przez
-- speaker_picker pre-check (avoid re-spawn diarize gdy cached) + Repair clone
-- flow (skip modal gdy diarize available + show multi-speaker hint).
--
-- NS-G follow-up (2026-05-14 PM4 fix #2): Tier 3 fallback do regular STT cache.
-- Po diarize=true default w Repair Transcribe, regular cache zawiera words
-- z speaker_id — wystarczy. Bez tej fallback clone Train robił re-Scribe
-- mimo że dane już są (user reported "Analyzing speakers | 11s" duplicate).
local function has_speaker_info(t)
  if not t or type(t.words) ~= 'table' then return false end
  for _, w in ipairs(t.words) do
    if w.speaker_id or w.speaker then return true end
  end
  return false
end

function M.check_diarize_cache_for_item(item, cache_key_str)
  if not item or not cache_key_str then return nil, nil end
  -- Tier 1: P_EXT diarize namespace
  local p = M.read_item_diarize_cache(item, cache_key_str)
  if p then return p, 'p_ext' end
  -- Tier 2: file diarize namespace
  local fc, fc_raw = M.load_diarize_cache_by_key(cache_key_str)
  if fc then
    M.write_item_diarize_cache(item, fc_raw, cache_key_str)
    return fc, 'file_cache'
  end
  -- Tier 3: regular STT cache fallback (gdy diarize=true był used).
  -- Cross-fill diarize namespace dla future instant lookups.
  local rp = M.read_item_cache(item, cache_key_str)
  if rp and has_speaker_info(rp) then
    local enc_ok, encoded = pcall(json.encode, rp)
    if enc_ok then
      M.save_diarize_cache_by_key(cache_key_str, rp)
      M.write_item_diarize_cache(item, encoded, cache_key_str)
    end
    return rp, 'regular_cache'
  end
  return nil, nil
end

-- M.transcribe (sync, blokujące GUI) USUNIĘTE M7 (2026-07-11, user OK) —
-- jedyny caller (transcribe_for_item) też sync-dead; async path =
-- spawn_transcribe_for_item + poll_transcribe. Git history zachowuje.

----------------------------------------------------------------------------
-- Resolve source audio path z REAPER itema (active take only — Phase 11 nie
-- supportuje multi-take source itemów dla repair).
----------------------------------------------------------------------------
function M.item_audio_path(item)
  if not item then return nil, 'nil item' end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil, 'item has no audio take' end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil, 'take has no source' end
  -- Section/reverse sources mają child source — shared helper (M2-2)
  src = require('modules.reaper_helpers').resolve_root_source(src)
  local path = reaper.GetMediaSourceFileName(src, '')
  if not path or path == '' then return nil, 'source has no file path' end
  return path, nil
end

-- M.transcribe_for_item (sync) USUNIĘTE M7 (2026-07-11, user OK) — patrz
-- notka przy usuniętym M.transcribe wyżej.

----------------------------------------------------------------------------
-- ASYNC API (NS-1 follow-up + Phase 11 polish):
-- spawn_transcribe_for_item() → returns handle (cache hit returns instant
-- result inline). Caller poll'uje poll_transcribe(handle) co frame.
--
-- Worker: scaffold/workers/worker_stt.sh (POSIX). Sentinel polling identyczny
-- jak job_manager dla STS — sentinel_path zawiera http_code, output_path
-- zawiera JSON response.
--
-- Handle shape:
--   {
--     status        = 'cache' | 'spawning' | 'pending' | 'done' | 'error'
--     source        = 'p_ext' | 'file_cache' | 'api'
--     transcript    = decoded table (gdy status=done)
--     error         = string (gdy status=error)
--     started_at    = util.now()
--     -- internal:
--     audio_path, hash, item, sentinel_path, output_path, key_file
--   }
----------------------------------------------------------------------------
function M.spawn_transcribe_for_item(item, opts)
  opts = opts or {}
  -- NS-C: caller (repair / sfx scene flow) może podać `opts.audio_path` override
  -- gdy track ma Voice Isolator flag ON — wtedy STT operuje na cleaned audio,
  -- nie na źródłowym pliku.
  -- NS-F Repair: caller może podać `opts.cache_key` (geometry-stable hash z
  -- compute_stt_cache_key) + `opts.timestamp_shift_secs` (= item_offs). Cache
  -- check używa stable key, poll shifts word timestamps po STT done żeby były
  -- w source-time space (zgodne z compute_item_bounds dla transcript filtering).
  local audio_path, perr
  if opts.audio_path and opts.audio_path ~= '' then
    audio_path = opts.audio_path
  else
    audio_path, perr = M.item_audio_path(item)
    if not audio_path then return { status = 'error', error = perr } end
  end

  -- Cache key: explicit override (geometry-stable) preferred; legacy fallback
  local hash = opts.cache_key or M.cache_key(audio_path)
  if not hash then return { status = 'error', error = 'cannot compute cache key' } end

  -- Tier 1: P_EXT
  local p = M.read_item_cache(item, hash)
  if p then
    return { status = 'done', source = 'p_ext', transcript = p, started_at = util.now() }
  end

  -- Tier 2: file cache (prefer explicit-key path gdy override, legacy audio_path-derived else)
  local fc, fc_raw
  if opts.cache_key then
    fc, fc_raw = M.load_file_cache_by_key(opts.cache_key)
  else
    fc, fc_raw = M.load_file_cache(audio_path)
  end
  if fc then
    M.write_item_cache(item, fc_raw, hash)
    return { status = 'done', source = 'file_cache', transcript = fc, started_at = util.now() }
  end

  -- Tier 3: spawn worker_stt.sh async
  local api_key = cfg.get_api_key()
  if not api_key or api_key == '' then
    return { status = 'error', error = 'no API key' }
  end
  if not util.file_exists(audio_path) then
    return { status = 'error', error = 'audio file not found: ' .. audio_path }
  end

  util.mkdir_p(tmp_dir())

  -- M6-2: api.ensure_key_file zawsze istnieje — inline fallback pisał plik
  -- bez atomic publish i połykał błędy chmod; teraz twardy, czytelny error.
  local key_file, kerr = api.ensure_key_file(api_key)
  if not key_file then
    return { status = 'error', error = 'key file: ' .. tostring(kerr) }
  end

  local job_id = ('stt_%x_%x'):format(os.time(), math.random(0, 0xFFFFFF))
  local sentinel_path = tmp_dir() .. path_sep() .. job_id .. '.done'
  local output_path   = tmp_dir() .. path_sep() .. job_id .. '.json'

  -- worker_stt.sh expected w obrębie scaffold/workers/. Resolve relative
  -- to entry script (reasonate.lua located via get_action_context).
  -- Simplest: assume scaffold/workers/worker_stt.sh in same parent jak reasonate.
  local _, this_path = reaper.get_action_context()
  local scaffold_dir = this_path and this_path:match('(.+)[/\\]') or ''
  local worker_path  = util.worker_script(scaffold_dir .. path_sep() .. 'workers' .. path_sep() .. 'worker_stt.sh')

  local model_id  = opts.model_id or 'scribe_v2'
  local lang_code = opts.language_code or ''   -- I10: '' = auto (worker omituje pole)
  local diarize   = (opts.diarize == true) and 'true' or 'false'
  local times     = opts.timestamps_granularity or 'word'
  local url       = 'https://api.elevenlabs.io/v1/speech-to-text'

  -- M5-6: opcjonalne pola formularza przez plik extras (name=value per
  -- linia): keyterms (bias słownictwa przy Re-transcribe — PL nazwy własne)
  -- + diarization_threshold (dubbing advanced). Plik kasowany w poll.
  local extras_path = ''
  do
    local lines = {}
    for _, term in ipairs(opts.keyterms or {}) do
      term = tostring(term):gsub('[\r\n]', ' ')
      -- Limity API (docs 2026-07-11): <50 znaków, max 5 słów per term.
      local _, n_words = term:gsub('%S+', '')
      if term ~= '' and #term < 50 and n_words <= 5 then
        lines[#lines + 1] = 'keyterms=' .. term
      end
    end
    if tonumber(opts.diarization_threshold) then
      lines[#lines + 1] = ('diarization_threshold=%s'):format(opts.diarization_threshold)
    end
    if #lines > 0 then
      extras_path = tmp_dir() .. path_sep() .. job_id .. '.extras'
      if not util.write_file(extras_path, table.concat(lines, '\n') .. '\n') then
        extras_path = ''
      end
    end
  end

  local cmd = table.concat({
    util.shell_escape(worker_path),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(audio_path),
    util.shell_escape(model_id),
    util.shell_escape(lang_code),
    util.shell_escape(diarize),
    util.shell_escape(times),
    util.shell_escape(output_path),
    util.shell_escape(sentinel_path),
    util.shell_escape(extras_path),
  }, ' ')

  -- Fire-and-forget (timeout = -1 → no wait)
  util.exec_worker(cmd)

  return {
    status               = 'pending',
    source               = 'api',
    started_at           = util.now(),
    audio_path           = audio_path,
    hash                 = hash,
    cache_key            = opts.cache_key,         -- geometry-stable, dla save via key
    timestamp_shift_secs = opts.timestamp_shift_secs or 0,
    item                 = item,
    sentinel_path        = sentinel_path,
    output_path          = output_path,
    extras_path          = extras_path ~= '' and extras_path or nil,
  }
end

----------------------------------------------------------------------------
-- poll_transcribe(handle) → mutates handle.status; returns handle.
-- Idempotent — bezpieczne wywołanie co frame.
----------------------------------------------------------------------------
function M.poll_transcribe(handle)
  if not handle then return nil end
  if handle.status ~= 'pending' then return handle end

  if not util.file_exists(handle.sentinel_path) then
    return handle  -- still running
  end

  -- Sentinel + curl diagnostics przez shared async_op (M2-1, 2026-06-10) —
  -- wcześniej verbatim kopia bloku z voice_admin/forced_align.
  local async_op = require 'modules.async_op'
  local sent = async_op.read_sentinel(handle)
  local http_code = sent.http_code
  handle.http_code = http_code

  -- M5-6: ephemeral plik extras (keyterms/threshold) — cleanup po done.
  if handle.extras_path then os.remove(handle.extras_path); handle.extras_path = nil end

  local body = util.read_file(handle.output_path) or ''
  os.remove(handle.output_path)

  if http_code < 200 or http_code >= 300 then
    handle.status = 'error'
    handle.error  = async_op.format_http_error(nil, sent, body)
    return handle
  end

  local ok, decoded = pcall(json.decode, body)
  if not ok or type(decoded) ~= 'table' then
    handle.status = 'error'
    handle.error  = 'STT response not JSON'
    return handle
  end

  -- Normalize segments-only response
  if not decoded.words and type(decoded.segments) == 'table' then
    local flat = {}
    for _, seg in ipairs(decoded.segments) do
      if type(seg.words) == 'table' then
        for _, w in ipairs(seg.words) do flat[#flat + 1] = w end
      end
    end
    decoded.words = flat
  end
  if type(decoded.words) ~= 'table' then
    handle.status = 'error'
    handle.error  = 'STT response missing "words" array'
    return handle
  end

  -- NS-F: shift word/segment/character timestamps if caller rendered partial
  -- item region. Scribe returns timestamps relative to the SUBMITTED file
  -- (rendered tmp WAV starts at 0); to map back to SOURCE-time space (matches
  -- compute_item_bounds + transcript.collect_visible_words filter), add
  -- handle.timestamp_shift_secs (= original item_offs).
  local shift = tonumber(handle.timestamp_shift_secs) or 0
  if shift > 0.0001 then
    if type(decoded.words) == 'table' then
      for _, w in ipairs(decoded.words) do
        if w.start  then w.start  = w.start  + shift end
        if w['end'] then w['end'] = w['end'] + shift end
      end
    end
    if type(decoded.segments) == 'table' then
      for _, seg in ipairs(decoded.segments) do
        if seg.start  then seg.start  = seg.start  + shift end
        if seg['end'] then seg['end'] = seg['end'] + shift end
        if type(seg.words) == 'table' then
          for _, w in ipairs(seg.words) do
            if w.start  then w.start  = w.start  + shift end
            if w['end'] then w['end'] = w['end'] + shift end
          end
        end
      end
    end
    if type(decoded.characters) == 'table' then
      for _, c in ipairs(decoded.characters) do
        if c.start  then c.start  = c.start  + shift end
        if c['end'] then c['end'] = c['end'] + shift end
      end
    end
  end

  -- Save oba cache'e (file + P_EXT). NS-2d: handle.skip_cache=true bypassuje
  -- — diarized response NIE jest valid replacement dla regular transcript cache
  -- (różne shape, czasem inny content). file-based spawn_diarize (NS-2d) używa
  -- tej flagi (cache w pamięci tylko).
  -- NS-F: prefer save_file_cache_by_key (geometry-stable) gdy handle.cache_key
  -- jest set; legacy save_file_cache(audio_path) gdy nie (Phase 11 / Dubbing).
  -- NS-G: handle.is_diarize + handle.cache_key → save do diarize namespace
  -- (parallel P_EXT + file cache prefix stt_diarize_<hash>.json).
  if handle.is_diarize and handle.cache_key and handle.cache_key ~= '' then
    local saved_ok, encoded =
      M.save_diarize_cache_by_key(handle.cache_key, decoded)
    if saved_ok and handle.item then
      M.write_item_diarize_cache(handle.item, encoded, handle.hash)
    end
  elseif not handle.skip_cache then
    local saved_ok, encoded
    if handle.cache_key and handle.cache_key ~= '' then
      saved_ok, encoded = M.save_file_cache_by_key(handle.cache_key, decoded)
    else
      saved_ok, encoded = M.save_file_cache(handle.audio_path, decoded)
    end
    if saved_ok and handle.item then
      M.write_item_cache(handle.item, encoded, handle.hash)
    end
  end

  handle.transcript = decoded
  handle.status     = 'done'
  return handle
end

----------------------------------------------------------------------------
-- NS-2d: spawn_diarize(audio_path, opts) — async STT z diarize=true.
--
-- Pattern mirror spawn_transcribe_for_item ale BEZ cache check (zawsze fresh,
-- diarized response ma własną semantykę inną od regular transcript) i BEZ
-- handle.item (file-based, nie item-bound). handle.skip_cache=true
-- instruuje poll_transcribe żeby NIE zapisał response do regular cache.
--
-- opts: { language_code='' (auto; ISO code wymusza), num_speakers=nil/int,
--         model_id='scribe_v2',
--         diarize=true (default) — set false dla NS-B Flow B per-track }
--
-- Returns handle (status='pending', sentinel_path, output_path, audio_path,
-- skip_cache=true, started_at). poll_transcribe → handle.status='done' z
-- handle.transcript zawierającym words[] z speaker_id per word.
----------------------------------------------------------------------------
function M.spawn_diarize(audio_path, opts)
  opts = opts or {}
  if not audio_path or audio_path == '' then
    return { status = 'error', error = 'empty audio path' }
  end
  if not util.file_exists(audio_path) then
    return { status = 'error', error = 'audio file not found: ' .. audio_path }
  end

  local api_key = cfg.get_api_key()
  if not api_key or api_key == '' then
    return { status = 'error', error = 'no API key' }
  end

  util.mkdir_p(tmp_dir())

  -- M6-2: api.ensure_key_file zawsze istnieje — inline fallback pisał plik
  -- bez atomic publish i połykał błędy chmod; teraz twardy, czytelny error.
  local key_file, kerr = api.ensure_key_file(api_key)
  if not key_file then
    return { status = 'error', error = 'key file: ' .. tostring(kerr) }
  end

  local job_id = ('diarize_%x_%x'):format(os.time(), math.random(0, 0xFFFFFF))
  local sentinel_path = tmp_dir() .. path_sep() .. job_id .. '.done'
  local output_path   = tmp_dir() .. path_sep() .. job_id .. '.json'

  local _, this_path = reaper.get_action_context()
  local scaffold_dir = this_path and this_path:match('(.+)[/\\]') or ''
  local worker_path  = util.worker_script(scaffold_dir .. path_sep() .. 'workers' .. path_sep() .. 'worker_stt.sh')

  local model_id  = opts.model_id or 'scribe_v2'
  local lang_code = opts.language_code or ''   -- I10: '' = auto (worker omituje pole)
  local times     = opts.timestamps_granularity or 'word'
  local url       = 'https://api.elevenlabs.io/v1/speech-to-text'
  local diarize   = (opts.diarize == false) and 'false' or 'true'

  -- M5-6: diarization_threshold (dubbing advanced) przez plik extras.
  local extras_path = ''
  if tonumber(opts.diarization_threshold) then
    extras_path = tmp_dir() .. path_sep() .. job_id .. '.extras'
    if not util.write_file(extras_path,
        ('diarization_threshold=%s\n'):format(opts.diarization_threshold)) then
      extras_path = ''
    end
  end

  local cmd = table.concat({
    util.shell_escape(worker_path),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(audio_path),
    util.shell_escape(model_id),
    util.shell_escape(lang_code),
    util.shell_escape(diarize),
    util.shell_escape(times),
    util.shell_escape(output_path),
    util.shell_escape(sentinel_path),
    util.shell_escape(extras_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    status        = 'pending',
    source        = 'api',
    started_at    = util.now(),
    audio_path    = audio_path,
    item          = nil,           -- file-based, not item-bound
    skip_cache    = true,          -- diarized response → bypass save_file_cache
    sentinel_path = sentinel_path,
    output_path   = output_path,
    extras_path   = extras_path ~= '' and extras_path or nil,
  }
end

----------------------------------------------------------------------------
-- NS-G: spawn_diarize_for_item(item, opts) — item-bound diarize STT z
-- geometry-stable cache key. Mirror spawn_transcribe_for_item ale z
-- diarize=true + saves to diarize namespace (parallel cache).
--
-- Use case: speaker_picker modal (przed IVC training) wymaga speaker_id per
-- word. Item może już mieć regular STT cached — diarize wymaga separate run
-- + separate save namespace żeby nie nadpisać.
--
-- opts: { language_code='' (auto; ISO code wymusza), model_id='scribe_v2',
--         cache_key, render_info, timestamp_shift_secs, audio_path_override }
--
-- Returns handle z handle.is_diarize=true (signal dla poll_transcribe).
----------------------------------------------------------------------------
function M.spawn_diarize_for_item(item, opts)
  opts = opts or {}

  local audio_path, perr
  if opts.audio_path and opts.audio_path ~= '' then
    audio_path = opts.audio_path
  else
    audio_path, perr = M.item_audio_path(item)
    if not audio_path then return { status = 'error', error = perr } end
  end

  local hash = opts.cache_key or M.cache_key(audio_path)
  if not hash then return { status = 'error', error = 'cannot compute cache key' } end

  -- Tier 1: P_EXT diarize cache
  local p = M.read_item_diarize_cache(item, hash)
  if p then
    return {
      status     = 'done',
      source     = 'p_ext',
      transcript = p,
      started_at = util.now(),
      is_diarize = true,
    }
  end

  -- Tier 2: file diarize cache
  local fc, fc_raw = M.load_diarize_cache_by_key(hash)
  if fc then
    M.write_item_diarize_cache(item, fc_raw, hash)
    return {
      status     = 'done',
      source     = 'file_cache',
      transcript = fc,
      started_at = util.now(),
      is_diarize = true,
    }
  end

  -- Tier 3: spawn worker_stt.sh async z diarize=true
  local api_key = cfg.get_api_key()
  if not api_key or api_key == '' then
    return { status = 'error', error = 'no API key' }
  end
  if not util.file_exists(audio_path) then
    return { status = 'error', error = 'audio file not found: ' .. audio_path }
  end

  util.mkdir_p(tmp_dir())

  -- M6-2: api.ensure_key_file zawsze istnieje — inline fallback pisał plik
  -- bez atomic publish i połykał błędy chmod; teraz twardy, czytelny error.
  local key_file, kerr = api.ensure_key_file(api_key)
  if not key_file then
    return { status = 'error', error = 'key file: ' .. tostring(kerr) }
  end

  local job_id = ('diarize_item_%x_%x'):format(os.time(), math.random(0, 0xFFFFFF))
  local sentinel_path = tmp_dir() .. path_sep() .. job_id .. '.done'
  local output_path   = tmp_dir() .. path_sep() .. job_id .. '.json'

  local _, this_path = reaper.get_action_context()
  local scaffold_dir = this_path and this_path:match('(.+)[/\\]') or ''
  local worker_path  = util.worker_script(scaffold_dir .. path_sep() .. 'workers' .. path_sep() .. 'worker_stt.sh')

  local model_id  = opts.model_id or 'scribe_v2'
  local lang_code = opts.language_code or ''   -- I10: '' = auto (worker omituje pole)
  local times     = opts.timestamps_granularity or 'word'
  local url       = 'https://api.elevenlabs.io/v1/speech-to-text'
  local diarize   = 'true'  -- ZAWSZE true dla spawn_diarize_for_item

  local cmd = table.concat({
    util.shell_escape(worker_path),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(audio_path),
    util.shell_escape(model_id),
    util.shell_escape(lang_code),
    util.shell_escape(diarize),
    util.shell_escape(times),
    util.shell_escape(output_path),
    util.shell_escape(sentinel_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    status               = 'pending',
    source               = 'api',
    started_at           = util.now(),
    audio_path           = audio_path,
    hash                 = hash,
    cache_key            = hash,
    timestamp_shift_secs = opts.timestamp_shift_secs or 0,
    item                 = item,
    is_diarize           = true,        -- signal dla poll_transcribe → diarize namespace save
    sentinel_path        = sentinel_path,
    output_path          = output_path,
  }
end

----------------------------------------------------------------------------
-- M.clear_cache_for_item(item, cache_key_str?) — usuwa P_EXT + file cache
-- (force re-STT). cache_key_str optional dla geometry-stable namespace
-- (NS-F+NS-G). Without it: legacy audio_path-based file cache only.
----------------------------------------------------------------------------
function M.clear_cache_for_item(item, cache_key_str)
  if not item then return end
  ext_set(item, 'transcript_hash', '')
  ext_set(item, 'transcript_json', '')
  ext_set(item, 'transcript_fetched_at', '')
  local audio_path = select(1, M.item_audio_path(item))
  if audio_path then
    local cp = M.cache_path_for(audio_path)
    if cp and util.file_exists(cp) then os.remove(cp) end
  end
  -- NS-G: geometry-stable namespace cleanup
  if cache_key_str and cache_key_str ~= '' then
    local cp_key = M.cache_path_for_key(cache_key_str)
    if cp_key and util.file_exists(cp_key) then os.remove(cp_key) end
  end
end

return M
