-- modules/migration.lua
-- One-shot migration helper dla rename ReaCast → Reasonate (2026-05-10).
-- Wywoływane raz z entrypoint przy starcie. Idempotentne (flag w ExtState).
--
-- Migracja składa się z trzech części:
--   1. ExtState — sekcja "ReaCast" → "Reasonate" (config.migrate_from_reacast)
--   2. Filesystem — katalogi reacast_tmp/cache/output → reasonate_*
--   3. P_EXT — lazy per-track/item w helpers.get_*_string (transparently)
--
-- ExtState i filesystem to one-shot na pierwszym launchu. P_EXT migracja
-- happens "as user touches each track/item" (lazy w helpers wrappers).

local config = require 'modules.config'
local util   = require 'modules.util'

local M = {}

local FLAG_KEY = '_migrated_filesystem_from_reacast'

local function rename_if_exists(old_path, new_path)
  if not util.file_exists(old_path) then
    -- Check if old_path is a directory (file_exists checks file)
    -- io.open na directory wraca nil na większości platform, więc używamy
    -- EnumerateFiles do detekcji
    local first = reaper.EnumerateFiles(old_path, 0)
    if not first then return false, 'no_old' end
  end
  -- os.rename działa atomically dla same-volume rename (macOS/Linux POSIX,
  -- Windows MoveFile). Jeśli new_path istnieje, fail (nie nadpisujemy).
  if util.file_exists(new_path) then return false, 'new_exists' end
  local first_new = reaper.EnumerateFiles(new_path, 0)
  if first_new then return false, 'new_exists' end
  local ok, err = os.rename(old_path, new_path)
  return ok, err
end

local function migrate_filesystem()
  local sep = util.path_sep()
  local res = reaper.GetResourcePath()
  local renamed = {}

  -- 1. <resource>/Scripts/reacast_tmp/ → reasonate_tmp/
  local old_tmp = res .. sep .. 'Scripts' .. sep .. 'reacast_tmp'
  local new_tmp = res .. sep .. 'Scripts' .. sep .. 'reasonate_tmp'
  local ok, err = rename_if_exists(old_tmp, new_tmp)
  if ok then renamed[#renamed + 1] = 'reacast_tmp/ → reasonate_tmp/' end

  -- 2. <resource>/Scripts/reacast_cache/ (fallback dla unsaved projects) → reasonate_cache/
  local old_cache_fb = res .. sep .. 'Scripts' .. sep .. 'reacast_cache'
  local new_cache_fb = res .. sep .. 'Scripts' .. sep .. 'reasonate_cache'
  ok, err = rename_if_exists(old_cache_fb, new_cache_fb)
  if ok then renamed[#renamed + 1] = 'Scripts/reacast_cache/ → reasonate_cache/' end

  -- 3. Per-projekt cache w project dir.
  --    REAPER projekt może być saved (GetProjectPath zwraca path) lub unsaved
  --    (zwraca empty / fallback). Sprawdzamy current.
  local pd = reaper.GetProjectPath('')
  if pd and pd ~= '' then
    local old_pcache = pd .. sep .. 'reacast_cache'
    local new_pcache = pd .. sep .. 'reasonate_cache'
    ok, err = rename_if_exists(old_pcache, new_pcache)
    if ok then renamed[#renamed + 1] = ('%s/reacast_cache/ → reasonate_cache/'):format(pd) end

    -- 4. Legacy reacast_output/ (Phase 4-5; nieużywane od Phase 6 ale może być w starych projektach)
    local old_out = pd .. sep .. 'reacast_output'
    local new_out = pd .. sep .. 'reasonate_output'
    ok, err = rename_if_exists(old_out, new_out)
    if ok then renamed[#renamed + 1] = ('%s/reacast_output/ → reasonate_output/'):format(pd) end
  end

  return renamed
end

----------------------------------------------------------------------------
-- Public API: run_once()
-- Returns table {extstate_count, filesystem_count, fs_details}.
-- Wywoływane raz z entrypoint reasonate.lua przy starcie.
----------------------------------------------------------------------------
function M.run_once()
  local result = {
    extstate_count = 0,
    filesystem_count = 0,
    fs_details = {},
  }

  -- Filesystem (one-shot przez ExtState flag, niezależnie od ExtState migration)
  local fs_flag = reaper.GetExtState(config.NAMESPACE, FLAG_KEY)
  if fs_flag ~= '1' then
    result.fs_details = migrate_filesystem()
    result.filesystem_count = #result.fs_details
    reaper.SetExtState(config.NAMESPACE, FLAG_KEY, '1', true)
  end

  -- ExtState (config has its own flag '_migrated_from_reacast')
  result.extstate_count = config.migrate_from_reacast() or 0

  -- Console summary jeśli cokolwiek się stało
  if result.extstate_count > 0 or result.filesystem_count > 0 then
    local msg = '[Reasonate] Migration from ReaCast:\n'
    if result.extstate_count > 0 then
      msg = msg .. ('  · %d ExtState settings copied\n'):format(result.extstate_count)
    end
    for _, line in ipairs(result.fs_details) do
      msg = msg .. ('  · %s\n'):format(line)
    end
    msg = msg .. '  (P_EXT migrowane lazy per track/item przy odczycie)\n'
    reaper.ShowConsoleMsg(msg)
  end

  return result
end

return M
