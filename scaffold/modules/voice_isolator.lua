-- modules/voice_isolator.lua
-- NS-C: ElevenLabs Voice Isolator (POST /v1/audio-isolation).
-- Async via workers/worker_voice_op.sh 'isolate' mode (multipart audio →
-- binary mp3 out). Pattern mirrors voice_admin.spawn_tts.
--
-- Public:
--   cache_path_for(audio_path) → string | nil   — deterministic per file identity
--   spawn_isolate(audio_path)  → handle         — cache hit returns synthetic done
--   poll(handle)               → mutates status 'running' / 'done' / 'error'
--
-- Cache: reasonate_tmp/isolated_<8hex>.mp3 keyed on audio_path + file size.
-- Re-isolating same file is free (cache hit, zero API call).
--
-- Niezmiennik #2 utrzymany: source nigdy nie tknięty — cleaned audio zawsze
-- w reasonate_tmp/ jako osobny plik.

local util = require 'modules.util'
local cfg  = require 'modules.config'
local api  = require 'modules.api'
local async_op = require 'modules.async_op'   -- M2-1: shared sentinel/diag + consts

local M = {}

local API_URL = 'https://api.elevenlabs.io/v1/audio-isolation'

-- ElevenLabs constraint (HTTP 400 below this; learned empirically 2026-05-11
-- — nieujawnione w OpenAPI schema). Sub-threshold items return synthetic
-- 'skipped' status; caller fall-through na raw audio.
M.MIN_DURATION_SECS = 4.6

-- Polish #5 (PM5): retry-on-429 (rate limit). Mirror pattern z modes/dubbing.lua
-- (MAX_429_RETRIES + exponential backoff 1s/2s/4s). Internal do poll() — caller
-- widzi handle nadal 'running' (transparent retry).
local MAX_429_RETRIES    = async_op.MAX_RETRIES      -- M2-2: shared consts
local RETRY_BACKOFF_SECS = async_op.RETRY_BACKOFF

local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

local function worker_path()
  local _, this_path = reaper.get_action_context()
  local scaffold_dir = this_path and this_path:match('(.+)[/\\]') or ''
  return util.worker_script(scaffold_dir .. path_sep() .. 'workers' .. path_sep() .. 'worker_voice_op.sh')
end

----------------------------------------------------------------------------
-- Cache key: hash(audio_path + '|' + file_size). Stable as long as file
-- identity doesn't change. If user replaces source externally, size shifts →
-- new key → fresh isolate (correct behavior).
----------------------------------------------------------------------------
function M.cache_path_for(audio_path)
  if not audio_path or audio_path == '' then return nil end
  local sz = util.file_size(audio_path)
  if not sz then return nil end
  local key = ('%08x'):format(util.simple_hash(audio_path .. '|' .. tostring(sz)))
  return tmp_dir() .. path_sep() .. ('isolated_%s.mp3'):format(key)
end

----------------------------------------------------------------------------
-- spawn_isolate(audio_path, opts) → handle
-- opts.duration_secs (optional) — gdy < MIN_DURATION_SECS, returns synthetic
--   { status='skipped', reason='too_short' } przed dotknięciem API. Caller
--   ma fall-through-ować na original audio path (raw, bez czyszczenia).
-- Cache hit → synthetic done (status='done', result=cache_path).
-- Else ExecProcess(-1) worker, returns running handle.
----------------------------------------------------------------------------
function M.spawn_isolate(audio_path, opts)
  opts = opts or {}
  if not audio_path or audio_path == '' then
    return { op = 'isolate', status = 'error', error = 'empty audio path' }
  end
  if not util.file_exists(audio_path) then
    return { op = 'isolate', status = 'error', error = 'audio file not found: ' .. tostring(audio_path) }
  end

  -- Pre-flight duration check (gdy caller poda duration). ElevenLabs API
  -- rzuca HTTP 400 "Audio duration is X seconds, which is below the minimum
  -- of 4.6 seconds" — pre-check oszczędza wywołanie API + lepsze UX.
  if opts.duration_secs and opts.duration_secs < M.MIN_DURATION_SECS then
    return {
      op             = 'isolate',
      status         = 'skipped',
      reason         = 'too_short',
      duration_secs  = opts.duration_secs,
      min_required   = M.MIN_DURATION_SECS,
      started_at     = util.now(),
      elapsed        = 0,
      args           = { audio_path = audio_path },
    }
  end

  local cache_path = M.cache_path_for(audio_path)
  if not cache_path then
    return { op = 'isolate', status = 'error', error = 'cannot compute cache path' }
  end

  -- Cache hit (>1KB sanity check against partial writes).
  if util.file_exists(cache_path) and (util.file_size(cache_path) or 0) > 1024 then
    return {
      op         = 'isolate',
      status     = 'done',
      result     = cache_path,
      started_at = util.now(),
      elapsed    = 0,
      args       = { audio_path = audio_path },
    }
  end

  local key = cfg.get_api_key()
  if not key or key == '' then
    return { op = 'isolate', status = 'error', error = 'no API key' }
  end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then
    return { op = 'isolate', status = 'error', error = kerr or 'no key file' }
  end

  util.mkdir_p(tmp_dir())
  local job_id = ('isolate_%x_%x'):format(os.time(), math.random(0, 0xFFFFFF))
  local sentinel_path = tmp_dir() .. path_sep() .. job_id .. '.done'

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape('isolate'),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(API_URL),
    util.shell_escape(key_file),
    util.shell_escape(audio_path),
    util.shell_escape(cache_path),
    util.shell_escape(sentinel_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    op            = 'isolate',
    status        = 'running',
    started_at    = util.now(),
    sentinel_path = sentinel_path,
    output_path   = cache_path,
    args          = { audio_path = audio_path },
  }
end

----------------------------------------------------------------------------
-- Internal helper: re-execute worker dla retry-on-429. Reuses handle's
-- audio_path + output_path (cache target stays the same). New sentinel path
-- generated per retry attempt.
----------------------------------------------------------------------------
local function respawn_worker(handle)
  local audio_path = handle.args and handle.args.audio_path
  if not audio_path or audio_path == '' then
    handle.status = 'error'
    handle.error  = 'cannot retry: audio_path missing from handle'
    return false
  end
  local key = cfg.get_api_key()
  if not key or key == '' then
    handle.status = 'error'
    handle.error  = 'cannot retry: no API key'
    return false
  end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then
    handle.status = 'error'
    handle.error  = kerr or 'cannot retry: no key file'
    return false
  end

  util.mkdir_p(tmp_dir())
  local job_id = ('isolate_retry_%x_%x'):format(os.time(), math.random(0, 0xFFFFFF))
  local new_sentinel = tmp_dir() .. path_sep() .. job_id .. '.done'

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape('isolate'),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(API_URL),
    util.shell_escape(key_file),
    util.shell_escape(audio_path),
    util.shell_escape(handle.output_path),
    util.shell_escape(new_sentinel),
  }, ' ')

  util.exec_worker(cmd)
  handle.sentinel_path = new_sentinel
  handle.waiting_retry = false
  return true
end

----------------------------------------------------------------------------
-- poll(handle) — idempotent. Read sentinel → check http_code → output file
-- size sanity check. On error, delete partial output (curl -o writes JSON
-- error response na non-2xx, treba usunąć żeby nie zaśmiecać cache).
--
-- Polish #5 (PM5): transparent retry-on-429. Gdy ElevenLabs odpowie 429:
-- → handle.waiting_retry = true + handle.retry_at = now + backoff
-- → handle.status pozostaje 'running' (caller-transparent)
-- → następne poll() po retry_at re-spawns worker via respawn_worker()
-- → max 3 retries (1s/2s/4s), po wyczerpaniu → handle.status='error'.
----------------------------------------------------------------------------
function M.poll(handle)
  if not handle then return nil end
  if handle.status ~= 'running' then return handle end

  -- Retry path: waiting po 429 backoff. Gdy retry_at osiągnięty → respawn.
  if handle.waiting_retry then
    if util.now() < (handle.retry_at or 0) then return handle end
    respawn_worker(handle)
    return handle
  end

  if not util.file_exists(handle.sentinel_path) then return handle end

  -- Sentinel przez shared async_op (M2-1) — zyskujemy stderr/curl_exit diag.
  local sent = async_op.read_sentinel(handle)
  local http_code = sent.http_code
  handle.http_code = http_code

  handle.elapsed = util.now() - handle.started_at

  if http_code < 200 or http_code >= 300 then
    -- Polish #5: rate-limit → schedule transparent retry zamiast hard fail.
    if http_code == 429 and (handle.retries or 0) < MAX_429_RETRIES then
      handle.retries = (handle.retries or 0) + 1
      local delay = RETRY_BACKOFF_SECS[handle.retries] or 4
      handle.retry_at = util.now() + delay
      handle.waiting_retry = true
      -- Cleanup error body (M1-2: non-2xx zostaje w $OUT.part — worker
      -- publikuje do cache path tylko po 2xx).
      os.remove(handle.output_path .. '.part')
      handle.retry_msg = ('Rate-limited (429); retry %d/%d in %.1fs'):format(
        handle.retries, MAX_429_RETRIES, delay)
      return handle    -- nadal status='running'
    end

    handle.status = 'error'
    -- JSON error response ląduje w $OUT.part (M1-2 atomic download).
    local part_path = handle.output_path .. '.part'
    local body = util.read_file(part_path) or ''
    os.remove(part_path)
    handle.error = async_op.format_http_error('isolate', sent, body)
    if handle.retries and handle.retries > 0 then
      handle.error = handle.error .. (' (after %d retries)'):format(handle.retries)
    end
    return handle
  end

  -- Success: sanity check output size.
  local sz = util.file_size(handle.output_path) or 0
  if sz < 1024 then
    os.remove(handle.output_path)
    handle.status = 'error'
    handle.error  = ('isolator returned suspiciously small file (%d bytes)'):format(sz)
    return handle
  end

  handle.status = 'done'
  handle.result = handle.output_path
  return handle
end

return M
