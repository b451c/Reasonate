-- modules/gui/track_color_popup.lua
-- Phase 11.x — items color picker popup (per-item LUB bulk track-level).
--
-- target_kind:
--   'track' → bulk: ustaw kolor wszystkim audio itemom na tracku + flag user_color
--             na każdym. Klik "Clear" usuwa flag z każdego (auto-status wraca).
--   'item'  → single: ustaw kolor jednemu itemowi + jego flag. Klik "Clear" tylko
--             tego jednego itema.
--
-- Sync: Reasonate swatch w tracks_table aktualizuje się następnym refresh'em
-- (state.lua oblicza effective_color z aktualnych I_CUSTOMCOLOR po itemach).

local helpers = require 'modules.reaper_helpers'
local colors  = require 'modules.colors'
local theme   = require 'modules.theme'

local M = {}

local POPUP_ID = 'reasonate_color_popup'

local s = {
  pending_open     = false,
  target_kind      = nil,    -- 'track' | 'item'
  target_guid      = nil,    -- track_guid or item_guid (per kind)
  target_track_guid = nil,   -- always set; for 'item' = its track guid (display)
  custom_open      = false,
  custom_color_rgb = 0xFF8000,
}

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------
function M.open_for_track(track_guid)
  s.pending_open       = true
  s.target_kind        = 'track'
  s.target_guid        = track_guid
  s.target_track_guid  = track_guid
  s.custom_open        = false
  s.custom_color_rgb   = 0xFF8000
end

function M.open_for_item(item_guid, track_guid)
  s.pending_open       = true
  s.target_kind        = 'item'
  s.target_guid        = item_guid
  s.target_track_guid  = track_guid
  s.custom_open        = false
  s.custom_color_rgb   = 0xFF8000

  -- Pre-fill custom z current item color (jeśli ma)
  -- WAŻNE: native_to_rgb zwraca 3 wartości; `(cond) and func() or nil` chain
  -- gubi multi-return. Trzeba explicit if-block.
  local item = helpers.find_item_by_guid(item_guid)
  if item then
    local native = math.floor(reaper.GetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR'))
    if native ~= 0 then
      local r, g, b = colors.native_to_rgb(native)
      if r and g and b then
        s.custom_color_rgb = (r << 16) | (g << 8) | b
      end
    end
  end
end

function M.is_active() return s.target_guid ~= nil end

----------------------------------------------------------------------------
-- Apply helpers (DRY — wrap helpers + close on success)
----------------------------------------------------------------------------
local function apply_color(native)
  if s.target_kind == 'track' then
    local tr = helpers.find_track_by_guid(s.target_guid)
    if tr then helpers.bulk_set_track_items_color(tr, native) end
  elseif s.target_kind == 'item' then
    local it = helpers.find_item_by_guid(s.target_guid)
    if it then helpers.set_item_user_color(it, native) end
  end
  reaper.UpdateArrange()  -- force timeline redraw (immediate visual update)
end

local function clear_color()
  if s.target_kind == 'track' then
    local tr = helpers.find_track_by_guid(s.target_guid)
    if tr then helpers.bulk_clear_track_items_color(tr) end
  elseif s.target_kind == 'item' then
    local it = helpers.find_item_by_guid(s.target_guid)
    if it then helpers.clear_item_user_color(it) end
  end
  reaper.UpdateArrange()
end

----------------------------------------------------------------------------
-- Render
----------------------------------------------------------------------------
function M.render(ctx)
  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    s.pending_open = false
  end

  theme.center_next_modal(ctx, 360, 0)
  theme.popup_keep_top(ctx, POPUP_ID)

  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse()
    | reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if not visible then
    if s.target_guid then
      s.target_guid       = nil
      s.target_track_guid = nil
      s.target_kind       = nil
    end
    return
  end
  if not p_open then reaper.ImGui_CloseCurrentPopup(ctx) end

  -- Header
  if s.target_kind == 'track' then
    local tr = helpers.find_track_by_guid(s.target_guid)
    local label = tr and helpers.track_name(tr) or '?'
    if label == '' then label = '(unnamed)' end
    reaper.ImGui_Text(ctx, ('Color all items · track: %s'):format(label))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_TextWrapped(ctx, 'Sets the same color on every audio item on ' ..
      'this track. Overrides Reasonate status auto-coloring per item. Track header ' ..
      'color (TCP) unchanged.')
    reaper.ImGui_PopStyleColor(ctx, 1)
  elseif s.target_kind == 'item' then
    local it = helpers.find_item_by_guid(s.target_guid)
    local take = it and reaper.GetActiveTake(it) or nil
    local take_name = ''
    if take then
      local _
      _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
    end
    if take_name == '' then take_name = '(unnamed)' end
    reaper.ImGui_Text(ctx, ('Item color: %s'):format(take_name))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_TextWrapped(ctx, 'Single item override. Status auto-coloring ' ..
      'leaves this item alone until you clear.')
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Preset grid 4×3
  local SWATCH_SIZE = 32
  local PER_ROW = 4
  for i, p in ipairs(colors.TRACK_PRESETS) do
    local r, g, b = p[1], p[2], p[3]
    local rgba = (r << 24) | (g << 16) | (b << 8) | 0xFF
    if reaper.ImGui_ColorButton(ctx, ('##preset_%d'):format(i), rgba,
        reaper.ImGui_ColorEditFlags_NoTooltip(),
        SWATCH_SIZE, SWATCH_SIZE) then
      apply_color(colors.rgb_to_native(r, g, b))
      reaper.ImGui_CloseCurrentPopup(ctx)
      s.target_guid = nil; s.target_track_guid = nil; s.target_kind = nil
      reaper.ImGui_EndPopup(ctx)
      return
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, p[4])
    end
    if i % PER_ROW ~= 0 then
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  if not s.custom_open then
    if theme.button_ghost(ctx, 'Custom color...##expand', 140, 0) then
      s.custom_open = true
    end
  else
    local rv, new_rgb = reaper.ImGui_ColorPicker3(ctx,
      '##custom', s.custom_color_rgb,
      reaper.ImGui_ColorEditFlags_NoSidePreview()
      | reaper.ImGui_ColorEditFlags_NoSmallPreview()
      | reaper.ImGui_ColorEditFlags_NoAlpha())
    if rv then
      s.custom_color_rgb = new_rgb
      local r = (new_rgb >> 16) & 0xFF
      local g = (new_rgb >> 8)  & 0xFF
      local b = new_rgb & 0xFF
      apply_color(colors.rgb_to_native(r, g, b))
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Footer: Clear (lewa) + Close (prawa)
  if theme.button_neutral(ctx, 'Clear color', 110, 0) then
    clear_color()
    reaper.ImGui_CloseCurrentPopup(ctx)
    s.target_guid = nil; s.target_track_guid = nil; s.target_kind = nil
  end
  reaper.ImGui_SameLine(ctx)
  if theme.button_primary(ctx, 'Close', 110, 0) then
    reaper.ImGui_CloseCurrentPopup(ctx)
    s.target_guid = nil; s.target_track_guid = nil; s.target_kind = nil
  end

  reaper.ImGui_EndPopup(ctx)
end

return M
