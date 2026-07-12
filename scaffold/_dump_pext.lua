-- _dump_pext.lua
--
-- Diagnostyka Fazy 1: dla każdego selected tracku wypisuje wszystkie
-- klucze P_EXT:Reasonate.* + ich wartości. Użyj po zmianie voice'a w
-- Reasonate żeby potwierdzić że P_EXT zostało zapisane.
--
-- Uruchom: zaznacz 1+ tracków → Action List → odpal ten skrypt.
-- Wynik w konsoli REAPER (View → Open Console).

local function out(s) reaper.ShowConsoleMsg(s .. '\n') end

reaper.ClearConsole()
out('=== Reasonate P_EXT dump ===')
out('')

local KEYS = {
  'voice_id',
  'voice_name',
  'role',
  'output_track_guid',
  'voice_settings',
  'color_tag',
}

local n_sel = reaper.CountSelectedTracks(0)
if n_sel == 0 then
  out('Brak zaznaczonych tracków. Zaznacz 1+ tracków i odpal ponownie.')
  return
end

for i = 0, n_sel - 1 do
  local tr = reaper.GetSelectedTrack(0, i)
  local idx = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'IP_TRACKNUMBER'))
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
  local guid = reaper.GetTrackGUID(tr)

  out(('Track %d: "%s"  (%s)'):format(idx, name ~= '' and name or '(unnamed)', guid))

  local any = false
  for _, k in ipairs(KEYS) do
    local _, val = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:Reasonate.' .. k, '', false)
    if val ~= '' then
      out(('  Reasonate.%-20s = %s'):format(k, val))
      any = true
    end
  end
  if not any then out('  (no Reasonate P_EXT keys set)') end
  out('')
end
