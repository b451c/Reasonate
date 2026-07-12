-- modules/gui/action_band.lua
-- Dolny pas akcji: primary CTA Convert + secondary Variants.
-- NS-1: zawsze widoczny (batch UI przeniesiony do batch_dialog floating window).
-- Convert/Variants disabled gdy batch w trakcie — żeby nie clobber'ować
-- batch_dialog state'a nowym confirm'em.

local theme = require 'modules.theme'

local M = {}

----------------------------------------------------------------------------
-- Render. opts: { n_sel, has_api_key, mod_label, batch_active }
-- Zwraca tabelę zdarzeń: { convert_clicked, variants_clicked }
----------------------------------------------------------------------------
function M.render(ctx, opts)
  local out = { convert_clicked = false, variants_clicked = false }
  local n_sel = opts.n_sel or 0
  local batch_active = opts.batch_active or false

  local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local PRIMARY_W = math.max(220, math.floor(avail_w * 0.42))
  local PRIMARY_H = 36

  local convert_label = batch_active
    and 'Batch in progress…'
    or ((n_sel > 0)
        and (('Convert selected (%d)'):format(n_sel))
        or  'Convert selected')

  local convert_disabled = batch_active or n_sel < 1
  reaper.ImGui_BeginDisabled(ctx, convert_disabled)
  if theme.button_primary(ctx, convert_label .. '##act_convert', PRIMARY_W, PRIMARY_H) then
    out.convert_clicked = true
  end
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx) then
    if batch_active then
      reaper.ImGui_SetTooltip(ctx, 'Wait for current batch to finish (or cancel it)')
    elseif n_sel == 0 then
      reaper.ImGui_SetTooltip(ctx, 'Select item(s) in timeline first')
    else
      reaper.ImGui_SetTooltip(ctx,
        ('%s+Enter — convert all %d selected items'):format(opts.mod_label or 'Cmd', n_sel))
    end
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  local variants_disabled = batch_active or n_sel ~= 1
  reaper.ImGui_BeginDisabled(ctx, variants_disabled)
  if theme.button_neutral(ctx, 'Variants…##act_variants', 130, PRIMARY_H) then
    out.variants_clicked = true
  end
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx) then
    if batch_active then
      reaper.ImGui_SetTooltip(ctx, 'Wait for current batch to finish (or cancel it)')
    elseif n_sel == 1 then
      reaper.ImGui_SetTooltip(ctx, 'Generate N takes with random seeds for the selected item')
    else
      reaper.ImGui_SetTooltip(ctx,
        ('Variants — select exactly 1 item (%d selected)'):format(n_sel))
    end
  end

  -- Subtelny shortcut hint po prawej (caption)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  theme.push_caption(ctx)
  reaper.ImGui_TextDisabled(ctx, ('%s+⏎'):format(opts.mod_label or 'Cmd'))
  theme.pop_caption(ctx)

  return out
end

return M
