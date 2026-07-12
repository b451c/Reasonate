-- modules/forced_align.lua
-- NS-B Dubbing: ElevenLabs Forced Alignment (POST /v1/forced-alignment).
--
-- Async via workers/worker_forced_align.sh (mirror voice_isolator pattern).
-- Per-word + per-character timecodes wewnątrz wygenerowanego audio,
-- używane przez dubbing_splicer dla precyzyjnego per-word splice (lip-sync
-- awareness) — fallback do full-segment splice gdy źródło<>generated word count.
--
-- Response shape (verified per audit):
--   {
--     characters: [ {text, start, end} ],
--     words:      [ {text, start, end, loss} ],
--     loss: <avg confidence for whole transcript>
--   }
-- Time units = seconds (double).
--
-- Cache: reasonate_tmp/dub_align/<hash>.json keyed on (audio_path_size, text).
-- Deterministic — re-align same audio + same text = cache hit instant.

local util     = require 'modules.util'
local cfg      = require 'modules.config'
local api      = require 'modules.api'
local json     = require 'modules.lib.json'
local async_op = require 'modules.async_op'   -- M2-1: shared sentinel/diag

local M = {}

local API_URL = 'https://api.elevenlabs.io/v1/forced-alignment'

local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

local function align_cache_dir()
  return tmp_dir() .. path_sep() .. 'dub_align'
end

local function worker_path()
  local _, this_path = reaper.get_action_context()
  local scaffold_dir = this_path and this_path:match('(.+)[/\\]') or ''
  return util.worker_script(scaffold_dir .. path_sep() .. 'workers' .. path_sep() .. 'worker_forced_align.sh')
end

----------------------------------------------------------------------------
-- sanitize_text(text) → tekst wyłącznie wypowiadany.
--
-- Alignment oczekuje tekstu który FAKTYCZNIE pada w audio. Tłumaczenia
-- dubbingu mogą zawierać TTS markup, którego model nie wypowiada:
-- audio tagi v3 ([whispers], [pause], ...) oraz <break time="X.Xs"/>
-- (v2/turbo/flash — timing fit 2026-06-10). Surowe tagi psują dopasowanie
-- (model szuka niewypowiedzianych tokenów w audio). Wołane w spawn()
-- PRZED cache_key — klucz liczony z czystego tekstu.
----------------------------------------------------------------------------
function M.sanitize_text(text)
  if type(text) ~= 'string' or text == '' then return text end
  local out = text
    :gsub('<%s*break[^>]*>', ' ')     -- <break time="1.0s" /> (i warianty)
    :gsub('%[[^%]\n]*%]', ' ')        -- [whispers], [short pause], ...
    :gsub('%s+', ' ')
    :gsub('^%s+', '')
    :gsub('%s+$', '')
  return out
end

----------------------------------------------------------------------------
-- M5-1 (audit 2026-07, PURE — headless-tested): konwersja alignmentu
-- ZNAKOWEGO z /v1/text-to-speech/.../with-timestamps na kształt odpowiedzi
-- forced-alignment ({words, characters, loss}) — konsumenci splice/tempo
-- działają bez zmian. Words zawierają tokeny WHITESPACE (mirror realnego
-- serwisu — KNOWN-ISSUES: konsumenci mapują przez nth-nonspace).
-- al = { characters=[], character_start_times_seconds=[],
--        character_end_times_seconds=[] }
----------------------------------------------------------------------------
function M.words_from_char_alignment(al)
  if type(al) ~= 'table' or type(al.characters) ~= 'table'
     or #al.characters == 0 then
    return nil
  end
  local starts = al.character_start_times_seconds or {}
  local ends   = al.character_end_times_seconds or {}
  local words, cur = {}, nil
  local function flush()
    if cur then cur.is_space = nil; words[#words + 1] = cur; cur = nil end
  end
  for i, ch in ipairs(al.characters) do
    if type(ch) ~= 'string' then ch = tostring(ch or '') end
    local st = tonumber(starts[i]) or (cur and cur['end']) or 0
    local en = tonumber(ends[i]) or st
    local is_space = ch:match('^%s+$') ~= nil
    if cur and cur.is_space ~= is_space then flush() end
    if not cur then
      cur = { text = '', start = st, ['end'] = en, is_space = is_space }
    end
    cur.text  = cur.text .. ch
    cur['end'] = en
  end
  flush()
  return { words = words, characters = al.characters, loss = 0 }
end

----------------------------------------------------------------------------
-- Cache key + path. Stable jak długo audio file identity nie zmieni się.
-- Re-align tego samego audio z innym text = inny key (correct — różny output).
----------------------------------------------------------------------------
function M.cache_key(audio_path, text)
  if not audio_path or audio_path == '' then return nil end
  local sz = util.file_size(audio_path) or 0
  local input = audio_path .. '|' .. tostring(sz) .. '|' .. (text or '')
  return string.format('%08x', util.simple_hash(input))
end

function M.cache_path_for(audio_path, text)
  local key = M.cache_key(audio_path, text)
  if not key then return nil end
  util.mkdir_p(align_cache_dir())
  return align_cache_dir() .. path_sep() .. key .. '.json'
end

local function read_cache(cache_path)
  if not cache_path or not util.file_exists(cache_path) then return nil end
  local raw = util.read_file(cache_path)
  if not raw or raw == '' then return nil end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

----------------------------------------------------------------------------
-- spawn(audio_path, text, opts) → handle
--
-- Cache hit → synthetic done. Else fire-and-forget worker_forced_align.sh.
----------------------------------------------------------------------------
function M.spawn(audio_path, text, opts)
  opts = opts or {}
  if not audio_path or audio_path == '' then
    return { op = 'forced_align', status = 'error', error = 'empty audio path' }
  end
  if not util.file_exists(audio_path) then
    return { op = 'forced_align', status = 'error', error = 'audio file not found: ' .. audio_path }
  end
  if not text or text == '' then
    return { op = 'forced_align', status = 'error', error = 'empty text' }
  end
  text = M.sanitize_text(text)
  if text == '' then
    return { op = 'forced_align', status = 'error', error = 'text contains no spoken words (only TTS markup)' }
  end

  local cache_path = M.cache_path_for(audio_path, text)
  if not cache_path then
    return { op = 'forced_align', status = 'error', error = 'cannot compute cache path' }
  end

  local cached = read_cache(cache_path)
  if cached then
    return {
      op         = 'forced_align',
      status     = 'done',
      result     = cached,
      from_cache = true,
      started_at = util.now(),
      elapsed    = 0,
      cache_path = cache_path,
      args       = { audio_path = audio_path, text = text },
    }
  end

  local key = cfg.get_api_key()
  if not key or key == '' then
    return { op = 'forced_align', status = 'error', error = 'no ElevenLabs API key' }
  end
  local key_file, kerr = api.ensure_key_file(key)
  if not key_file then
    return { op = 'forced_align', status = 'error', error = kerr or 'no key file' }
  end

  util.mkdir_p(tmp_dir())
  local job_id = ('align_%x_%x'):format(os.time(), math.random(0, 0xFFFFFF))
  local sentinel_path = tmp_dir() .. path_sep() .. job_id .. '.done'
  local output_path   = tmp_dir() .. path_sep() .. job_id .. '.json'

  -- Write text to file → pass path to worker → curl uses `-F text=<@file`.
  -- Bypasses ALL shell escaping issues (nested quotes, em dashes, smart quotes,
  -- backticks, $vars, etc.). Critical dla dialogue translations które zawierają
  -- nested "quoted speech".
  local text_path = tmp_dir() .. path_sep() .. job_id .. '.txt'
  if not util.write_file(text_path, text) then
    return { op = 'forced_align', status = 'error', error = 'cannot write text file: ' .. text_path }
  end

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(API_URL),
    util.shell_escape(key_file),
    util.shell_escape(audio_path),
    util.shell_escape(text_path),
    util.shell_escape(output_path),
    util.shell_escape(sentinel_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    op            = 'forced_align',
    status        = 'running',
    started_at    = util.now(),
    sentinel_path = sentinel_path,
    output_path   = output_path,
    text_path     = text_path,
    cache_path    = cache_path,
    args          = { audio_path = audio_path, text = text },
  }
end

----------------------------------------------------------------------------
-- poll(handle) — idempotent.
----------------------------------------------------------------------------
function M.poll(handle)
  if not handle then return nil end
  if handle.status ~= 'running' then return handle end
  if not util.file_exists(handle.sentinel_path) then return handle end

  -- Sentinel + curl diagnostics przez shared async_op (M2-1, 2026-06-10) —
  -- wcześniej ten blok był verbatim kopią voice_admin.poll/stt.poll_transcribe.
  local sent = async_op.read_sentinel(handle)
  handle.http_code = sent.http_code

  local body = util.read_file(handle.output_path) or ''
  os.remove(handle.output_path)
  if handle.text_path then os.remove(handle.text_path) end

  handle.elapsed = util.now() - handle.started_at

  if sent.http_code < 200 or sent.http_code >= 300 then
    handle.status = 'error'
    handle.error  = async_op.format_http_error('forced-align', sent, body)
    return handle
  end

  local ok, decoded = pcall(json.decode, body)
  if not ok or type(decoded) ~= 'table' then
    handle.status = 'error'
    handle.error  = 'forced-align response not JSON'
    return handle
  end
  if type(decoded.words) ~= 'table' then
    handle.status = 'error'
    handle.error  = 'forced-align response missing words[] array'
    return handle
  end

  util.write_file(handle.cache_path, body)

  handle.status = 'done'
  handle.result = decoded
  return handle
end

return M
