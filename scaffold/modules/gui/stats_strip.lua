-- modules/gui/stats_strip.lua
-- Strip pod header: project counts + status pille (tylko niezerowe).

local theme = require 'modules.theme'

local M = {}

local STATUS_ORDER = { 'new', 'in_progress', 'converted', 'stale', 'error', 'output', 'skipped' }

function M.render(ctx, state)
  local out = { add_track_clicked = false, casts_clicked = false }
  local t = state.totals or {}

  -- Lewa strona: project tracks/voiced/items
  reaper.ImGui_AlignTextToFramePadding(ctx)
  theme.push_caption(ctx)
  reaper.ImGui_TextDisabled(ctx, 'PROJECT')
  theme.pop_caption(ctx)

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  -- T1 (UX-POLISH): output tracki ([AI]) nie liczą się jako "tracks" —
  -- "2 tracks · 1 voiced" przy 1 realnym źródle mylił. Osobny licznik AI.
  local n_out = t.output_tracks or 0
  local label = ('%d tracks · %d voiced · %d items'):format(
    math.max(0, #state.tracks - n_out), t.with_voice or 0, t.total_audio or 0)
  if n_out > 0 then
    label = label .. (' · %d AI'):format(n_out)
  end
  reaper.ImGui_Text(ctx, label)

  -- + Track ghost button — wstawia nowy track na końcu REAPER project.
  -- Zostaje refresh tick (500ms) który podchwytuje nowy track w cache.
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if theme.button_ghost(ctx, '+ Track##stats_add_track', 0, 0) then
    out.add_track_clicked = true
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Insert new track in REAPER (appended at end of project)')
  end

  -- Casts button — Voice Replacement-specific feature (track role → voice
  -- mapping). 2026-05-14 PM8: moved z global header tutaj (mode-scoped).
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if theme.button_ghost(ctx, 'Casts##stats_casts', 0, 0) then
    out.casts_clicked = true
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Save / load track role → voice mappings.\n'
      .. 'Cast = named preset z mapping speaker labels → voice IDs.\n'
      .. 'Voice Replacement only.')
  end

  -- Status pills — same line, right-aligned. Best effort; jeśli brak miejsca
  -- to ImGui zawinie automatycznie (SameLine 0 z dużym offset).
  local has_any_status = false
  for _, st in ipairs(STATUS_ORDER) do
    if (t[st] or 0) > 0 then has_any_status = true; break end
  end

  if has_any_status then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
    for _, st in ipairs(STATUS_ORDER) do
      local n = t[st] or 0
      if n > 0 then
        theme.status_pill(ctx, st, n)
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
      end
    end
    -- Wymusza nową linię po pills (kolejny element pójdzie na nową linię)
    reaper.ImGui_NewLine(ctx)
  end

  return out
end

return M
