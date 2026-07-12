-- modules/gui/dubbing_voice_settings.lua
-- NS-B M4+: Voice settings modal dla Dubbing (per-speaker + per-segment).
--
-- Decoupled z Voice Replacement track P_EXT. Caller provides:
--   opts.title             — modal header
--   opts.subtitle          — secondary line (e.g., speaker label + voice name)
--   opts.current_settings  — {stability, similarity_boost, style, speed, speaker_boost}
--   opts.has_override      — bool — show "override active" badge w per-segment context
--   opts.allow_clear       — bool — show "Clear override" button (per-segment)
--   opts.on_apply(settings)— callback gdy user clicks Apply z new values
--   opts.on_clear()        — callback gdy user clicks Clear (per-segment override)
--
-- Sliders: 5 voice settings (matches dubbing_project.DEFAULT_VOICE_SETTINGS).

local theme = require 'modules.theme'

local M = {}

local POPUP_ID = 'Dubbing voice settings'

local s = {
  pending_open = false,
  title        = '',
  subtitle     = '',
  has_override = false,
  allow_clear  = false,
  -- Editing state (live-modified by sliders; only committed on Apply)
  stability        = 0.5,
  similarity_boost = 0.75,
  style            = 0.0,
  speed            = 1.0,
  speaker_boost    = true,
  -- Initial snapshot dla unsaved-changes detection
  initial          = nil,
  -- Callbacks
  on_apply         = nil,
  on_clear         = nil,
}

local function clone_settings(t)
  return {
    stability        = t and t.stability        or 0.5,
    similarity_boost = t and t.similarity_boost or 0.75,
    style            = t and t.style            or 0.0,
    speed            = t and t.speed            or 1.0,
    speaker_boost    = t and (t.speaker_boost == true or t.speaker_boost == nil) or false,
  }
end

local function settings_diverge(a, b)
  if not a or not b then return false end
  return a.stability ~= b.stability
      or a.similarity_boost ~= b.similarity_boost
      or a.style ~= b.style
      or a.speed ~= b.speed
      or a.speaker_boost ~= b.speaker_boost
end

function M.open(opts)
  s.pending_open = true
  s.title        = opts.title or 'Voice settings'
  s.subtitle     = opts.subtitle or ''
  s.has_override = opts.has_override == true
  s.allow_clear  = opts.allow_clear == true
  local cur = clone_settings(opts.current_settings)
  s.stability        = cur.stability
  s.similarity_boost = cur.similarity_boost
  s.style            = cur.style
  s.speed            = cur.speed
  s.speaker_boost    = cur.speaker_boost
  s.initial          = cur
  s.on_apply         = opts.on_apply
  s.on_clear         = opts.on_clear
end

function M.is_open() return s.initial ~= nil end

function M.render(ctx)
  if not s.initial then return nil end
  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    s.pending_open = false
  end

  theme.center_next_modal(ctx, 520, 0)
  theme.popup_keep_top(ctx, POPUP_ID)
  local visible = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then
    s.initial = nil
    return 'close'
  end

  local action = nil

  -- Header
  theme.push_heading(ctx)
  reaper.ImGui_Text(ctx, s.title)
  theme.pop_heading(ctx)
  if s.subtitle ~= '' then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_Text(ctx, s.subtitle)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  if s.has_override then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFB060FF)
    reaper.ImGui_Text(ctx, '* Per-segment override active')
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Sliders
  reaper.ImGui_Text(ctx, 'Stability')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local rv, v = reaper.ImGui_SliderDouble(ctx, '##stab', s.stability, 0.0, 1.0, '%.2f')
  if rv then s.stability = v end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx, 'Lower = more variation, expressive. Higher = consistent, monotone.')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Text(ctx, 'Similarity boost')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  rv, v = reaper.ImGui_SliderDouble(ctx, '##sim', s.similarity_boost, 0.0, 1.0, '%.2f')
  if rv then s.similarity_boost = v end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx, 'How close TTS mimics the cloned voice. Higher = more like sample, ale less prosodic variation.')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Text(ctx, 'Style')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  rv, v = reaper.ImGui_SliderDouble(ctx, '##style', s.style, 0.0, 1.0, '%.2f')
  if rv then s.style = v end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx, 'Style exaggeration (v3 model only). 0 = natural, higher = stronger character traits.')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Text(ctx, 'Speed')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  rv, v = reaper.ImGui_SliderDouble(ctx, '##speed', s.speed, 0.7, 1.2, '%.2f')
  if rv then s.speed = v end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx, '0.7 = slower, 1.0 = natural, 1.2 = faster. Affects pacing without pitch change.')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  rv, v = reaper.ImGui_Checkbox(ctx, 'Speaker boost', s.speaker_boost)
  if rv then s.speaker_boost = v end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx, 'Enhance voice clarity. ON = recommended dla most dubbing scenarios.')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Apply / Clear / Cancel
  local current = clone_settings(s)
  local changed = settings_diverge(s.initial, current)

  if theme.button_neutral(ctx, 'Cancel') then
    -- Unsaved warning gdy changes
    local discard = true
    if changed then
      discard = (reaper.MB('Discard voice settings changes?', 'Unsaved changes', 1) == 1)
    end
    if discard then
      reaper.ImGui_CloseCurrentPopup(ctx)
      s.initial = nil
      action = 'cancel'
    end
  end

  if s.allow_clear and s.has_override then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    if theme.button_neutral(ctx, 'Clear override (use default)') then
      if s.on_clear then s.on_clear() end
      reaper.ImGui_CloseCurrentPopup(ctx)
      s.initial = nil
      action = 'cleared'
    end
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_BeginDisabled(ctx, not changed)
  if theme.button_primary(ctx, 'Apply') then
    if s.on_apply then s.on_apply(current) end
    reaper.ImGui_CloseCurrentPopup(ctx)
    s.initial = nil
    action = 'applied'
  end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_EndPopup(ctx)
  return action
end

return M
