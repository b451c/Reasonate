-- modules/gui/voice_settings_dialog.lua
-- Modal: per-track override voice_settings (stability/similarity_boost/style/
-- use_speaker_boost). Default fall-through: jeśli track nie ma override,
-- używamy defaults z helpers.default_voice_settings().
--
-- Cache key zawiera settings JSON (Faza 6) → Apply z innymi settings = inny
-- hash → następny Convert robi realny API call.

local helpers = require 'modules.reaper_helpers'
local theme   = require 'modules.theme'

local M = {}

local POPUP_ID = 'Voice settings'

local s = {
  pending_open = false,
  state        = nil,
  track_guid   = nil,
  track_name   = nil,
  voice_name   = nil,
  has_override = false,
  -- editing state
  stability         = 0.5,
  similarity_boost  = 0.75,
  style             = 0.0,
  use_speaker_boost = true,
  speed             = 1.0,
  isolate_audio     = false,   -- NS-C: per-track Voice Isolator flag
}

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------
function M.open(opts)
  s.pending_open = true
  s.state        = opts.state
  s.track_guid   = opts.track_guid
  s.track_name   = opts.track_name or '?'
  s.voice_name   = opts.voice_name or '?'

  local tr = helpers.find_track_by_guid(opts.track_guid)
  if tr then
    s.isolate_audio = helpers.get_track_isolate_flag(tr)
    s.has_override  = helpers.get_track_voice_settings(tr) ~= nil
                      or s.isolate_audio
    local eff = helpers.effective_voice_settings(tr)
    s.stability         = eff.stability
    s.similarity_boost  = eff.similarity_boost
    s.style             = eff.style
    s.use_speaker_boost = eff.use_speaker_boost
    s.speed             = eff.speed or 1.0
  end
end

----------------------------------------------------------------------------
-- Render
----------------------------------------------------------------------------
function M.render(ctx)
  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    s.pending_open = false
  end

  theme.center_next_modal(ctx, 480, 0)
  theme.popup_keep_top(ctx, POPUP_ID)

  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end
  if not p_open then reaper.ImGui_CloseCurrentPopup(ctx) end

  reaper.ImGui_TextWrapped(ctx, ('%s → %s'):format(s.track_name, s.voice_name))
  if s.has_override then
    reaper.ImGui_TextColored(ctx, theme.COLORS.override, '● per-track override active')
  else
    reaper.ImGui_TextDisabled(ctx, 'using defaults')
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Stability
  reaper.ImGui_Text(ctx, 'Stability')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local rv, v = reaper.ImGui_SliderDouble(ctx, '##stab', s.stability, 0.0, 1.0, '%.2f')
  if rv then s.stability = v end
  reaper.ImGui_TextDisabled(ctx, '↑ more emotion / variance     ↓ more stable')

  reaper.ImGui_Spacing(ctx)
  -- Similarity boost
  reaper.ImGui_Text(ctx, 'Similarity boost')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  rv, v = reaper.ImGui_SliderDouble(ctx, '##sim', s.similarity_boost, 0.0, 1.0, '%.2f')
  if rv then s.similarity_boost = v end
  reaper.ImGui_TextDisabled(ctx, '↑ closer to original voice timbre')

  reaper.ImGui_Spacing(ctx)
  -- Style
  reaper.ImGui_Text(ctx, 'Style')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  rv, v = reaper.ImGui_SliderDouble(ctx, '##sty', s.style, 0.0, 1.0, '%.2f')
  if rv then s.style = v end
  reaper.ImGui_TextDisabled(ctx, '↑ stronger style features (at the cost of stability)')

  reaper.ImGui_Spacing(ctx)
  -- Speed (ElevenLabs voice_settings.speed; Multilingual v2 + Turbo support;
  -- Flash bypasses. Safe range 0.7-1.2 per Agents UI cap.)
  reaper.ImGui_Text(ctx, 'Speed')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  rv, v = reaper.ImGui_SliderDouble(ctx, '##spd', s.speed or 1.0, 0.7, 1.2, '%.2fx')
  if rv then s.speed = v end
  reaper.ImGui_TextDisabled(ctx, '1.0 = native pace · <1.0 slower · >1.0 faster')

  reaper.ImGui_Spacing(ctx)
  local cb_rv, cb_v = reaper.ImGui_Checkbox(ctx, 'Use speaker boost', s.use_speaker_boost)
  if cb_rv then s.use_speaker_boost = cb_v end

  reaper.ImGui_Spacing(ctx)
  -- NS-C: Voice Isolator per-track flag. Osobny P_EXT key (isolate_audio).
  local iso_rv, iso_v = reaper.ImGui_Checkbox(ctx,
    'Clean audio before AI (Voice Isolator)', s.isolate_audio)
  if iso_rv then s.isolate_audio = iso_v end
  reaper.ImGui_TextDisabled(ctx,
    'pre-process source audio via ElevenLabs before convert / clone / transcribe')

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Reset to defaults (left, destructive-ish)
  reaper.ImGui_BeginDisabled(ctx, not s.has_override)
  if theme.button_neutral(ctx, 'Reset to defaults', 160, 0) then
    local tr = helpers.find_track_by_guid(s.track_guid)
    if tr then
      helpers.set_track_voice_settings(tr, nil)
      helpers.set_track_isolate_flag(tr, false)
      local def = helpers.default_voice_settings()
      s.stability         = def.stability
      s.similarity_boost  = def.similarity_boost
      s.style             = def.style
      s.use_speaker_boost = def.use_speaker_boost
      s.speed             = def.speed or 1.0
      s.isolate_audio     = false
      s.has_override = false
    end
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_SameLine(ctx)
  if theme.button_neutral(ctx, 'Cancel', 100, 0) then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_SameLine(ctx)

  if theme.button_primary(ctx, 'Apply', 110, 0) then
    local tr = helpers.find_track_by_guid(s.track_guid)
    if tr then
      helpers.set_track_voice_settings(tr, {
        stability         = s.stability,
        similarity_boost  = s.similarity_boost,
        style             = s.style,
        use_speaker_boost = s.use_speaker_boost,
        speed             = s.speed or 1.0,
      })
      helpers.set_track_isolate_flag(tr, s.isolate_audio)
    end
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

return M
