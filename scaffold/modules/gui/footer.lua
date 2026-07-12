-- modules/gui/footer.lua
-- Status footer = globalny pasek aktywności (Pakiet A, W3 2026-06-10).
-- Lewa strona: chipy aktywności z modules/activity.collect (spinner + etap +
-- i/n; błąd = czerwony chip z [Retry]); gdy nic nie działa — action_msg /
-- "Ready" jak dotąd. Prawa strona: shortcuty + ⓘ (wersje w tooltipie).

local theme       = require 'modules.theme'
local voice_admin = require 'modules.voice_admin'

local M = {}

local MAX_CHIPS = 3

local function chip_text(a)
  local txt = a.label
  if a.total and a.total > 0 then
    txt = ('%s %d/%d'):format(txt, a.done or 0, a.total)
  end
  return txt
end

local function render_chip(ctx, a)
  if a.kind == 'error' then
    reaper.ImGui_TextColored(ctx, theme.COLORS.status_error, '● ' .. chip_text(a))
  elseif a.kind == 'record' then
    reaper.ImGui_TextColored(ctx, theme.COLORS.status_error, '● ' .. chip_text(a))
  else
    reaper.ImGui_TextColored(ctx, theme.COLORS.status_running,
      voice_admin.spinner_glyph() .. ' ' .. chip_text(a))
  end
  if a.tooltip and reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, a.tooltip)
  end
  if a.kind == 'error' and a.retry then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    if reaper.ImGui_SmallButton(ctx, 'Retry##act_' .. (a.id or '?')) then
      a.retry()
    end
  end
end

----------------------------------------------------------------------------
-- Render. opts: { activities, msg, msg_color, mod_label,
--                 env = { reaper, imgui, reaimgui, curl_path, concurrency } }
----------------------------------------------------------------------------
function M.render(ctx, opts)
  reaper.ImGui_Separator(ctx)
  theme.push_caption(ctx)

  reaper.ImGui_AlignTextToFramePadding(ctx)
  local acts = opts.activities or {}
  if #acts > 0 then
    local shown = math.min(#acts, MAX_CHIPS)
    for i = 1, shown do
      if i > 1 then
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
        reaper.ImGui_TextDisabled(ctx, '·')
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
      end
      render_chip(ctx, acts[i])
    end
    if #acts > shown then
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
      reaper.ImGui_TextDisabled(ctx, ('+%d'):format(#acts - shown))
      if reaper.ImGui_IsItemHovered(ctx) then
        local lines = {}
        for i = shown + 1, #acts do lines[#lines + 1] = chip_text(acts[i]) end
        reaper.ImGui_SetTooltip(ctx, table.concat(lines, '\n'))
      end
    end
  elseif opts.msg and opts.msg ~= '' then
    reaper.ImGui_TextColored(ctx, opts.msg_color or theme.COLORS.text_dim, opts.msg)
  else
    reaper.ImGui_TextDisabled(ctx, 'Ready')
  end

  -- Right-aligned shortcuts + ⓘ. Estymacja ~6px/char zostaje (surgical);
  -- CalcTextSize JEST w Lua (M7 errata — stary komentarz kłamał).
  -- T10 (user-caught 2026-07-11): tekst był statyczny "Convert" z ery
  -- single-mode — kłamał w TTS/Repair/Dubbing/SFX. Mapa per tryb, tylko
  -- skróty, które ten tryb NAPRAWDĘ obsługuje (process_shortcuts per mode).
  local mod = opts.mod_label or 'Cmd'
  local MODE_SHORTCUTS = {
    voice_replacement = mod .. '+⏎ Convert   ⎋ Cancel batch',
    tts               = mod .. '+⏎ Generate',
    -- 'Tab' tekstem — ⇥ U+21E5 niezweryfikowany w Inter (safe-list).
    repair            = mod .. '+⏎ Apply edit   Tab Mode   ⎋ Clear selection',
  }
  local mode_part = MODE_SHORTCUTS[opts.current_mode]
  local shortcut_text = (mode_part and (mode_part .. '   ') or '')
    .. mod .. '+, Settings'
  local tw_est = #shortcut_text * 6
  local INFO_W = 26
  local total_right = tw_est + theme.SPACING.md + INFO_W
  local avail = reaper.ImGui_GetContentRegionAvail(ctx)
  if avail > total_right + 60 then
    reaper.ImGui_SameLine(ctx, 0, avail - total_right)
    reaper.ImGui_TextDisabled(ctx, shortcut_text)
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    reaper.ImGui_TextDisabled(ctx, 'i')
    if reaper.ImGui_IsItemHovered(ctx) then
      local env = opts.env or {}
      reaper.ImGui_SetTooltip(ctx, ('REAPER %s · ImGui %s · ReaImGui %s\ncurl %s\nconcurrency %d')
        :format(env.reaper or '?', env.imgui or '?', env.reaimgui or '?',
                env.curl_path or '?', env.concurrency or 0))
    end
  end

  theme.pop_caption(ctx)
end

return M
