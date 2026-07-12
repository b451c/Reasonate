-- modules/recording.lua
-- Phase 11.x — track recording z poziomu Reasonate.
-- Stan machine: idle → pre_roll (countdown) → recording → idle.
--
-- Bezpieczna sekwencja:
--   1. Save+disarm wszystkie inne tracki (cross-track recording protection)
--   2. Arm target track + ustaw input/monitor wg config
--   3. Position cursor na końcu istniejących itemów + 0.5s gap (no overlap)
--   4. (opcjonalnie) Pre-roll countdown
--   5. Start transport record (Main_OnCommand 1013)
--   6. ... live VU + timer rendered przez tracks_table per frame ...
--   7. Stop transport (Main_OnCommand 1016)
--   8. Disarm target + restore wszystkich poprzednich arm states
--   9. Auto-select new item dla audition
--
-- External stop detection: GetPlayState bit 4 — gdy user naciśnie Space w
-- REAPER, wykrywamy w tick() i wywalamy stan internal.

local helpers = require 'modules.reaper_helpers'
local cfg     = require 'modules.config'
local util    = require 'modules.util'

local M = {}

local s = {
  state             = 'idle',  -- 'idle' | 'pre_roll' | 'recording'
  target_track_guid = nil,
  prev_arm_states   = nil,
  prev_input        = nil,
  prev_monitor      = nil,
  prev_recmode      = nil,
  started_at        = nil,     -- recording start (clock secs)
  pre_roll_secs     = 0,
  pre_roll_started  = nil,
  cursor_pos        = nil,
}

----------------------------------------------------------------------------
-- Public state queries (used by tracks_table render)
----------------------------------------------------------------------------
function M.is_active()      return s.state ~= 'idle' end
function M.is_recording()   return s.state == 'recording' end
function M.is_pre_roll()    return s.state == 'pre_roll' end
function M.target_guid()    return s.target_track_guid end

function M.elapsed_secs()
  if s.state == 'recording' and s.started_at then
    return util.now() - s.started_at
  end
  return 0
end

function M.pre_roll_remaining()
  if s.state ~= 'pre_roll' or not s.pre_roll_started then return 0 end
  local r = s.pre_roll_secs - (util.now() - s.pre_roll_started)
  if r < 0 then r = 0 end
  return r
end

----------------------------------------------------------------------------
-- M.start(track_guid) → ok, err
-- Wymusza single-target — gdy już recording, zwraca error.
----------------------------------------------------------------------------
function M.start(track_guid)
  if s.state ~= 'idle' then
    return false, 'Already recording (track ' .. tostring(s.target_track_guid) .. ')'
  end
  local tr = helpers.find_track_by_guid(track_guid)
  if not tr then return false, 'track not found' end

  -- Zachowaj poprzedni stan track config (do restore po stop)
  s.prev_input   = reaper.GetMediaTrackInfo_Value(tr, 'I_RECINPUT') or 0
  s.prev_monitor = reaper.GetMediaTrackInfo_Value(tr, 'I_RECMON')   or 0
  s.prev_recmode = reaper.GetMediaTrackInfo_Value(tr, 'I_RECMODE')  or 0

  -- Pre-flight: arm target, disarm others
  s.prev_arm_states = helpers.arm_track_only(tr)

  -- Configure input/monitor wg user pref
  helpers.configure_track_for_record(tr,
    cfg.get_record_input(),
    cfg.get_record_monitor())

  -- Position cursor żeby nowy item NIE nakładał się na istniejące
  s.cursor_pos = helpers.position_cursor_for_record(tr, 0.5)

  s.target_track_guid = track_guid
  s.pre_roll_secs     = cfg.get_record_pre_roll() or 0

  if s.pre_roll_secs > 0 then
    s.state = 'pre_roll'
    s.pre_roll_started = util.now()
  else
    -- Direct start
    reaper.Main_OnCommand(1013, 0)  -- Transport: Record
    s.state = 'recording'
    s.started_at = util.now()
  end
  return true
end

----------------------------------------------------------------------------
-- M.tick() — co frame z defer loop. Obsługuje:
--   - pre-roll countdown → przejście do 'recording' po elapsed
--   - external stop detection (user pressed Space) → wewnętrzny cleanup
----------------------------------------------------------------------------
function M.tick()
  if s.state == 'idle' then return end

  if s.state == 'pre_roll' then
    if util.now() - s.pre_roll_started >= s.pre_roll_secs then
      reaper.Main_OnCommand(1013, 0)
      s.state = 'recording'
      s.started_at = util.now()
    end
    return
  end

  if s.state == 'recording' then
    -- External stop detection: REAPER nie nagrywa już (np. user nacisnął Space)
    if not helpers.is_reaper_recording() then
      M._cleanup_after_stop()
    end
  end
end

----------------------------------------------------------------------------
-- M.stop() — internal click on ■ stop button. Wysyła Main_OnCommand 1016.
----------------------------------------------------------------------------
function M.stop()
  if s.state == 'idle' then return end
  if s.state == 'recording' or s.state == 'pre_roll' then
    -- 1016 = Transport: Stop (saves any new takes per REAPER default)
    reaper.Main_OnCommand(1016, 0)
  end
  M._cleanup_after_stop()
end

----------------------------------------------------------------------------
-- _cleanup_after_stop — wspólna ścieżka z M.stop i external-stop detection
----------------------------------------------------------------------------
function M._cleanup_after_stop()
  local tr = s.target_track_guid and helpers.find_track_by_guid(s.target_track_guid) or nil

  -- Restore track config (input/monitor/recmode)
  if tr then
    if s.prev_input   then reaper.SetMediaTrackInfo_Value(tr, 'I_RECINPUT', s.prev_input)   end
    if s.prev_monitor then reaper.SetMediaTrackInfo_Value(tr, 'I_RECMON',   s.prev_monitor) end
    if s.prev_recmode then reaper.SetMediaTrackInfo_Value(tr, 'I_RECMODE',  s.prev_recmode) end
  end

  -- Restore arm states (target + others)
  helpers.restore_arm_states(s.prev_arm_states)

  -- Auto-select new item dla audition
  if tr then
    local last = helpers.last_item_on_track(tr)
    if last then
      reaper.SelectAllMediaItems(0, false)
      reaper.SetMediaItemSelected(last, true)
      reaper.SetOnlyTrackSelected(tr)
      reaper.UpdateArrange()
    end
  end

  -- Reset state
  s.state             = 'idle'
  s.target_track_guid = nil
  s.prev_arm_states   = nil
  s.prev_input        = nil
  s.prev_monitor      = nil
  s.prev_recmode      = nil
  s.started_at        = nil
  s.pre_roll_secs     = 0
  s.pre_roll_started  = nil
  s.cursor_pos        = nil
end

----------------------------------------------------------------------------
-- VU peak — stub for tracks_table render.
-- Returns dB (-120..6, typical -60..0).
----------------------------------------------------------------------------
function M.target_track_peak_db(channel)
  if s.state == 'idle' or not s.target_track_guid then return -120 end
  local tr = helpers.find_track_by_guid(s.target_track_guid)
  if not tr then return -120 end
  return helpers.track_peak_db(tr, channel or 0)
end

-- Cleanup gdy Reasonate script się zamyka (atexit handler w reasonate.lua)
function M.shutdown()
  if s.state ~= 'idle' then
    M.stop()
  end
end

return M
