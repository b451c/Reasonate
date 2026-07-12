-- modules/cast.lua
-- Cast = mapping role → voice_id, persystowany w globalnym ExtState
-- (sekcja "Reasonate", klucz "casts" — JSON-encoded array of casts).
--
-- Mapping po nazwie roli (nie po GUID), żeby cast działał między projektami.
-- Każdy track z `P_EXT.role` + `P_EXT.voice_id` wpada do save'u; apply
-- chodzi po wszystkich trackach w current project i przypisuje voice
-- gdzie role pasuje.

local helpers = require 'modules.reaper_helpers'
local json    = require 'modules.lib.json'

local M = {}

local NAMESPACE = 'Reasonate'
local KEY       = 'casts'

----------------------------------------------------------------------------
-- Storage
----------------------------------------------------------------------------
local function load_all()
  local raw = reaper.GetExtState(NAMESPACE, KEY)
  if raw == '' then return {} end
  local ok, decoded = pcall(json.decode, raw)
  if ok and type(decoded) == 'table' then return decoded end
  return {}
end

local function save_all(casts)
  reaper.SetExtState(NAMESPACE, KEY, json.encode(casts), true)
end

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------
function M.count_roles(mapping)
  local n = 0
  for _ in pairs(mapping or {}) do n = n + 1 end
  return n
end

function M.list()
  local casts = load_all()
  table.sort(casts, function(a, b) return (a.saved_at or 0) > (b.saved_at or 0) end)
  return casts
end

function M.find(name)
  for _, c in ipairs(load_all()) do
    if c.name == name then return c end
  end
  return nil
end

-- Build mapping z bieżącego projektu i zapisz pod podaną nazwą (replace if exists)
function M.save_current(name)
  if not name or name == '' then return false, 'empty cast name' end
  local mapping = {}
  local n_tracks = 0
  for tr in helpers.iter_tracks() do
    local role = helpers.get_track_role(tr)
    local voice_id, voice_name = helpers.get_track_voice(tr)
    if role and voice_id then
      mapping[role] = { voice_id = voice_id, voice_name = voice_name }
      n_tracks = n_tracks + 1
    end
  end
  if n_tracks == 0 then
    return false, 'no tracks with both role and voice assigned'
  end

  local casts = load_all()
  local entry = { name = name, mapping = mapping, saved_at = os.time() }
  for i, c in ipairs(casts) do
    if c.name == name then
      casts[i] = entry
      save_all(casts)
      return true, ('Updated "%s" — %d roles'):format(name, n_tracks)
    end
  end
  table.insert(casts, entry)
  save_all(casts)
  return true, ('Saved "%s" — %d roles'):format(name, n_tracks)
end

function M.delete(name)
  local casts = load_all()
  for i, c in ipairs(casts) do
    if c.name == name then
      table.remove(casts, i)
      save_all(casts)
      return true
    end
  end
  return false, 'not found'
end

return M
