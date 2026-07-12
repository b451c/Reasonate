-- modules/update_check.lua — "Check for updates" (PHASE-USER-GUIDE §3).
--
-- Źródło wersji: GitHub Releases API (GET /repos/<slug>/releases/latest,
-- tag_name vs config.APP_VERSION). Async przez workers/worker_update
-- (sentinel triplet; publiczny endpoint, zero API key). Zero auto-instalacji
-- — od dystrybucji jest ReaPack; wynik to tekst + [Open releases].
--
-- Gating: config.UPDATE_REPO == '' (przed publikacją) = feature wyłączony
-- (przycisk w About ukryty, cichy check nie startuje).
--
-- Pure helpers (parse_version / is_newer) — headless-tested w tests/run.lua.

local util     = require 'modules.util'
local cfg      = require 'modules.config'
local async_op = require 'modules.async_op'
local json     = require 'modules.lib.json'

local M = {}

local NS = 'Reasonate'
local AUTO_CHECK_INTERVAL_SECS = 24 * 3600   -- cichy check max 1×/24 h

----------------------------------------------------------------------------
-- Pure: wersje. parse_version('v1.2.3-rc1') → {1, 2, 3, pre = 1}.
-- Final release ma pre = math.huge (final > każdy pre-release tej samej
-- triady). Suffix bez cyfry ('-beta') → pre = 0. Malformed → nil.
----------------------------------------------------------------------------
function M.parse_version(s)
  if type(s) ~= 'string' then return nil end
  s = s:match('^%s*(.-)%s*$'):gsub('^[vV]', '')
  local maj, min = s:match('^(%d+)%.(%d+)')
  if not maj then return nil end
  local patch = s:match('^%d+%.%d+%.(%d+)') or '0'
  local rest = s:match('^%d+%.%d+%.?%d*(.*)$') or ''
  local pre
  if rest == '' then
    pre = math.huge
  else
    pre = tonumber(rest:match('(%d+)%s*$')) or 0
  end
  return { tonumber(maj), tonumber(min), tonumber(patch), pre = pre }
end

function M.is_newer(remote_str, local_str)
  local r, l = M.parse_version(remote_str), M.parse_version(local_str)
  if not r or not l then return false end
  for i = 1, 3 do
    if r[i] ~= l[i] then return r[i] > l[i] end
  end
  return r.pre > l.pre
end

----------------------------------------------------------------------------
-- Stan modułu: jeden check naraz; wynik ostatniego checku tej sesji +
-- persystowany tag dostępnego update'u (nutka przeżywa restart do czasu
-- aż kolejny check powie "up to date").
----------------------------------------------------------------------------
local handle = nil
M.last_result = nil   -- { status='ok'|'error', newer=bool, tag=?, message=? }

local available_tag, available_loaded = nil, false

function M.available()
  if not available_loaded then
    local t = reaper.GetExtState(NS, 'update_available_tag')
    available_tag = (t ~= '' ) and t or nil
    available_loaded = true
  end
  return available_tag
end

local function set_available(tag)
  available_tag, available_loaded = tag, true
  reaper.SetExtState(NS, 'update_available_tag', tag or '', true)
end

function M.is_checking() return handle ~= nil end

function M.releases_url()
  return 'https://github.com/' .. (cfg.UPDATE_REPO or '') .. '/releases'
end

----------------------------------------------------------------------------
-- Spawn / poll
----------------------------------------------------------------------------
local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

local function worker_path()
  local _, this_path = reaper.get_action_context()
  local scaffold_dir = this_path and this_path:match('(.+)[/\\]') or ''
  return util.worker_script(scaffold_dir .. path_sep() .. 'workers' .. path_sep() .. 'worker_update.sh')
end

function M.spawn_check()
  if handle then return false end
  local slug = cfg.UPDATE_REPO or ''
  if slug == '' then return false end
  local curl = cfg.get_curl_path()
  if not curl or curl == '' then
    M.last_result = { status = 'error', message = 'curl not configured (run _phase0_check)' }
    return false
  end
  util.mkdir_p(tmp_dir())
  local job_id = ('update_%x_%x'):format(os.time(), math.random(0, 0xFFFFFF))
  local out_path      = tmp_dir() .. path_sep() .. job_id .. '.out'
  local sentinel_path = tmp_dir() .. path_sep() .. job_id .. '.done'
  local url = 'https://api.github.com/repos/' .. slug .. '/releases/latest'
  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape(curl),
    util.shell_escape(url),
    util.shell_escape(out_path),
    util.shell_escape(sentinel_path),
  }, ' ')
  util.exec_worker(cmd)
  handle = {
    status        = 'running',
    op            = 'update_check',
    out_path      = out_path,
    sentinel_path = sentinel_path,
    started_at    = util.now(),
  }
  reaper.SetExtState(NS, 'update_last_check', tostring(os.time()), true)
  M.last_result = nil
  return true
end

-- Cichy check na starcie: gated na slug + throttle 24 h. Wynik → nutka
-- w About/headerze; NIGDY modal (PHASE-USER-GUIDE §3). Wołane co klatkę
-- z defer loop — flaga sesyjna sprowadza koszt do jednego boolean checku.
local auto_check_done = false
function M.maybe_auto_check()
  if auto_check_done then return end
  auto_check_done = true
  if (cfg.UPDATE_REPO or '') == '' then return end
  local last = tonumber(reaper.GetExtState(NS, 'update_last_check')) or 0
  if os.time() - last < AUTO_CHECK_INTERVAL_SECS then return end
  M.spawn_check()
end

local function finish(result)
  os.remove(handle.out_path)
  handle = nil
  M.last_result = result
end

-- Wołane co klatkę z defer loop (tani nil-check gdy brak checku w toku).
function M.tick()
  if not handle then return end
  async_op.force_error_if_stale(handle)
  if handle.status == 'error' then
    return finish({ status = 'error', message = handle.error or 'timed out' })
  end
  if not util.file_exists(handle.sentinel_path) then return end

  local s = async_op.read_sentinel(handle)
  if s.http_code == 200 then
    local body = util.read_file(handle.out_path) or ''
    local okj, data = pcall(json.decode, body)
    local tag = okj and type(data) == 'table' and (data.tag_name or data.name) or nil
    if not tag or not M.parse_version(tag) then
      return finish({ status = 'error', message = 'unexpected response from GitHub' })
    end
    local newer = M.is_newer(tag, cfg.APP_VERSION)
    set_available(newer and tag or nil)
    return finish({ status = 'ok', newer = newer, tag = tag })
  elseif s.http_code == 404 then
    return finish({ status = 'error', message = 'no releases found' })
  elseif s.http_code == 403 or s.http_code == 429 then
    return finish({ status = 'error', message = 'GitHub rate limit — try again later' })
  elseif s.http_code == 0 then
    return finish({ status = 'error',
      message = 'network error' .. async_op.curl_exit_hint(s.curl_exit) })
  else
    return finish({ status = 'error', message = ('HTTP %d'):format(s.http_code) })
  end
end

return M
