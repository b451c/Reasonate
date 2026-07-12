-- modules/dubbing_state.lua
-- NS-B Dubbing: project state persistence (2-tier).
--
--   1. ProjExtState 'Reasonate.dubbing_state' JSON — minimal pointer:
--      { project_guid, version, last_modified }
--      Lekkie, persistent w .rpp project file → przeżywa save/share.
--
--   2. Filesystem JSON: <resource>/Scripts/Reasonate/dubbing_projects/<guid>.json
--      Pełen data model z dubbing_project.lua (segments, speakers, alignment,
--      glossary, cost). Limit ProjExtState ~64KB — większe data offload tu.
--
-- Pattern mirror NS-2c tts_state (debounce 500ms + atexit flush). Avoids 100s
-- writes per session gdy user pisze translation w inspector textarea.

local util = require 'modules.util'
local json = require 'modules.lib.json'

local M = {}

M.PROJ_EXT_SECTION = 'Reasonate'
M.PROJ_EXT_KEY     = 'dubbing_state'
M.STATE_VERSION    = 1

local function path_sep() return util.path_sep() end

-- T5a (UX-POLISH, user decision 2026-07-11): JSON projektu żyje OBOK .rpp
-- (<project_dir>/reasonate_projects/dubbing_projects/) i podróżuje z
-- projektem; unsaved → fallback resource path (lokalizacja sprzed T5a).
-- Odczyt: primary → fallback (stare projekty ładują się bez migracji;
-- pierwszy zapis ląduje już w primary — plik w fallbacku zostaje jako
-- backup). Patrz util.project_state_dirs.
local SUBDIR = 'dubbing_projects'

local function project_file_for_write(project_guid)
  local primary = util.project_state_dirs(SUBDIR)
  util.mkdir_p(primary)
  return primary .. path_sep() .. project_guid .. '.json'
end

-- Ścieżka ISTNIEJĄCEGO pliku (primary → fallback) lub nil.
local function find_project_file(project_guid)
  local primary, fallback = util.project_state_dirs(SUBDIR)
  local p = primary .. path_sep() .. project_guid .. '.json'
  if util.file_exists(p) then return p end
  if fallback then
    local f = fallback .. path_sep() .. project_guid .. '.json'
    if util.file_exists(f) then return f end
  end
  return nil
end

local function proj_handle()
  -- Active project (0 = current). EnumProjects(-1) returns (proj_handle, path).
  return reaper.EnumProjects(-1, '')
end

----------------------------------------------------------------------------
-- ProjExtState pointer (minimal blob)
----------------------------------------------------------------------------
function M.read_proj_ext()
  local proj = proj_handle()
  local _, raw = reaper.GetProjExtState(proj, M.PROJ_EXT_SECTION, M.PROJ_EXT_KEY)
  if not raw or raw == '' then return nil end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

function M.write_proj_ext(meta)
  local proj = proj_handle()
  local ok, encoded = pcall(json.encode, meta or {})
  if ok then
    reaper.SetProjExtState(proj, M.PROJ_EXT_SECTION, M.PROJ_EXT_KEY, encoded)
  end
end

----------------------------------------------------------------------------
-- Filesystem JSON load/save (full data)
----------------------------------------------------------------------------
function M.load_from_filesystem(project_guid)
  if not project_guid or project_guid == '' then return nil end
  local path = find_project_file(project_guid)
  if not path then return nil end
  local raw = util.read_file(path)
  if not raw or raw == '' then return nil end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

function M.save_to_filesystem(project_guid, data)
  if not project_guid or project_guid == '' then return false, 'no guid' end
  local path = project_file_for_write(project_guid)
  local ok, encoded = pcall(json.encode, data or {})
  if not ok then return false, 'JSON encode failed' end
  if not util.write_file(path, encoded) then return false, 'write file failed' end
  return true
end

----------------------------------------------------------------------------
-- Public: load() → project table | nil
--   Reads ProjExtState pointer → if guid set, loads full from filesystem.
----------------------------------------------------------------------------
----------------------------------------------------------------------------
-- Migration: backfill missing fields w older projects loaded z disk.
-- Add fields tutaj gdy data model rośnie. Idempotent — safe to re-run.
----------------------------------------------------------------------------
local function migrate_project(project)
  if not project or type(project) ~= 'table' then return project end
  local langs = project.target_languages or {}

  -- M4+ fix #11: seg.dub_n_items[lang] — backfill 1 dla istniejących generated,
  -- 0 dla nie-generated.
  for _, seg in ipairs(project.segments or {}) do
    if not seg.dub_n_items then
      seg.dub_n_items = {}
      for _, lang in ipairs(langs) do
        local generated = seg.dub_status and seg.dub_status[lang] == 'generated'
        seg.dub_n_items[lang] = generated and 1 or 0
      end
    end
    -- M3.6: seg.source_words preserved per-word splice. Default [] gdy missing.
    if seg.source_words == nil then seg.source_words = {} end
    -- M3.5: seg.director_note default ''.
    if seg.director_note == nil then seg.director_note = '' end
    -- M4+ rewrite: seg.dub_per_word[lang] flag. Default false (assume legacy
    -- splices were full-segment lub broken per-word grid which user musi re-gen).
    if seg.dub_per_word == nil then
      seg.dub_per_word = {}
      for _, lang in ipairs(langs) do seg.dub_per_word[lang] = false end
    end
    -- M4+ fix #20: per-word fallback reason per seg (visibility w Inspector).
    if seg.dub_per_word_fallback_reason == nil then
      seg.dub_per_word_fallback_reason = {}
      for _, lang in ipairs(langs) do seg.dub_per_word_fallback_reason[lang] = '' end
    end
    -- M4+ fix #27: applied stretch ratio per lang (smoothing z neighbors).
    if seg.dub_applied_ratio == nil then
      seg.dub_applied_ratio = {}
      for _, lang in ipairs(langs) do seg.dub_applied_ratio[lang] = nil end
    end
  end

  -- M4+: speaker.source_track_guid (Flow B) — optional, no init needed.
  -- M2.4: cost_tracker cache counters — backfill 0.
  if project.cost_tracker then
    project.cost_tracker.translate_cache_hits = project.cost_tracker.translate_cache_hits or 0
    project.cost_tracker.translate_fresh      = project.cost_tracker.translate_fresh      or 0
    project.cost_tracker.tts_cache_hits       = project.cost_tracker.tts_cache_hits       or 0
  end

  return project
end

function M.load()
  local meta = M.read_proj_ext()
  if not meta or not meta.project_guid then return nil end
  local project = M.load_from_filesystem(meta.project_guid)
  return migrate_project(project)
end

----------------------------------------------------------------------------
-- Public: save(project) — immediate write both tiers.
-- Use mark_dirty() + flush_if_needed() w defer loop dla debounced case.
----------------------------------------------------------------------------
function M.save(project)
  if not project or type(project) ~= 'table' then return false, 'invalid project' end
  if not project.project_guid or project.project_guid == '' then
    return false, 'project missing guid'
  end

  local ok, err = M.save_to_filesystem(project.project_guid, project)
  if not ok then return false, err end

  M.write_proj_ext({
    project_guid  = project.project_guid,
    version       = M.STATE_VERSION,
    last_modified = os.time(),
  })
  return true
end

----------------------------------------------------------------------------
-- Debounce state — mark_dirty marks pending write, flush_if_needed writes
-- po quiet period. Mirror NS-2c tts_state pattern. atexit ensures last writes
-- persisted on REAPER close (registered z reasonate.lua entrypoint).
----------------------------------------------------------------------------
local DEBOUNCE_SECS = 0.5

local _dirty_project = nil   -- { project, marked_at }

function M.mark_dirty(project)
  _dirty_project = { project = project, marked_at = util.now() }
end

function M.flush_if_needed()
  if not _dirty_project then return false end
  if (util.now() - _dirty_project.marked_at) < DEBOUNCE_SECS then return false end
  local proj = _dirty_project.project
  _dirty_project = nil
  return M.save(proj)
end

function M.flush_now()
  if not _dirty_project then return false end
  local proj = _dirty_project.project
  _dirty_project = nil
  return M.save(proj)
end

----------------------------------------------------------------------------
-- Unique project guid (filesystem path key). 'dub_' prefix + hex.
----------------------------------------------------------------------------
function M.generate_project_guid()
  local g = reaper.genGuid('')
  return 'dub_' .. g:gsub('[%{%}-]', '')
end

----------------------------------------------------------------------------
-- Delete project (filesystem + ProjExtState pointer cleanup).
----------------------------------------------------------------------------
function M.delete(project_guid)
  if not project_guid or project_guid == '' then return end
  -- T5a: kasujemy w OBU lokalizacjach (primary + fallback backup) —
  -- delete to jawna decyzja usera, backup nie powinien wskrzeszać projektu.
  local primary, fallback = util.project_state_dirs(SUBDIR)
  local p = primary .. path_sep() .. project_guid .. '.json'
  if util.file_exists(p) then os.remove(p) end
  if fallback then
    local f = fallback .. path_sep() .. project_guid .. '.json'
    if util.file_exists(f) then os.remove(f) end
  end
  -- Clear pointer (write empty)
  local proj = proj_handle()
  reaper.SetProjExtState(proj, M.PROJ_EXT_SECTION, M.PROJ_EXT_KEY, '')
end

----------------------------------------------------------------------------
-- List all dubbing projects on disk (filesystem JSON files).
-- Returns array { project_guid, file_path } (info lazy-loaded by caller).
----------------------------------------------------------------------------
function M.list_all()
  -- T5a: unia primary (project dir) + fallback (resource path); duplikat
  -- guida → primary wygrywa (świeższy — fallback to backup sprzed migracji).
  local primary, fallback = util.project_state_dirs(SUBDIR)
  local out, seen = {}, {}
  for _, dir in ipairs({ primary, fallback }) do
    if dir then
      for _, fname in ipairs(util.list_dir(dir)) do
        local guid = fname:match('^(.+)%.json$')
        if guid and not seen[guid] then
          seen[guid] = true
          out[#out + 1] = {
            file_name    = fname,
            project_guid = guid,
            file_path    = dir .. path_sep() .. fname,
          }
        end
      end
    end
  end
  return out
end

return M
