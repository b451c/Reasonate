-- _set_item_status.lua
--
-- Diagnostyka Fazy 2: ustawia Reasonate P_EXT na zaznaczonych itemach
-- żeby symulować różne statusy bez wywoływania ElevenLabs API.
--
-- Wybierz jeden z trybów poprzez przedrostek nazwy akcji w Action List
-- albo edytując STATUS poniżej:
--   'converted' → P_EXT.converted = '1'                      (zielony)
--   'error'     → P_EXT.error = 'manual test error'          (czerwony)
--   'output'    → P_EXT.is_output = '1'                      (fioletowy)
--   'clear'     → usuwa wszystkie Reasonate.* keys + odbarwia  (back to new)
--
-- Po zmianie Reasonate (jeśli otwarty) odświeży kolor na następnym tick (≤500 ms).

local STATUS = 'converted'  -- ZMIEŃ TUTAJ przed odpaleniem

local KEYS_TO_CLEAR = {
  'P_EXT:Reasonate.converted',
  'P_EXT:Reasonate.error',
  'P_EXT:Reasonate.is_output',
}

local function set(item, key, val)
  reaper.GetSetMediaItemInfo_String(item, key, val, true)
end

local function clear_keys(item)
  for _, k in ipairs(KEYS_TO_CLEAR) do set(item, k, '') end
end

local n = reaper.CountSelectedMediaItems(0)
if n == 0 then
  reaper.MB('Zaznacz 1+ itemów najpierw.', '_set_item_status.lua', 0)
  return
end

reaper.Undo_BeginBlock()
for i = 0, n - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  clear_keys(item)
  if STATUS == 'converted' then
    set(item, 'P_EXT:Reasonate.converted', '1')
  elseif STATUS == 'error' then
    set(item, 'P_EXT:Reasonate.error', 'manual test error')
  elseif STATUS == 'output' then
    set(item, 'P_EXT:Reasonate.is_output', '1')
  elseif STATUS == 'clear' then
    -- already cleared; also reset I_CUSTOMCOLOR
    reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', 0)
  end
end
reaper.UpdateArrange()
reaper.Undo_EndBlock('Reasonate: set item status to ' .. STATUS, -1)

reaper.ShowConsoleMsg(('Set status "%s" on %d item(s).\n'):format(STATUS, n))
