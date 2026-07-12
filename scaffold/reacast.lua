-- reacast.lua — LEGACY SHIM
--
-- ReaCast został przemianowany na "Reasonate" 2026-05-10 (kolizja z REAPER
-- built-in feature "ReaCast" — web streamer dla broadcastu audio).
--
-- Ten plik istnieje tylko żeby stary Action List entry (wskazujący na
-- reacast.lua) dalej działał i pokazał użytkownikowi notatkę o nowej nazwie.
-- Po dodaniu nowej akcji ze ścieżką reasonate.lua, ten plik można usunąć.

reaper.MB(
  'ReaCast has been renamed to "Reasonate" — same plugin under a new name.\n\n' ..
  'Update the Action List entry:\n' ..
  '  1. Actions → Action List → find "Script: reacast.lua" → Remove\n' ..
  '  2. Actions → Action List → ReaScript: Load → point to "reasonate.lua"\n' ..
  '  3. Re-assign your keyboard shortcut to the new action if you had one\n\n' ..
  'Reasonate will now launch via this old entry — it will work, but this dialog ' ..
  'will keep appearing on every click of the old shortcut until you update the ' ..
  'Action List.',
  'Reasonate (formerly ReaCast)', 0)

local script_path = ({reaper.get_action_context()})[2]:match('(.*[/\\])') or ''
dofile(script_path .. 'reasonate.lua')
