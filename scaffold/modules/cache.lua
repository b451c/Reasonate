-- modules/cache.lua
-- Output mp3 cache — klucz deterministyczny od (source_identity + conv_params).
-- Lokalizacja: <project>/reasonate_cache/<key>.mp3 (portable z projektem).
-- Fallback: <resource>/Scripts/reasonate_cache/ gdy projekt unsaved.

local util = require 'modules.util'
local json = require 'modules.lib.json'

local M = {}

local function project_dir()
  local _, proj_path = reaper.EnumProjects(-1)
  if proj_path and proj_path ~= '' then
    return proj_path:match('(.+)[/\\]')
  end
  return nil
end

function M.cache_dir()
  local sep = util.path_sep()
  local pd = project_dir()
  if pd then
    local cd = pd .. sep .. 'reasonate_cache'
    util.mkdir_p(cd)
    return cd
  end
  local fb = reaper.GetResourcePath() .. sep .. 'Scripts' .. sep .. 'reasonate_cache'
  util.mkdir_p(fb)
  return fb
end

----------------------------------------------------------------------------
-- compute_key: deterministyczny hash params wpływających na audio output.
-- Zmiana KAŻDEGO z tych pól → inny klucz → cache miss → realny API call.
----------------------------------------------------------------------------
function M.compute_key(params)
  -- M1-1 (audit 2026-07): kanoniczna serializacja settings (NIE json.encode
  -- — Lua 5.4 randomizuje kolejność pairs() per proces → klucz dryfował
  -- między restartami REAPER = płatne re-konwersje). Prefiks 'v2|' =
  -- jawna, jednorazowa inwalidacja starych wpisów (patrz KNOWN-ISSUES).
  local settings_str = type(params.settings) == 'table'
    and util.canon_voice_settings(params.settings)
    or tostring(params.settings or '')

  local input = string.format(
    'v2|%s|%d|%.3f|%s|%s|%d|%s|%s',
    params.source_path   or '',
    params.source_size   or 0,
    params.source_length or 0,
    params.voice_id      or '',
    params.model_id      or '',
    params.seed          or 0,
    settings_str,
    params.output_format or '')

  -- Phase 11.x: trimmed/playrated itemy renderowane przez AudioAccessor
  -- dostają distinct klucz. Untrimmed items zachowują pre-Phase-11.x klucz
  -- (backward compat z istniejącym cache).
  local item_offs   = params.item_offs   or 0
  local item_length = params.item_length or 0
  local playrate    = params.playrate    or 1
  local source_len  = params.source_length or 0
  local trimmed = item_offs > 0.001
              or math.abs(playrate - 1) > 0.001
              or (item_length > 0 and source_len > 0
                  and math.abs(item_length - source_len) > 0.05)
  if trimmed then
    input = input .. string.format('|%.6f|%.6f|%.6f', item_offs, item_length, playrate)
  end

  -- NS-C: gdy Voice Isolator pre-process ON dla tego tracku, AI dostaje
  -- inny input audio → inny wynik. Append suffix tylko gdy ON (default OFF
  -- → klucz niezmieniony → backward-compat z istniejącym cache).
  if params.isolate_audio then
    input = input .. '|iso'
  end

  return util.simple_hash(input)  -- 8-char hex z DJB2
end

function M.path_for(key, ext)
  return M.cache_dir() .. util.path_sep() .. tostring(key) .. '.' .. (ext or 'mp3')
end

function M.exists(key, ext)
  return util.file_exists(M.path_for(key, ext))
end

----------------------------------------------------------------------------
-- Stats + clear (do Settings UI)
----------------------------------------------------------------------------
function M.stats()
  local dir = M.cache_dir()
  local count, total = 0, 0
  for _, fname in ipairs(util.list_dir(dir)) do
    if fname:match('%.mp3$') then
      count = count + 1
      local sz = util.file_size(dir .. util.path_sep() .. fname)
      if sz then total = total + sz end
    end
  end
  return { count = count, total_bytes = total, dir = dir }
end

function M.clear()
  local dir = M.cache_dir()
  local removed = 0
  for _, fname in ipairs(util.list_dir(dir)) do
    if fname:match('%.mp3$') then
      if os.remove(dir .. util.path_sep() .. fname) then
        removed = removed + 1
      end
    end
  end
  return removed
end

----------------------------------------------------------------------------
-- Size-cap eviction (audit fix M2-3, 2026-06-10).
--
-- Cache nie miał TTL ani limitu — jedyne sprzątanie to ręczny "Clear cache".
-- LRU approximation: mtime jest niedostępne (Lua/REAPER bez JS-ext), więc
-- last-used żyje w sidecar `cache_index.json` w cache dir. touch(key)
-- wołane przez job_manager przy cache hit + po udanym imporcie. Pliki
-- spoza indeksu (pre-feature) traktowane jako najstarsze (ts=0) — eviction
-- bierze je first; regenerowalne z definicji (deterministyczny klucz).
----------------------------------------------------------------------------
local INDEX_NAME = 'cache_index.json'
local _index = nil   -- lazy {key_str -> last_used_unix}

local function index_path()
  return M.cache_dir() .. util.path_sep() .. INDEX_NAME
end

local function load_index()
  if _index then return _index end
  _index = {}
  local raw = util.read_file(index_path())
  if raw and raw ~= '' then
    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == 'table' then _index = decoded end
  end
  return _index
end

-- M6-7: zapis atomowy (tmp+rename — kill mid-write nie zostawia urwanego
-- JSON-a) + debounce (touch podczas batcha nie robi pełnego rewritu per
-- job; flush co ≥5 s od ostatniego zapisu albo jawnie przez flush_index —
-- hook batch-end w reasonate.lua woła evict_to_cap → save i tak).
local _index_dirty     = false
local _index_last_wr   = 0
local INDEX_FLUSH_SECS = 5

local function save_index()
  local ok, encoded = pcall(json.encode, _index or {})
  if not ok then return end
  local path = index_path()
  local tmp  = path .. '.tmp'
  if util.write_file(tmp, encoded) then
    os.remove(path)
    if not os.rename(tmp, path) then os.remove(tmp) end
  end
  _index_dirty   = false
  _index_last_wr = os.time()
end

function M.flush_index()
  if _index_dirty then save_index() end
end

function M.touch(key)
  if not key then return end
  local idx = load_index()
  idx[tostring(key)] = os.time()
  _index_dirty = true
  if os.time() - _index_last_wr >= INDEX_FLUSH_SECS then
    save_index()
  end
end

-- evict_to_cap(max_bytes) → evicted_count. max_bytes nil/0 = bez limitu.
function M.evict_to_cap(max_bytes)
  if not max_bytes or max_bytes <= 0 then return 0 end
  local dir = M.cache_dir()
  local sep = util.path_sep()
  local idx = load_index()

  local files, total = {}, 0
  for _, fname in ipairs(util.list_dir(dir)) do
    local key = fname:match('^(.+)%.mp3$')
    if key then
      local sz = util.file_size(dir .. sep .. fname) or 0
      total = total + sz
      files[#files + 1] = { fname = fname, key = key, size = sz,
                            last_used = idx[key] or 0 }
    end
  end
  if total <= max_bytes then return 0 end

  table.sort(files, function(a, b) return a.last_used < b.last_used end)

  local evicted = 0
  for _, f in ipairs(files) do
    if total <= max_bytes then break end
    if os.remove(dir .. sep .. f.fname) then
      total = total - f.size
      idx[f.key] = nil
      evicted = evicted + 1
    end
  end
  if evicted > 0 or _index_dirty then save_index() end
  return evicted
end

return M
