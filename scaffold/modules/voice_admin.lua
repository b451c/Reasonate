-- modules/voice_admin.lua
-- Async voice management ops via worker_voice_op.sh + sentinel polling.
-- Mirror pattern: stt.spawn_transcribe_for_item / poll_transcribe.
--
-- Public:
--   spawn_train(name, sample_path)       → handle (op='train')
--   spawn_delete(voice_id)                → handle (op='delete')
--   spawn_rename(voice_id, new_name)      → handle (op='rename')
--   spawn_refresh()                       → handle (op='refresh')
--   spawn_quota()                         → handle (op='quota'); GET /v1/user/subscription
--   poll(handle)                          → mutates handle.status w 'running'/'done'/'error'
--
-- handle fields after poll completes:
--   status         — 'done' albo 'error'
--   result         — op-specific (voice_id dla train, parsed voices array dla refresh, nil dla delete)
--   error          — string gdy status='error'
--   elapsed        — seconds since spawn

local util = require 'modules.util'
local cfg  = require 'modules.config'
local api  = require 'modules.api'
local json = require 'modules.lib.json'
local async_op = require 'modules.async_op'   -- M2-1: shared sentinel/diag

local M = {}

local API_BASE = 'https://api.elevenlabs.io'

local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

local function worker_path()
  -- Windows port (2026-07-11): .ps1 przez util.worker_script
  local _, this_path = reaper.get_action_context()
  local scaffold_dir = this_path and this_path:match('(.+)[/\\]') or ''
  return util.worker_script(scaffold_dir .. path_sep() .. 'workers' .. path_sep() .. 'worker_voice_op.sh')
end

local function ensure_dir(p) util.mkdir_p(p) end

local function unique_paths(prefix)
  ensure_dir(tmp_dir())
  local job_id = ('%s_%x_%x'):format(prefix, os.time(), math.random(0, 0xFFFFFF))
  local out_path      = tmp_dir() .. path_sep() .. job_id .. '.out'
  local sentinel_path = tmp_dir() .. path_sep() .. job_id .. '.done'
  return out_path, sentinel_path
end

----------------------------------------------------------------------------
-- Spawn helper (per-op cmd construction). Returns handle skeleton.
----------------------------------------------------------------------------
-- Definicja NAD spawn() — Lua lexical scoping (KNOWN-ISSUES): local function
-- widzi tylko symbole zdefiniowane wcześniej w pliku.
local function url_encode(s)
  if s == nil then return '' end
  s = tostring(s)
  return (s:gsub('([^%w%-_%.%~])', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

local function spawn(op, args, key_override)
  -- key_override (M2-2, audit 2026-07): Settings "Test connection" testuje
  -- klucz z bufora (jeszcze nie zapisany) — ensure_key_file nadpisze plik
  -- gdy klucz różny od cache'owanego.
  local key = key_override or cfg.get_api_key()
  if not key or key == '' then
    return { status = 'error', error = 'no API key', op = op }
  end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then
    return { status = 'error', error = kerr or 'no key file', op = op }
  end

  local out_path, sentinel_path = unique_paths(op)
  local curl = cfg.get_curl_path()

  -- Build cmd argv per op
  local argv = {
    util.shell_escape(worker_path()),
    util.shell_escape(op),
    util.shell_escape(curl),
  }

  if op == 'train' then
    argv[#argv + 1] = util.shell_escape(API_BASE .. '/v1/voices/add')
    argv[#argv + 1] = util.shell_escape(key_file)
    argv[#argv + 1] = util.shell_escape(args.name)
    argv[#argv + 1] = util.shell_escape(args.sample_path)
    argv[#argv + 1] = util.shell_escape(out_path)
    argv[#argv + 1] = util.shell_escape(sentinel_path)
  elseif op == 'delete' then
    argv[#argv + 1] = util.shell_escape(API_BASE .. '/v1/voices/' .. args.voice_id)
    argv[#argv + 1] = util.shell_escape(key_file)
    argv[#argv + 1] = util.shell_escape(out_path)
    argv[#argv + 1] = util.shell_escape(sentinel_path)
  elseif op == 'rename' then
    argv[#argv + 1] = util.shell_escape(API_BASE .. '/v1/voices/' .. args.voice_id .. '/edit')
    argv[#argv + 1] = util.shell_escape(key_file)
    argv[#argv + 1] = util.shell_escape(args.new_name)
    argv[#argv + 1] = util.shell_escape(out_path)
    argv[#argv + 1] = util.shell_escape(sentinel_path)
  elseif op == 'refresh' then
    -- M3-2: args.page_token = kontynuacja paginacji (konta >100 głosów);
    -- pierwsza strona bez tokenu. Kolejne strony spawnuje poll() na tym
    -- samym handle'u — callerzy pollują bez zmian.
    local url = API_BASE .. '/v2/voices?page_size=100'
    if args.page_token and args.page_token ~= '' then
      url = url .. '&next_page_token=' .. url_encode(args.page_token)
    end
    argv[#argv + 1] = util.shell_escape(url)
    argv[#argv + 1] = util.shell_escape(key_file)
    argv[#argv + 1] = util.shell_escape(out_path)
    argv[#argv + 1] = util.shell_escape(sentinel_path)
  elseif op == 'quota' then
    argv[#argv + 1] = util.shell_escape(API_BASE .. '/v1/user/subscription')
    argv[#argv + 1] = util.shell_escape(key_file)
    argv[#argv + 1] = util.shell_escape(out_path)
    argv[#argv + 1] = util.shell_escape(sentinel_path)
  else
    return { status = 'error', error = 'unknown op: ' .. tostring(op), op = op }
  end

  local cmd = table.concat(argv, ' ')
  util.exec_worker(cmd)

  return {
    op            = op,
    status        = 'running',
    started_at    = util.now(),
    sentinel_path = sentinel_path,
    output_path   = out_path,
    args          = args,
  }
end

----------------------------------------------------------------------------
-- Public API: per-op spawn wrappers
----------------------------------------------------------------------------
function M.spawn_train(name, sample_path)
  if not name or name == '' then return { status = 'error', error = 'empty name', op = 'train' } end
  if not sample_path or sample_path == '' then return { status = 'error', error = 'empty sample', op = 'train' } end
  return spawn('train', { name = name, sample_path = sample_path })
end

function M.spawn_delete(voice_id)
  if not voice_id or voice_id == '' then return { status = 'error', error = 'empty voice_id', op = 'delete' } end
  return spawn('delete', { voice_id = voice_id })
end

function M.spawn_rename(voice_id, new_name)
  if not voice_id or voice_id == '' then return { status = 'error', error = 'empty voice_id', op = 'rename' } end
  if not new_name or new_name == '' then return { status = 'error', error = 'empty new_name', op = 'rename' } end
  return spawn('rename', { voice_id = voice_id, new_name = new_name })
end

function M.spawn_refresh(opts)
  local h = spawn('refresh', {}, opts and opts.api_key)
  -- M3-2: kontynuacja paginacji w poll() musi użyć tego samego klucza
  -- (Settings "Test/Save & fetch" testuje klucz z bufora przed zapisem).
  h._key_override = opts and opts.api_key or nil
  return h
end

function M.spawn_quota(opts)
  return spawn('quota', {}, opts and opts.api_key)
end

----------------------------------------------------------------------------
-- spawn_list_shared(filters) — async GET /v1/shared-voices z query params.
-- filters: { search, gender, age, language, accent, category, featured (bool),
--            page (int 0+), page_size (int 1-100) }.
-- All optional. Empty/nil filtry pomijane.
----------------------------------------------------------------------------
function M.spawn_list_shared(filters)
  filters = filters or {}
  local qs = {}
  qs[#qs + 1] = 'page_size=' .. tostring(filters.page_size or 30)
  if filters.page and filters.page > 0 then
    qs[#qs + 1] = 'page=' .. tostring(filters.page)
  end
  for _, k in ipairs({ 'search', 'gender', 'age', 'language', 'accent', 'category' }) do
    local v = filters[k]
    if v and v ~= '' then
      qs[#qs + 1] = k .. '=' .. url_encode(v)
    end
  end
  if filters.use_case and filters.use_case ~= '' then
    qs[#qs + 1] = 'use_cases=' .. url_encode(filters.use_case)
  end
  if filters.featured == true then qs[#qs + 1] = 'featured=true' end
  if filters.include_custom_rates == true then
    qs[#qs + 1] = 'include_custom_rates=true'
  end
  if filters.include_live_moderated == true then
    qs[#qs + 1] = 'include_live_moderated=true'
  end

  local url = API_BASE .. '/v1/shared-voices?' .. table.concat(qs, '&')

  local key = cfg.get_api_key()
  if not key or key == '' then return { status = 'error', error = 'no API key', op = 'shared_list' } end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then return { status = 'error', error = kerr or 'no key file', op = 'shared_list' } end

  local out_path, sentinel_path = unique_paths('shared_list')

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape('shared_list'),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(out_path),
    util.shell_escape(sentinel_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    op            = 'shared_list',
    status        = 'running',
    started_at    = util.now(),
    sentinel_path = sentinel_path,
    output_path   = out_path,
    args          = filters,
  }
end

----------------------------------------------------------------------------
-- spawn_add_shared(public_owner_id, voice_id, new_name) — async POST
-- /v1/voices/add/{public_owner_id}/{voice_id} z {new_name} JSON body.
----------------------------------------------------------------------------
function M.spawn_add_shared(public_owner_id, voice_id, new_name)
  if not public_owner_id or public_owner_id == '' then
    return { status = 'error', error = 'empty public_owner_id', op = 'add_shared' }
  end
  if not voice_id or voice_id == '' then
    return { status = 'error', error = 'empty voice_id', op = 'add_shared' }
  end
  if not new_name or new_name == '' then
    return { status = 'error', error = 'empty new_name', op = 'add_shared' }
  end

  local key = cfg.get_api_key()
  if not key or key == '' then return { status = 'error', error = 'no API key', op = 'add_shared' } end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then return { status = 'error', error = kerr or 'no key file', op = 'add_shared' } end

  ensure_dir(tmp_dir())
  local body_path = tmp_dir() .. path_sep()
                 .. ('add_shared_body_%x_%x.json'):format(os.time(), math.random(0, 0xFFFFFF))
  if not util.write_file(body_path, json.encode({ new_name = new_name })) then
    return { status = 'error', error = 'cannot write body file', op = 'add_shared' }
  end

  local out_path, sentinel_path = unique_paths('add_shared')
  local url = API_BASE .. '/v1/voices/add/' .. public_owner_id .. '/' .. voice_id

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape('add_shared'),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(body_path),
    util.shell_escape(out_path),
    util.shell_escape(sentinel_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    op            = 'add_shared',
    status        = 'running',
    started_at    = util.now(),
    sentinel_path = sentinel_path,
    output_path   = out_path,
    body_path     = body_path,
    args          = { public_owner_id = public_owner_id, voice_id = voice_id, new_name = new_name },
  }
end

----------------------------------------------------------------------------
-- spawn_tts(opts) — async TTS. Skip worker spawn na cache hit (synthetic
-- done handle z result=cache_path). opts: voice_id/text/prev_text/next_text/
-- voice_settings/seed/language_code/output_format/with_timestamps (M5-1).
----------------------------------------------------------------------------
function M.spawn_tts(opts)
  opts = opts or {}
  if not opts.voice_id or opts.voice_id == '' then
    return { status = 'error', error = 'empty voice_id', op = 'tts' }
  end
  if not opts.text or opts.text == '' then
    return { status = 'error', error = 'empty text', op = 'tts' }
  end

  -- Cache hit → synthetic done (eliminuje worker spawn dla powtórzonych phrases).
  -- M5-1: przy with_timestamps cache hit wymaga TAKŻE sidecara alignmentu
  -- (<cache>.align.json) — mp3 z ery 2-requestowej bez sidecara = miss
  -- (jednorazowy re-render, od tej pory 1 request z alignmentem w cache).
  local tts = require 'modules.tts'
  local cache_path = tts.cache_path_for(opts)
  if cache_path and util.file_exists(cache_path)
     and (util.file_size(cache_path) or 0) > 1024 then
    local alignment = nil
    local sidecar_ok = true
    if opts.with_timestamps then
      sidecar_ok = false
      local raw = util.read_file(cache_path .. '.align.json')
      if raw and raw ~= '' then
        local okj, decoded = pcall(json.decode, raw)
        if okj and type(decoded) == 'table' and type(decoded.words) == 'table' then
          alignment  = decoded
          sidecar_ok = true
        end
      end
    end
    if sidecar_ok then
      return {
        op         = 'tts',
        status     = 'done',
        result     = cache_path,
        alignment  = alignment,   -- M5-1: nil gdy zwykły tts
        started_at = util.now(),
        elapsed    = 0,
        from_cache = true,   -- prevents char counter billing on cache hits
        args       = opts,
      }
    end
  end

  local key = cfg.get_api_key()
  if not key or key == '' then return { status = 'error', error = 'no API key', op = 'tts' } end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then return { status = 'error', error = kerr or 'no key file', op = 'tts' } end

  -- Body JSON
  local body = {
    text     = opts.text,
    model_id = opts.model_id or 'eleven_multilingual_v2',
  }
  if type(opts.voice_settings) == 'table' then body.voice_settings = opts.voice_settings end
  if opts.prev_text and opts.prev_text ~= '' then body.previous_text = opts.prev_text end
  if opts.next_text and opts.next_text ~= '' then body.next_text = opts.next_text end
  -- Seed (NS-2b TTS regen): integer 0..2^32-1 dla deterministic gen, różne
  -- seedy = różne wygenerowane audio dla tego samego tekstu/głosu/settings.
  if opts.seed and tonumber(opts.seed) and opts.seed > 0 then
    body.seed = math.floor(opts.seed)
  end
  -- NS-B Dubbing: language_code (ISO 639-1, e.g. 'pl' / 'es' / 'de' — NOT 'pl-PL').
  -- HOTFIX 2026-07-11: normalizacja przez util.iso639_1 — Scribe daje kody
  -- 639-3 ('eng'), custom kody dubbingu bywają z regionem ('pt-br'); surowe
  -- przekazanie = HTTP 400. Nienormalizowalne → pole POMIJANE (autodetekcja).
  do
    local lc = util.iso639_1(opts.language_code)
    if lc then body.language_code = lc end
  end

  ensure_dir(tmp_dir())
  local body_path = tmp_dir() .. path_sep()
                 .. ('tts_body_%x_%x.json'):format(os.time(), math.random(0, 0xFFFFFF))
  if not util.write_file(body_path, json.encode(body)) then
    return { status = 'error', error = 'cannot write tts body file', op = 'tts' }
  end

  local output_format = opts.output_format or 'mp3_44100_128'

  -- M5-1: with_timestamps → wariant endpointu z alignmentem znakowym w
  -- JSON response (1 request zamiast TTS + forced-alignment). Worker case
  -- tts_ts pisze JSON do tmp; poll dekoduje base64 → mp3 w cache (atomic).
  if opts.with_timestamps then
    local url = ('https://api.elevenlabs.io/v1/text-to-speech/%s/with-timestamps?output_format=%s')
      :format(opts.voice_id, output_format)
    local out_path, sentinel_path = unique_paths('tts_ts')
    local cmd = table.concat({
      util.shell_escape(worker_path()),
      util.shell_escape('tts_ts'),
      util.shell_escape(cfg.get_curl_path()),
      util.shell_escape(url),
      util.shell_escape(key_file),
      util.shell_escape(body_path),
      util.shell_escape(out_path),
      util.shell_escape(sentinel_path),
    }, ' ')
    util.exec_worker(cmd)
    return {
      op            = 'tts_ts',
      status        = 'running',
      started_at    = util.now(),
      sentinel_path = sentinel_path,
      output_path   = out_path,
      cache_path    = cache_path,          -- finalne mp3 po dekodzie
      body_path     = body_path,           -- cleanup w poll
      args          = opts,
    }
  end

  local url = ('https://api.elevenlabs.io/v1/text-to-speech/%s?output_format=%s'):format(
    opts.voice_id, output_format)

  local sentinel_path = tmp_dir() .. path_sep()
                     .. ('tts_%x_%x.done'):format(os.time(), math.random(0, 0xFFFFFF))

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape('tts'),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(body_path),
    util.shell_escape(cache_path),
    util.shell_escape(sentinel_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    op            = 'tts',
    status        = 'running',
    started_at    = util.now(),
    sentinel_path = sentinel_path,
    output_path   = cache_path,
    body_path     = body_path,           -- cleanup w poll
    args          = opts,
  }
end

----------------------------------------------------------------------------
-- NS-2c: spawn_dialogue(opts) — async multi-speaker TTS via /v1/text-to-dialogue.
-- Mirror spawn_tts pattern (POST JSON body, binary mp3 response, cache hit → synthetic done).
--
-- opts:
--   inputs        — array of { text, voice_id } (required, max 10 unique voice_ids, ~2000 chars total)
--   settings      — table { stability } (optional, per-request global)
--   seed          — int (optional, 0 = random per call)
--   output_format — string (default mp3_44100_128)
--   model_id      — string (default 'eleven_v3', only supported value)
--
-- Returns handle z .from_cache=true gdy cache hit (skip char counter billing).
----------------------------------------------------------------------------
function M.spawn_dialogue(opts)
  opts = opts or {}
  if type(opts.inputs) ~= 'table' or #opts.inputs == 0 then
    return { status = 'error', error = 'empty inputs', op = 'dialogue' }
  end
  -- Validate each input has text + voice_id
  for i, it in ipairs(opts.inputs) do
    if type(it) ~= 'table' or not it.text or it.text == '' then
      return { status = 'error', error = ('inputs[%d].text empty'):format(i), op = 'dialogue' }
    end
    if not it.voice_id or it.voice_id == '' then
      return { status = 'error', error = ('inputs[%d].voice_id empty'):format(i), op = 'dialogue' }
    end
  end

  -- Cache hit → synthetic done (eliminuje worker spawn dla powtórzonych dialogues).
  -- M5-2: przy with_timestamps hit wymaga też sidecara alignmentu (mirror
  -- spawn_tts M5-1) — stary cache bez sidecara = jednorazowy re-render.
  local tts = require 'modules.tts'
  local cache_path = tts.dialogue_cache_path_for(opts)
  if cache_path and util.file_exists(cache_path)
     and (util.file_size(cache_path) or 0) > 1024 then
    local alignment = nil
    local sidecar_ok = true
    if opts.with_timestamps then
      sidecar_ok = false
      local raw = util.read_file(cache_path .. '.align.json')
      if raw and raw ~= '' then
        local okj, decoded = pcall(json.decode, raw)
        if okj and type(decoded) == 'table' and type(decoded.words) == 'table' then
          alignment  = decoded
          sidecar_ok = true
        end
      end
    end
    if sidecar_ok then
      return {
        op         = 'dialogue',
        status     = 'done',
        result     = cache_path,
        alignment  = alignment,
        started_at = util.now(),
        elapsed    = 0,
        from_cache = true,   -- prevents char counter billing on cache hits
        args       = opts,
      }
    end
  end

  local key = cfg.get_api_key()
  if not key or key == '' then return { status = 'error', error = 'no API key', op = 'dialogue' } end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then return { status = 'error', error = kerr or 'no key file', op = 'dialogue' } end

  -- Body JSON
  local body = {
    inputs   = opts.inputs,
    model_id = opts.model_id or 'eleven_v3',
  }
  if type(opts.settings) == 'table' then body.settings = opts.settings end
  if opts.seed and tonumber(opts.seed) and opts.seed > 0 then
    body.seed = math.floor(opts.seed)
  end
  -- HOTFIX 2026-07-11: normalizacja kodu języka (mirror spawn_tts).
  do
    local lc = util.iso639_1(opts.language_code)
    if lc then body.language_code = lc end
  end

  ensure_dir(tmp_dir())
  local body_path = tmp_dir() .. path_sep()
                 .. ('dialogue_body_%x_%x.json'):format(os.time(), math.random(0, 0xFFFFFF))
  if not util.write_file(body_path, json.encode(body)) then
    return { status = 'error', error = 'cannot write dialogue body file', op = 'dialogue' }
  end

  local output_format = opts.output_format or 'mp3_44100_128'

  -- M5-2: with_timestamps → JSON response z alignmentem całego pliku
  -- (+ voice_segments); mechanika workera identyczna z tts_ts (reuse case).
  if opts.with_timestamps then
    local url = ('https://api.elevenlabs.io/v1/text-to-dialogue/with-timestamps?output_format=%s')
      :format(output_format)
    local out_path, sentinel_path = unique_paths('dialogue_ts')
    local cmd = table.concat({
      util.shell_escape(worker_path()),
      util.shell_escape('tts_ts'),          -- ten sam case: POST JSON → JSON
      util.shell_escape(cfg.get_curl_path()),
      util.shell_escape(url),
      util.shell_escape(key_file),
      util.shell_escape(body_path),
      util.shell_escape(out_path),
      util.shell_escape(sentinel_path),
    }, ' ')
    util.exec_worker(cmd)
    return {
      op            = 'dialogue_ts',
      status        = 'running',
      started_at    = util.now(),
      sentinel_path = sentinel_path,
      output_path   = out_path,
      cache_path    = cache_path,
      body_path     = body_path,           -- cleanup w poll
      args          = opts,
    }
  end

  local url = ('https://api.elevenlabs.io/v1/text-to-dialogue?output_format=%s'):format(output_format)

  local sentinel_path = tmp_dir() .. path_sep()
                     .. ('dialogue_%x_%x.done'):format(os.time(), math.random(0, 0xFFFFFF))

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape('dialogue'),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(body_path),
    util.shell_escape(cache_path),
    util.shell_escape(sentinel_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    op            = 'dialogue',
    status        = 'running',
    started_at    = util.now(),
    sentinel_path = sentinel_path,
    output_path   = cache_path,
    body_path     = body_path,           -- cleanup w poll
    args          = opts,
  }
end

----------------------------------------------------------------------------
-- NS-SFX (2026-06-10): sound effects via POST /v1/sound-generation.
-- Mirror spawn_tts (JSON body → binary mp3 → deterministic cache path).
--
-- opts:
--   text             — prompt SFX (required; English audio terminology best)
--   duration_seconds — 0.5..30 (nil = model auto-guesses; tańsze ryzyko:
--                      billing 40 credits/s liczy się od finalnej długości)
--   prompt_influence — 0..1 (nil = API default 0.3)
--   loop             — bool (seamless loop, v2 model only)
--   variant_n        — int (część cache key — N wariantów tego samego promptu
--                      to N osobnych generacji; repeat z tym samym n = cache hit)
--   output_format    — default 'mp3_44100_128'
--   model_id         — default 'eleven_text_to_sound_v2'
----------------------------------------------------------------------------
function M.sfx_cache_path_for(opts)
  local key = string.format('sfx|%s|%s|%s|%s|%s|%s|%s',
    opts.text or '',
    tostring(opts.duration_seconds or 'auto'),
    tostring(opts.prompt_influence or 'default'),
    tostring(opts.loop or false),
    opts.output_format or 'mp3_44100_128',
    opts.model_id or 'eleven_text_to_sound_v2',
    tostring(opts.variant_n or 1))
  return tmp_dir() .. path_sep() .. ('sfx_%08x.mp3'):format(util.simple_hash(key))
end

function M.spawn_sfx(opts)
  opts = opts or {}
  if not opts.text or opts.text == '' then
    return { status = 'error', error = 'empty SFX prompt', op = 'sfx' }
  end

  local cache_path = M.sfx_cache_path_for(opts)
  if util.file_exists(cache_path) and (util.file_size(cache_path) or 0) > 1024 then
    return {
      op         = 'sfx',
      status     = 'done',
      result     = cache_path,
      started_at = util.now(),
      elapsed    = 0,
      from_cache = true,   -- skip credits counter on cache hits
      args       = opts,
    }
  end

  local key = cfg.get_api_key()
  if not key or key == '' then return { status = 'error', error = 'no API key', op = 'sfx' } end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then return { status = 'error', error = kerr or 'no key file', op = 'sfx' } end

  local body = {
    text     = opts.text,
    model_id = opts.model_id or 'eleven_text_to_sound_v2',
  }
  if tonumber(opts.duration_seconds) then
    body.duration_seconds = math.max(0.5, math.min(30, tonumber(opts.duration_seconds)))
  end
  if tonumber(opts.prompt_influence) then
    body.prompt_influence = math.max(0, math.min(1, tonumber(opts.prompt_influence)))
  end
  if opts.loop == true then body.loop = true end

  ensure_dir(tmp_dir())
  local body_path = tmp_dir() .. path_sep()
                 .. ('sfx_body_%x_%x.json'):format(os.time(), math.random(0, 0xFFFFFF))
  if not util.write_file(body_path, json.encode(body)) then
    return { status = 'error', error = 'cannot write sfx body file', op = 'sfx' }
  end

  local url = ('https://api.elevenlabs.io/v1/sound-generation?output_format=%s')
    :format(opts.output_format or 'mp3_44100_128')

  local sentinel_path = tmp_dir() .. path_sep()
                     .. ('sfx_%x_%x.done'):format(os.time(), math.random(0, 0xFFFFFF))

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape('sfx'),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(body_path),
    util.shell_escape(cache_path),
    util.shell_escape(sentinel_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    op            = 'sfx',
    status        = 'running',
    started_at    = util.now(),
    sentinel_path = sentinel_path,
    output_path   = cache_path,
    body_path     = body_path,           -- cleanup w poll
    args          = opts,
  }
end

----------------------------------------------------------------------------
-- NS-MUSIC (2026-06-10): music beds via POST /v1/music. Mirror spawn_sfx
-- (JSON body → binary mp3 → deterministic cache path). Per ElevenLabs docs:
-- prompt XOR composition_plan (używamy prompt), music_length_ms 3000-600000
-- (nil = model decyduje), force_instrumental dla podkładów pod narrację.
-- Koszt NIE jest stały (minuty muzyki z planu, przelicznik per tier) —
-- cost preview w panelu jest orientacyjny, from_cache nadal znaczący.
--
-- opts:
--   text             — music prompt (required; genre/mood/instrumentation/BPM/key)
--   duration_seconds — 3..600 (nil = model auto-decyduje)
--   instrumental     — bool (force_instrumental; default true dla scene beds)
--   variant_n        — int (część cache key, mirror sfx)
--   output_format    — default 'mp3_44100_128'
--   model_id         — default 'music_v1' (v2 nie ma jeszcze API — 2026-06)
----------------------------------------------------------------------------
function M.music_cache_path_for(opts)
  local key = string.format('music|%s|%s|%s|%s|%s|%s',
    opts.text or '',
    tostring(opts.duration_seconds or 'auto'),
    tostring(opts.instrumental ~= false),
    opts.output_format or 'mp3_44100_128',
    opts.model_id or 'music_v1',
    tostring(opts.variant_n or 1))
  return tmp_dir() .. path_sep() .. ('music_%08x.mp3'):format(util.simple_hash(key))
end

function M.spawn_music(opts)
  opts = opts or {}
  if not opts.text or opts.text == '' then
    return { status = 'error', error = 'empty music prompt', op = 'music' }
  end

  local cache_path = M.music_cache_path_for(opts)
  if util.file_exists(cache_path) and (util.file_size(cache_path) or 0) > 1024 then
    return {
      op         = 'music',
      status     = 'done',
      result     = cache_path,
      started_at = util.now(),
      elapsed    = 0,
      from_cache = true,
      args       = opts,
    }
  end

  local key = cfg.get_api_key()
  if not key or key == '' then return { status = 'error', error = 'no API key', op = 'music' } end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then return { status = 'error', error = kerr or 'no key file', op = 'music' } end

  local body = {
    prompt   = opts.text,
    model_id = opts.model_id or 'music_v1',
  }
  if tonumber(opts.duration_seconds) then
    local secs = math.max(3, math.min(600, tonumber(opts.duration_seconds)))
    body.music_length_ms = math.floor(secs * 1000 + 0.5)
  end
  -- 2026-07-11 (referencja /v1/music zweryfikowana online): force_instrumental
  -- działa TYLKO z music_v1. Dla music_v2 wymuszamy w PROMPCIE — append PO
  -- policzeniu cache_path (instrumental i model są w kluczu, body zostaje
  -- deterministyczne dla tych samych wejść).
  if opts.instrumental ~= false then
    if body.model_id == 'music_v1' then
      body.force_instrumental = true
    else
      body.prompt = body.prompt .. ' Instrumental only - no vocals, no lyrics.'
    end
  end

  ensure_dir(tmp_dir())
  local body_path = tmp_dir() .. path_sep()
                 .. ('music_body_%x_%x.json'):format(os.time(), math.random(0, 0xFFFFFF))
  if not util.write_file(body_path, json.encode(body)) then
    return { status = 'error', error = 'cannot write music body file', op = 'music' }
  end

  local url = ('https://api.elevenlabs.io/v1/music?output_format=%s')
    :format(opts.output_format or 'mp3_44100_128')

  local sentinel_path = tmp_dir() .. path_sep()
                     .. ('music_%x_%x.done'):format(os.time(), math.random(0, 0xFFFFFF))

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape('music'),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(body_path),
    util.shell_escape(cache_path),
    util.shell_escape(sentinel_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    op            = 'music',
    status        = 'running',
    started_at    = util.now(),
    sentinel_path = sentinel_path,
    output_path   = cache_path,
    body_path     = body_path,           -- cleanup w poll
    args          = opts,
  }
end

----------------------------------------------------------------------------
-- NS-B Dubbing: spawn_similar_voices(audio_path, opts) — async POST
-- /v1/similar-voices. Multipart upload reference audio → JSON response z top_k
-- candidates list. Field name 'audio_file' (NIE 'file' — verified per audit).
--
-- opts: { similarity_threshold (0..2, lower=closer, default API decide),
--         top_k (1..100, default API decide) }
--
-- Result on poll done: { voices=[{voice_id, public_owner_id, name, language,
--                                  gender, age, accent, descriptive, preview_url, ...}],
--                        has_more, total_count }
----------------------------------------------------------------------------
function M.spawn_similar_voices(audio_path, opts)
  opts = opts or {}
  if not audio_path or audio_path == '' then
    return { op = 'similar_voices', status = 'error', error = 'empty audio path' }
  end
  if not util.file_exists(audio_path) then
    return { op = 'similar_voices', status = 'error', error = 'audio file not found: ' .. audio_path }
  end

  local key = cfg.get_api_key()
  if not key or key == '' then
    return { op = 'similar_voices', status = 'error', error = 'no API key' }
  end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then
    return { op = 'similar_voices', status = 'error', error = kerr or 'no key file' }
  end

  local out_path, sentinel_path = unique_paths('similar_voices')
  local url = API_BASE .. '/v1/similar-voices'

  -- Optional form fields: passed jako positional args do worker'a. Empty str
  -- = skip pole (worker case handles conditional include).
  local similarity = (opts.similarity_threshold ~= nil) and tostring(opts.similarity_threshold) or ''
  local top_k      = (opts.top_k ~= nil) and tostring(opts.top_k) or ''

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape('similar_voices'),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(audio_path),
    util.shell_escape(out_path),
    util.shell_escape(sentinel_path),
    util.shell_escape(similarity),
    util.shell_escape(top_k),
  }, ' ')

  util.exec_worker(cmd)

  return {
    op            = 'similar_voices',
    status        = 'running',
    started_at    = util.now(),
    sentinel_path = sentinel_path,
    output_path   = out_path,
    args          = { audio_path = audio_path, similarity_threshold = opts.similarity_threshold, top_k = opts.top_k },
  }
end

----------------------------------------------------------------------------
-- NS-B M4.1: Voice Design — text-to-voice (2-step API).
--
-- Step 1: spawn_voice_design_previews(opts) → handle. opts: {
--   voice_description (string, plain English, descriptive),
--   text       (string, sample utterance, recommend 100-1000 chars),
--   model_id   ('eleven_multilingual_v2' default; v3 = better quality dla styles),
--   loudness   (-1..1, default 0.5),
--   guidance_scale (0..100, default 5; lower = more variation),
-- }
-- On done: handle.result = { previews = [{ audio_base64, generated_voice_id,
--                                          media_type='audio/mpeg', duration_secs }] }.
--
-- Step 2: spawn_voice_design_create(opts) → handle. opts: {
--   voice_name (string, becomes voice library entry name),
--   voice_description (same string used dla step 1 — required),
--   generated_voice_id (z preview user picked),
--   played_not_selected_voice_ids = {ids} (optional — improves future variety),
-- }
-- On done: handle.result = { voice_id, name, ... } — permanent voice w library.
----------------------------------------------------------------------------
function M.spawn_voice_design_previews(opts)
  opts = opts or {}
  if not opts.voice_description or opts.voice_description == '' then
    return { op = 'voice_design_previews', status = 'error', error = 'voice_description required' }
  end
  if not opts.text or opts.text == '' then
    return { op = 'voice_design_previews', status = 'error', error = 'sample text required' }
  end

  local key = cfg.get_api_key()
  if not key or key == '' then
    return { op = 'voice_design_previews', status = 'error', error = 'no API key' }
  end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then
    return { op = 'voice_design_previews', status = 'error', error = kerr or 'no key file' }
  end

  local body = {
    voice_description = opts.voice_description,
    text              = opts.text,
    model_id          = opts.model_id or 'eleven_multilingual_v2',
    loudness          = opts.loudness or 0.5,
    guidance_scale    = opts.guidance_scale or 5,
  }
  local ok_e, encoded = pcall(json.encode, body)
  if not ok_e then
    return { op = 'voice_design_previews', status = 'error', error = 'JSON encode body failed' }
  end

  util.mkdir_p(tmp_dir())
  local body_path = tmp_dir() .. path_sep()
                 .. ('vdesign_body_%x_%x.json'):format(os.time(), math.random(0, 0xFFFFFF))
  if not util.write_file(body_path, encoded) then
    return { op = 'voice_design_previews', status = 'error', error = 'cannot write body file' }
  end

  local out_path, sentinel_path = unique_paths('voice_design_previews')
  local url = API_BASE .. '/v1/text-to-voice/create-previews'

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape('voice_design_previews'),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(body_path),
    util.shell_escape(out_path),
    util.shell_escape(sentinel_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    op            = 'voice_design_previews',
    status        = 'running',
    started_at    = util.now(),
    sentinel_path = sentinel_path,
    output_path   = out_path,
    body_path     = body_path,
    args          = opts,
  }
end

function M.spawn_voice_design_create(opts)
  opts = opts or {}
  if not opts.voice_name or opts.voice_name == '' then
    return { op = 'voice_design_create', status = 'error', error = 'voice_name required' }
  end
  if not opts.voice_description or opts.voice_description == '' then
    return { op = 'voice_design_create', status = 'error', error = 'voice_description required' }
  end
  if not opts.generated_voice_id or opts.generated_voice_id == '' then
    return { op = 'voice_design_create', status = 'error', error = 'generated_voice_id required' }
  end

  local key = cfg.get_api_key()
  if not key or key == '' then
    return { op = 'voice_design_create', status = 'error', error = 'no API key' }
  end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then
    return { op = 'voice_design_create', status = 'error', error = kerr or 'no key file' }
  end

  local body = {
    voice_name         = opts.voice_name,
    voice_description  = opts.voice_description,
    generated_voice_id = opts.generated_voice_id,
  }
  if type(opts.played_not_selected_voice_ids) == 'table' and #opts.played_not_selected_voice_ids > 0 then
    body.played_not_selected_voice_ids = opts.played_not_selected_voice_ids
  end
  local ok_e, encoded = pcall(json.encode, body)
  if not ok_e then
    return { op = 'voice_design_create', status = 'error', error = 'JSON encode body failed' }
  end

  util.mkdir_p(tmp_dir())
  local body_path = tmp_dir() .. path_sep()
                 .. ('vdesign_create_%x_%x.json'):format(os.time(), math.random(0, 0xFFFFFF))
  if not util.write_file(body_path, encoded) then
    return { op = 'voice_design_create', status = 'error', error = 'cannot write body file' }
  end

  local out_path, sentinel_path = unique_paths('voice_design_create')
  local url = API_BASE .. '/v1/text-to-voice/create-voice-from-preview'

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape('voice_design_create'),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(body_path),
    util.shell_escape(out_path),
    util.shell_escape(sentinel_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    op            = 'voice_design_create',
    status        = 'running',
    started_at    = util.now(),
    sentinel_path = sentinel_path,
    output_path   = out_path,
    body_path     = body_path,
    args          = opts,
  }
end

----------------------------------------------------------------------------
-- Poll — idempotent (safe to call every frame). Mutates handle in-place.
----------------------------------------------------------------------------
function M.poll(handle)
  if not handle then return nil end
  if handle.status ~= 'running' then return handle end
  if not util.file_exists(handle.sentinel_path) then return handle end

  -- Sentinel + curl diagnostics przez shared async_op (M2-1, 2026-06-10).
  -- handle.http_code przepisany na handle — BUG fix: dubbing.lua sprawdza
  -- h.http_code == 429 dla TTS retry, a voice_admin NIGDY go nie ustawiał →
  -- retry-on-429 dla Dubbing TTS był martwym kodem (każdy rate-limit =
  -- finalny błąd segmentu). Wykryte przy ekstrakcji M2-1.
  local sent = async_op.read_sentinel(handle)
  local http_code = sent.http_code
  handle.http_code = http_code

  -- Body (binary dla tts/dialogue/sfx/music; JSON dla pozostałych ops)
  local body
  if handle.op == 'tts' or handle.op == 'dialogue' or handle.op == 'sfx' or handle.op == 'music' then
    -- Output to cache_path (deterministic). Nie czytamy zawartości binary —
    -- check size only. Body cleanup w success branch.
    body = ''
    if handle.body_path then os.remove(handle.body_path) end
  else
    body = util.read_file(handle.output_path) or ''
    os.remove(handle.output_path)
  end

  handle.elapsed = util.now() - handle.started_at

  if http_code < 200 or http_code >= 300 then
    handle.status = 'error'
    -- TTS/dialogue/sfx/music error path: JSON error response ląduje w
    -- $OUT.part (M1-2 atomic download — worker robi mv do cache path TYLKO
    -- po 2xx). Czytamy tu, usuwamy.
    if handle.op == 'tts' or handle.op == 'dialogue' or handle.op == 'sfx' or handle.op == 'music' then
      local part_path = handle.output_path .. '.part'
      body = util.read_file(part_path) or ''
      os.remove(part_path)
    end
    -- JSON detail / transport diagnostics przez shared helper (M2-1).
    handle.error = async_op.format_http_error(nil, sent, body)
    return handle
  end

  -- Cleanup body files for ops że je tworzą.
  if handle.op == 'add_shared' and handle.body_path then
    os.remove(handle.body_path)
  end

  -- Op-specific result parse
  if handle.op == 'tts' or handle.op == 'dialogue' or handle.op == 'sfx' or handle.op == 'music' then
    local sz = util.file_size(handle.output_path) or 0
    if sz < 1024 then
      os.remove(handle.output_path)
      handle.status = 'error'
      handle.error  = ('%s returned suspiciously small file (%d bytes)'):format(
        handle.op == 'dialogue' and 'Dialogue'
          or (handle.op == 'sfx' and 'SFX' or (handle.op == 'music' and 'Music' or 'TTS')), sz)
      return handle
    end
    handle.result = handle.output_path
  elseif handle.op == 'tts_ts' or handle.op == 'dialogue_ts' then
    -- M5-1/M5-2: JSON {audio_base64, alignment} → mp3 do cache (atomic
    -- .part → rename, mirror M1-2) + sidecar <cache>.align.json (cache hit
    -- z alignmentem przy powtórce) + handle.alignment (kształt forced-align).
    -- dialogue_ts dodatkowo niesie voice_segments (mapa input→zakres czasu).
    if handle.body_path then os.remove(handle.body_path) end
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= 'table'
       or type(decoded.audio_base64) ~= 'string' or decoded.audio_base64 == '' then
      handle.status = 'error'; handle.error = 'with-timestamps response missing audio_base64'
      return handle
    end
    local audio = util.base64_decode(decoded.audio_base64)
    if not audio or #audio < 1024 then
      handle.status = 'error'
      handle.error  = ('with-timestamps audio decode failed (%d bytes)'):format(audio and #audio or 0)
      return handle
    end
    local forced_align = require 'modules.forced_align'
    local alignment = forced_align.words_from_char_alignment(decoded.alignment)
    local part = handle.cache_path .. '.part'
    if not util.write_file(part, audio) then
      handle.status = 'error'; handle.error = 'cannot write decoded audio to cache'
      return handle
    end
    os.remove(handle.cache_path)
    local okmv = os.rename(part, handle.cache_path)
    if not okmv then
      os.remove(part)
      handle.status = 'error'; handle.error = 'cannot publish decoded audio to cache'
      return handle
    end
    if alignment then
      -- dialogue_ts: voice_segments (mapa input→zakres czasu) do sidecara
      -- i handle'a — konsument (take alignment) może kiedyś użyć.
      if type(decoded.voice_segments) == 'table' then
        alignment.voice_segments = decoded.voice_segments
      end
      local okenc, enc = pcall(json.encode, alignment)
      if okenc then util.write_file(handle.cache_path .. '.align.json', enc) end
    end
    handle.result    = handle.cache_path
    handle.alignment = alignment   -- nil gdy API nie zwróciło alignmentu
  elseif handle.op == 'train' then
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= 'table' or not decoded.voice_id then
      handle.status = 'error'; handle.error = 'IVC response missing voice_id'
      return handle
    end
    handle.result = decoded.voice_id
  elseif handle.op == 'delete' then
    handle.result = true
  elseif handle.op == 'rename' then
    handle.result = true
  elseif handle.op == 'shared_list' then
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= 'table' or type(decoded.voices) ~= 'table' then
      handle.status = 'error'; handle.error = 'shared-voices response malformed'
      return handle
    end
    handle.result = {
      voices      = decoded.voices,
      has_more    = decoded.has_more or false,
      total_count = decoded.last_sort_id and -1 or (decoded.total_count or 0),
    }
  elseif handle.op == 'add_shared' then
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= 'table' or not decoded.voice_id then
      handle.status = 'error'; handle.error = 'add_shared response missing voice_id'
      return handle
    end
    handle.result = decoded.voice_id
  elseif handle.op == 'similar_voices' then
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= 'table' or type(decoded.voices) ~= 'table' then
      handle.status = 'error'; handle.error = 'similar-voices response malformed'
      return handle
    end
    handle.result = {
      voices      = decoded.voices,
      has_more    = decoded.has_more or false,
      total_count = decoded.total_count or 0,
    }
  elseif handle.op == 'refresh' then
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= 'table' or type(decoded.voices) ~= 'table' then
      handle.status = 'error'; handle.error = 'voices response malformed'
      return handle
    end
    -- Mapowanie entry → nasz kształt przez api.merge_voices_page (M3-2 —
    -- jedno źródło; type-guard fine_tuning.state w środku).
    handle._acc = api.merge_voices_page(handle._acc or {}, decoded)
    local pages = handle._pages or 1
    -- M3-2: konta >100 głosów — kolejna strona na TYM SAMYM handle'u.
    -- Callerzy (Settings/Voice Manager/Picker Sync/Library) pollują dalej;
    -- 'done' dopiero gdy has_more=false lub cap stron.
    if decoded.has_more and decoded.next_page_token
        and decoded.next_page_token ~= '' and pages < api.MAX_VOICES_PAGES then
      local nh = spawn('refresh', { page_token = decoded.next_page_token },
                       handle._key_override)
      if nh.status == 'running' then
        handle.sentinel_path = nh.sentinel_path
        handle.output_path   = nh.output_path
        handle.started_at    = nh.started_at   -- stale-detection per strona
        handle._pages        = pages + 1
        return handle                          -- wciąż 'running'
      end
      -- Częściowa lista bez sygnału = user myśli, że widzi wszystko.
      handle.status = 'error'
      handle.error  = 'voices pagination failed: ' .. tostring(nh.error)
      return handle
    end
    handle.result = handle._acc
  elseif handle.op == 'quota' then
    -- /v1/user/subscription response shape: { character_count, character_limit,
    -- tier, next_character_count_reset_unix, ... }. Fields tonumber-coerced
    -- defensively (API zwraca consistent ints ale type check tani).
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= 'table' then
      handle.status = 'error'; handle.error = 'subscription response malformed'
      return handle
    end
    handle.result = {
      used       = tonumber(decoded.character_count) or 0,
      total      = tonumber(decoded.character_limit) or 0,
      tier       = decoded.tier or 'unknown',
      reset_unix = tonumber(decoded.next_character_count_reset_unix) or 0,
      -- M4-3: sloty głosów (modal sprzątania klonów przy Close projektu).
      -- Defensywnie nil gdy API nie zwróci pól.
      voice_slots_used = tonumber(decoded.voice_slots_used),
      voice_limit      = tonumber(decoded.voice_limit),
    }
  elseif handle.op == 'voice_design_previews' then
    -- M4.1 step 1 response: { previews: [{audio_base64, generated_voice_id, media_type, duration_secs?}] }
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= 'table' or type(decoded.previews) ~= 'table' then
      handle.status = 'error'; handle.error = 'voice-design previews response malformed'
      return handle
    end
    handle.result = { previews = decoded.previews }
    if handle.body_path then os.remove(handle.body_path) end
  elseif handle.op == 'voice_design_create' then
    -- M4.1 step 2 response: full voice object z voice_id
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= 'table' or not decoded.voice_id then
      handle.status = 'error'; handle.error = 'voice-design create response missing voice_id'
      return handle
    end
    handle.result = { voice_id = decoded.voice_id, name = decoded.name }
    if handle.body_path then os.remove(handle.body_path) end
  end

  handle.status = 'done'
  return handle
end

----------------------------------------------------------------------------
-- Spinner helper — rotating glyph driven by util.now() (~30 Hz).
-- Returns one z 4 ASCII chars: | / - \. Inter font ma wszystkie te glyphy.
----------------------------------------------------------------------------
local SPINNER_FRAMES = { '|', '/', '-', '\\' }
function M.spinner_glyph()
  local idx = (math.floor(util.now() * 8) % 4) + 1
  return SPINNER_FRAMES[idx]
end

return M
