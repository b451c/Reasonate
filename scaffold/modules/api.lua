-- modules/api.lua
-- ElevenLabs HTTP wrapper.
--   Sync calls (Faza 3): fetch_voices — krótki freeze GUI (tylko startup;
--     Settings przeszły na async w audit M2-2).
--   Async (Faza 5): spawn_convert — fire-and-forget przez worker.sh, sentinel
--     file polling w job_manager.lua.
--
-- Curl używa absolutnej ścieżki z ExtState (Faza 0) — bare 'curl' nie
-- działa pod macOS GUI REAPER.

local config   = require 'modules.config'
local json     = require 'modules.lib.json'
local async_op = require 'modules.async_op'
local util     = require 'modules.util'   -- Windows port: worker_script/exec_worker

local M = {}

local API_BASE = 'https://api.elevenlabs.io'

----------------------------------------------------------------------------
-- Shell escape (POSIX preferowane; api.lua ma własną kopię żeby nie wisieć
-- na util.lua tylko z tego powodu — historycznie napisana wcześniej)
----------------------------------------------------------------------------
local function shell_escape(s)
  s = tostring(s)
  if reaper.GetOS():find('Win') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function path_sep() return reaper.GetOS():find('Win') and '\\' or '/' end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

local function ensure_dir(path)
  -- Natywne API (2026-07-12): os.execute mkdir = okno konsoli per call
  -- na Windows (patrz util.mkdir_p — ten sam fix).
  if path and path ~= '' then
    reaper.RecursiveCreateDirectory(path, 0)
  end
end

local function unique_tmp_name(prefix, ext)
  return ('%s%s%s_%x_%x.%s'):format(
    tmp_dir(), path_sep(), prefix,
    os.time(), math.random(0, 0xFFFFFF),
    ext or 'tmp')
end

----------------------------------------------------------------------------
-- curl_get: synchroniczny GET, body przez plik (uniknięcie buforowania
-- w ExecProcess). Faza 3 i ogólnie wszystkie szybkie GET-y.
--
-- Klucz API trafia do curla przez `-H @keyfile` (NIGDY w argv) — invariant #1.
-- ensure_key_file pisze chmod-600 plik raz per session, reusowany przez
-- wszystkie sync i async ścieżki.
----------------------------------------------------------------------------
local function curl_get(path, api_key, opts)
  opts = opts or {}
  local key_file, kerr = M.ensure_key_file(api_key)
  if not key_file then return false, nil, kerr or 'no key file' end
  local curl_path = config.get_curl_path()
  local url = API_BASE .. path
  ensure_dir(tmp_dir())
  local body_path = unique_tmp_name('_resp', 'json')
  -- M2-4 (audit 2026-07): capture stderr curla (flaga --stderr — ExecProcess
  -- nie przechodzi przez shell, '2>' by nie zadziałało) + exit hint. Bez
  -- tego martwa sieć = "HTTP 0: invalid JSON" zamiast hintu DNS/timeout.
  local stderr_path = unique_tmp_name('_resp_err', 'txt')

  local cmd = table.concat({
    shell_escape(curl_path),
    '-sS',
    '--max-time', tostring(opts.max_time_secs or 35),
    '--stderr', shell_escape(stderr_path),
    '-H', shell_escape('@' .. key_file),
    '-o', shell_escape(body_path),
    '-w', shell_escape('%{http_code}'),
    shell_escape(url),
  }, ' ')

  local result = reaper.ExecProcess(cmd, opts.timeout_ms or 45000)

  local body = ''
  local f = io.open(body_path, 'rb')
  if f then body = f:read('*all') or ''; f:close() end
  os.remove(body_path)

  local stderr_txt = ''
  local fe = io.open(stderr_path, 'rb')
  if fe then stderr_txt = (fe:read('*all') or ''):gsub('%s+$', ''); fe:close() end
  os.remove(stderr_path)

  if not result or result == '' then
    return false, nil, 'no response from curl (ExecProcess returned nil — process killed)'
  end

  local nl = result:find('\n')
  local exec_exit = tonumber(nl and result:sub(1, nl - 1) or result) or -1
  local http_code_str = ((nl and result:sub(nl + 1) or ''):gsub('%s+', ''))
  local http_code = tonumber(http_code_str)

  local function transport_diag()
    local hint = async_op.curl_exit_hint(exec_exit)
    if stderr_txt ~= '' then
      hint = hint .. (' · %s'):format(stderr_txt:sub(1, 160))
    end
    return hint
  end

  if not http_code then
    return false, nil, ('curl exit %d, no HTTP response%s. Body: %s')
      :format(exec_exit, transport_diag(), body:sub(1, 200))
  end

  local ok, decoded = pcall(json.decode, body)
  if not ok then
    if http_code == 0 then
      -- Transport-level fail (DNS/timeout/SSL) — body puste/nie-JSON.
      return false, nil, ('no HTTP response%s'):format(transport_diag())
    end
    return false, nil, ('HTTP %d: invalid JSON (%s)%s')
      :format(http_code, tostring(decoded):sub(1, 200), transport_diag())
  end

  if http_code >= 200 and http_code < 300 then
    return true, decoded, nil
  end

  local msg = ('HTTP %d'):format(http_code)
  if type(decoded) == 'table' and decoded.detail then
    local d = decoded.detail
    if type(d) == 'table' then
      msg = msg .. ': ' .. (d.message or d.status or json.encode(d))
    elseif type(d) == 'string' then
      msg = msg .. ': ' .. d
    end
  end
  return false, decoded, msg
end

----------------------------------------------------------------------------
-- curl_post_multipart: synchroniczny POST multipart/form-data, body przez
-- plik. Phase 11 (Dialog Repair): używany dla Scribe STT (file upload + form
-- fields) i IVC voice cloning (sample audio upload).
--
-- fields: array of {key, value} (ordered for determinism)
-- file_field: name of file form field (e.g. 'file')
-- file_path: absolute path do pliku do uploadu
--
-- Zwraca (ok, decoded, err). decoded jest JSON table (lub raw body string
-- gdy opts.raw_body=true — np. dla TTS gdzie response jest binary mp3).
----------------------------------------------------------------------------
function M.curl_post_multipart(path, fields, file_field, file_path, api_key, opts)
  opts = opts or {}
  if not api_key or api_key == '' then return false, nil, 'empty API key' end
  local key_file, kerr = M.ensure_key_file(api_key)
  if not key_file then return false, nil, kerr or 'no key file' end
  local curl_path = config.get_curl_path()
  local url = API_BASE .. path
  ensure_dir(tmp_dir())
  local body_path = unique_tmp_name('_resp', opts.raw_body and 'bin' or 'json')

  local args = {
    shell_escape(curl_path),
    '-sS',
    '--max-time', tostring(opts.max_time_secs or 120),
    '-H', shell_escape('@' .. key_file),
  }
  for _, kv in ipairs(fields or {}) do
    args[#args + 1] = '-F'
    args[#args + 1] = shell_escape(tostring(kv[1]) .. '=' .. tostring(kv[2]))
  end
  if file_field and file_path and file_path ~= '' then
    args[#args + 1] = '-F'
    args[#args + 1] = shell_escape(file_field .. '=@' .. file_path)
  end
  args[#args + 1] = '-o';  args[#args + 1] = shell_escape(body_path)
  args[#args + 1] = '-w';  args[#args + 1] = shell_escape('%{http_code}')
  args[#args + 1] = shell_escape(url)

  local cmd = table.concat(args, ' ')
  local result = reaper.ExecProcess(cmd, opts.timeout_ms or 150000)

  local body = ''
  local f = io.open(body_path, 'rb')
  if f then body = f:read('*all') or ''; f:close() end
  if not opts.keep_body_file then os.remove(body_path) end

  if not result or result == '' then
    return false, nil, 'no response from curl (ExecProcess returned nil — process killed)'
  end

  local nl = result:find('\n')
  local exec_exit = tonumber(nl and result:sub(1, nl - 1) or result) or -1
  local http_code_str = ((nl and result:sub(nl + 1) or ''):gsub('%s+', ''))
  local http_code = tonumber(http_code_str)

  if not http_code then
    return false, nil, ('curl exit %d, no HTTP response. Body head: %s')
      :format(exec_exit, body:sub(1, 200))
  end

  if opts.raw_body then
    if http_code >= 200 and http_code < 300 then
      return true, body, nil
    end
    return false, body, ('HTTP %d (raw body, %d bytes)'):format(http_code, #body)
  end

  local ok, decoded = pcall(json.decode, body)
  if not ok then
    return false, nil, ('HTTP %d: invalid JSON (%s)'):format(http_code, tostring(decoded):sub(1, 200))
  end

  if http_code >= 200 and http_code < 300 then
    return true, decoded, nil
  end

  local msg = ('HTTP %d'):format(http_code)
  if type(decoded) == 'table' and decoded.detail then
    local d = decoded.detail
    if type(d) == 'table' then
      msg = msg .. ': ' .. (d.message or d.status or json.encode(d))
    elseif type(d) == 'string' then
      msg = msg .. ': ' .. d
    end
  end
  return false, decoded, msg
end

----------------------------------------------------------------------------
-- Voices page merge (M3-2, pure — headless-tested). Jedno miejsce mapowania
-- /v2/voices entry → nasz kształt; konsumenci: fetch_voices (sync, niżej)
-- + voice_admin.poll op 'refresh' (async, kontynuacja stron).
--
-- fine_tuning.state present tylko dla professional voice clones
-- (draft/queued/fine_tuning/fine_tuned/failed). UI Voice Manager pokazuje
-- "Training…" badge gdy state ≠ fine_tuned/nil.
-- DEFENSIVE: ElevenLabs zwraca state jako TABLE (per-language map) dla
-- niektórych voices — type-guard zapobiega concat crash w UI.
----------------------------------------------------------------------------
function M.merge_voices_page(acc, decoded)
  for _, v in ipairs((decoded and decoded.voices) or {}) do
    local fts = nil
    if type(v.fine_tuning) == 'table' and type(v.fine_tuning.state) == 'string' then
      fts = v.fine_tuning.state
    end
    acc[#acc + 1] = {
      voice_id        = v.voice_id,
      name            = v.name,
      category        = v.category,
      labels          = v.labels or {},
      preview_url     = v.preview_url,
      description     = v.description,
      is_owner        = v.is_owner,
      created_at_unix = v.created_at_unix,
      fine_tuning_state = fts,
    }
  end
  return acc
end

-- Safety cap paginacji: 10 stron × 100 głosów. Dubbing tworzy klony per
-- speaker per język, więc >100 głosów jest realne; >1000 = coś poszło źle.
M.MAX_VOICES_PAGES = 10

local function url_encode(s)
  return tostring(s):gsub('([^%w%-%._~])', function(c)
    return ('%%%02X'):format(c:byte())
  end)
end

----------------------------------------------------------------------------
-- Public: fetch_voices (Phase 3 sync API; jedyny żywy caller to zachowany
-- celowo martwy action_refresh_voices w reasonate.lua — startup ładuje
-- WYŁĄCZNIE cache dyskowy przez state.lua; świeży fetch = async
-- voice_admin.spawn_refresh). test_subscription USUNIĘTE 2026-07-02
-- (user OK) — Settings Test = async voice_admin.spawn_quota od M2-2.
----------------------------------------------------------------------------
function M.fetch_voices(api_key)
  if not api_key or api_key == '' then
    return false, nil, 'empty API key'
  end
  -- Custom voices mają duże entries (samples, fine_tuning, verification) —
  -- response potrafi być >500 KB i 5-15s pobierania per strona.
  -- M3-2: pętla po stronach — konta >100 głosów były ucinane do 1. strony.
  local out = {}
  local token = nil
  for _ = 1, M.MAX_VOICES_PAGES do
    local path = '/v2/voices?page_size=100'
    if token then path = path .. '&next_page_token=' .. url_encode(token) end
    local ok, decoded, err = curl_get(path, api_key)
    if not ok then return false, nil, err end
    if type(decoded) ~= 'table' or type(decoded.voices) ~= 'table' then
      return false, nil, 'response missing "voices" array'
    end
    M.merge_voices_page(out, decoded)
    token = decoded.has_more and decoded.next_page_token or nil
    if not token or token == '' then break end
  end
  return true, out, nil
end

----------------------------------------------------------------------------
-- Voices cache na dysku
----------------------------------------------------------------------------
local function cache_path()
  return tmp_dir() .. path_sep() .. 'voices.json'
end

function M.save_voices_cache(voices)
  ensure_dir(tmp_dir())
  local path = cache_path()
  local f = io.open(path, 'wb')
  if not f then return false, 'cannot open ' .. path end
  local payload = { fetched_at = os.time(), version = 1, voices = voices }
  local ok, encoded = pcall(json.encode, payload)
  if not ok then f:close(); return false, 'json encode failed' end
  f:write(encoded)
  f:close()
  return true
end

function M.load_voices_cache(max_age_seconds)
  local path = cache_path()
  local f = io.open(path, 'rb')
  if not f then return nil end
  local content = f:read('*all')
  f:close()
  local ok, decoded = pcall(json.decode, content)
  if not ok or type(decoded) ~= 'table' or type(decoded.voices) ~= 'table' then
    return nil
  end
  if max_age_seconds and decoded.fetched_at then
    local age = os.time() - decoded.fetched_at
    if age > max_age_seconds then return nil, 'expired', age end
  end
  return decoded.voices, decoded.fetched_at
end

----------------------------------------------------------------------------
-- API key file (shared by sync + async paths) + worker spawn (async only)
----------------------------------------------------------------------------
-- Worker.sh path resolved przez debug.getinfo (api.lua jest w scaffold/modules/,
-- worker.sh w scaffold/workers/).
local function this_module_dir()
  local src = debug.getinfo(1, 'S').source
  if src:sub(1, 1) == '@' then src = src:sub(2) end
  return src:match('(.+)[/\\][^/\\]+$') or '.'
end

local function worker_sh_path()
  -- Windows port (2026-07-11): util.worker_script podmienia .sh → .ps1.
  return util.worker_script(this_module_dir() .. path_sep() .. '..'
      .. path_sep() .. 'workers' .. path_sep() .. 'worker.sh')
end

local _worker_chmoded = false
local function ensure_worker_executable()
  if _worker_chmoded then return end
  if not reaper.GetOS():find('Win') then
    os.execute('chmod +x ' .. shell_escape(worker_sh_path()) .. ' 2>/dev/null')
  end
  _worker_chmoded = true
end

-- Klucz API trzymamy w pliku z chmod 600, żeby nie ląował w ps aux.
-- Pisany raz per session. Jeśli user zmieni klucz w settings → re-write.
local _key_file_path = nil
local _key_file_for  = nil
function M.ensure_key_file(api_key)
  if not api_key or api_key == '' then return nil, 'empty api key' end
  ensure_dir(tmp_dir())
  if _key_file_path and _key_file_for == api_key then
    -- check still exists
    local f = io.open(_key_file_path, 'rb')
    if f then f:close(); return _key_file_path end
  end
  local path = tmp_dir() .. path_sep() .. '.reasonate_key'
  -- M6-2: tmp → chmod → rename (bez okna TOCTOU) + błąd chmod logowany.
  local tmp_path = path .. '.tmp'
  local f = io.open(tmp_path, 'wb')
  if not f then return nil, 'cannot write key file: ' .. tmp_path end
  f:write('xi-api-key: ' .. api_key)
  f:close()
  if not reaper.GetOS():find('Win') then
    local ok_chmod = os.execute('chmod 600 ' .. shell_escape(tmp_path))
    if ok_chmod ~= true and ok_chmod ~= 0 then
      reaper.ShowConsoleMsg(('[Reasonate] warning: chmod 600 failed for %s\n'):format(tmp_path))
    end
  end
  os.remove(path)
  if not os.rename(tmp_path, path) then
    os.remove(tmp_path)
    return nil, 'cannot publish key file: ' .. path
  end
  _key_file_path = path
  _key_file_for  = api_key
  return path
end

-- M3-3 (audit 2026-06-10): wipe pliku klucza przy zamknięciu pluginu
-- (reaper.atexit). Plik jest chmod-600, ale nie ma powodu trzymać go na
-- dysku między sesjami — odtwarzany on-demand (ensure_key_file).
function M.wipe_key_file()
  os.remove(tmp_dir() .. path_sep() .. '.reasonate_key')
  _key_file_path, _key_file_for = nil, nil
end

----------------------------------------------------------------------------
-- M.spawn_convert(job) → ok, error_msg
--
-- job: {
--   voice_id, model_id, settings (table), seed, output_format,
--   remove_bg (bool), input_path, output_path, done_sentinel
-- }
--
-- Returns true (zlecenie spawnięte) or false+err. Po sukcesie nie czeka —
-- proces leci niezależnie, job_manager.tick() poll-uje done_sentinel.
----------------------------------------------------------------------------
function M.spawn_convert(job)
  -- Windows port (2026-07-11): gate "POSIX-only" usunięty — worker.ps1
  -- (util.exec_worker prefiksuje powershell.exe). Test: VM smoke.
  local api_key = config.get_api_key()
  if not api_key then return false, 'no API key' end

  local key_file, err = M.ensure_key_file(api_key)
  if not key_file then return false, err end

  ensure_worker_executable()

  local url = ('%s/v1/speech-to-speech/%s?output_format=%s'):format(
    API_BASE, job.voice_id, job.output_format or 'mp3_44100_128')

  local settings_json = json.encode(job.settings or {
    stability = 0.5, similarity_boost = 0.75, style = 0, use_speaker_boost = true,
  })
  -- JSON NIGDY inline w argv (2026-07-12, user-caught na VM): PowerShell
  -- -File gubi/zjada cudzysłowy w argumentach (i "" i \") → worker umiera
  -- przed startem, zero sentinela. Settings idą PLIKIEM; worker podaje
  -- pole formularza przez curl `-F "voice_settings=<plik"` (składnia `<`
  -- czyta wartość pola z pliku). Plik kasuje worker po curl-u.
  local settings_file = job.done_sentinel .. '.settings.json'
  if not util.write_file(settings_file, settings_json) then
    return false, 'cannot write settings file'
  end

  local cmd = table.concat({
    shell_escape(worker_sh_path()),
    shell_escape(config.get_curl_path()),
    shell_escape(url),
    shell_escape(key_file),
    shell_escape(job.input_path),
    shell_escape(job.model_id or 'eleven_multilingual_sts_v2'),
    shell_escape(settings_file),
    shell_escape(tostring(job.seed or 0)),
    shell_escape(tostring(job.remove_bg or false)),
    shell_escape(job.output_path),
    shell_escape(job.done_sentinel),
  }, ' ')

  -- Fire-and-forget. ExecProcess(-1) zwraca natychmiast.
  util.exec_worker(cmd)
  return true, nil
end

return M
