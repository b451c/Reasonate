-- modules/gui/header_bar.lua
-- App bar: tytuł + subtitle voices status + 3 right-aligned ghost buttons
-- (Voice Manager / Library / Settings).
--
-- 2026-05-14 PM8: Casts removed z global header — przeniesione do
-- Voice Replacement mode stats_strip (mode-specific feature, legacy ReaCast
-- gdy był tylko single mode).
--
-- Right-click na tytule "Reasonate" otwiera context menu z dock options
-- (Floating + REAPER dockers 1-16). ReaImGui nie wstrzykuje native REAPER
-- title-bar menu, więc renderujemy własne via BeginPopupContextItem.

local theme       = require 'modules.theme'
local voice_admin = require 'modules.voice_admin'
local util        = require 'modules.util'

local M = {}

local BTN_W   = 110
local BTN_GAP = 4
local SUPPORT_BTN_W = 28

-- T4 (UX-POLISH): linki wsparcia twórcy (te same co w ReDockIT/EditView).
local SUPPORT_LINKS = {
  { label = 'Ko-fi',           url = 'https://ko-fi.com/quickmd' },
  { label = 'Buy Me a Coffee', url = 'https://buymeacoffee.com/bsroczynskh' },
  { label = 'PayPal',          url = 'https://paypal.me/b451c' },
}

-- Thousands separator (european style — space). Used for TTS char counter.
local function fmt_thousands(n)
  local s = tostring(math.floor(n or 0))
  return (s:reverse():gsub('(%d%d%d)', '%1 '):reverse():gsub('^%s+', ''))
end

----------------------------------------------------------------------------
-- Dock context menu — minimal: Undock / Dock toggle.
-- "Dock" wskazuje docker 1 (REAPER default). User może potem przeciągnąć
-- okno do innego dockera natywnie jeśli chce. Zwraca dock_id albo nil.
----------------------------------------------------------------------------
local function render_dock_menu(ctx, current_dock_id)
  local picked = nil
  local is_floating = current_dock_id == 0

  if reaper.ImGui_MenuItem(ctx, 'Undock (Floating)', nil, is_floating) then
    picked = 0
  end
  if reaper.ImGui_MenuItem(ctx, 'Dock', nil, not is_floating) then
    picked = -1   -- REAPER docker 1; user może przeciągnąć do innego
  end

  return picked
end

----------------------------------------------------------------------------
-- Render the 3 ghost buttons (Voice Manager / Library / Settings).
-- Casts intentionally absent — moved do stats_strip w Voice Replacement mode.
----------------------------------------------------------------------------
local function render_buttons(ctx, opts)
  local out = { settings = false, voice_manager = false, library = false }

  -- T4 (UX-POLISH): dyskretne ♥ wsparcia twórcy (wzorzec MaxPane/SneakPeak).
  -- Serce rysowane DrawList (2 koła + trójkąt) — glyph U+2665 renderował
  -- się niecentrycznie w ramce przycisku (krzywe side-bearingi Inter; ta
  -- sama klasa co ▼ → AddTriangleFilled w KNOWN-ISSUES). Geometria liczona
  -- ze środka item rect = idealne centrowanie niezależnie od fontu.
  if theme.button_ghost(ctx, '##hdr_support', SUPPORT_BTN_W, 0) then
    reaper.ImGui_OpenPopup(ctx, 'hdr_support_menu')
  end
  local sup_hover = reaper.ImGui_IsItemHovered(ctx)
  do
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local min_x, min_y = reaper.ImGui_GetItemRectMin(ctx)
    local max_x, max_y = reaper.ImGui_GetItemRectMax(ctx)
    local cx = (min_x + max_x) / 2
    local cy = (min_y + max_y) / 2
    local col = sup_hover and 0xE17878FF or 0xB06060FF
    -- Dwa górne łuki + korpus: koła r=2.9 przy (±2.6, -1.4), trójkąt do
    -- czubka (0, +5.2). Proporcje strojone pod 28px slot.
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx - 2.6, cy - 1.4, 2.9, col)
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx + 2.6, cy - 1.4, 2.9, col)
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      cx - 5.3, cy - 0.4, cx + 5.3, cy - 0.4, cx, cy + 5.2, col)
  end
  if sup_hover then
    reaper.ImGui_SetTooltip(ctx, 'Support the developer')
  end
  if reaper.ImGui_BeginPopup(ctx, 'hdr_support_menu') then
    reaper.ImGui_TextDisabled(ctx, 'Support Reasonate development')
    reaper.ImGui_Separator(ctx)
    for _, link in ipairs(SUPPORT_LINKS) do
      if reaper.ImGui_Selectable(ctx, link.label .. '##hdr_sup_' .. link.label, false) then
        util.open_url(link.url)
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end
  reaper.ImGui_SameLine(ctx, 0, BTN_GAP)

  reaper.ImGui_BeginDisabled(ctx, not opts.has_api_key)
  if theme.button_ghost(ctx, 'Voice Manager##hdr_vm', BTN_W, 0) then
    out.voice_manager = true
  end
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Manage your ElevenLabs voices · rename · delete · sync')
  end

  reaper.ImGui_SameLine(ctx, 0, BTN_GAP)
  reaper.ImGui_BeginDisabled(ctx, not opts.has_api_key)
  if theme.button_ghost(ctx, 'Library##hdr_lib', BTN_W, 0) then
    out.library = true
  end
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Browse public ElevenLabs Voice Library + import voices')
  end

  reaper.ImGui_SameLine(ctx, 0, BTN_GAP)
  if theme.button_ghost(ctx, 'Settings##hdr_settings', BTN_W, 0) then
    out.settings = true
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'API key · cache · defaults')
  end

  return out
end

----------------------------------------------------------------------------
-- Public render. opts: { has_api_key, voices_source, voices_count,
--                        voices_age_min, current_dock_id }
-- Returns: { settings, refresh, casts, set_dock_id }
----------------------------------------------------------------------------
function M.render(ctx, opts)
  local out = { settings = false, voice_manager = false, library = false,
                set_dock_id = nil, open_releases = false }
  local total_btn = BTN_W * 3 + SUPPORT_BTN_W + BTN_GAP * 3

  -- 1. Tytuł — Inter SemiBold 22pt. Right-click = dock menu.
  theme.push_heading(ctx, theme.SIZE.display)
  reaper.ImGui_Text(ctx, 'Reasonate')
  theme.pop_heading(ctx)

  -- Right-click context menu na tytule (BeginPopupContextItem przywiązuje
  -- się do PREVIOUS item — Text przed chwilą).
  if reaper.ImGui_BeginPopupContextItem(ctx, 'reasonate_dock_menu') then
    local picked = render_dock_menu(ctx, opts.current_dock_id or 0)
    if picked ~= nil then
      out.set_dock_id = picked
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- Hover hint na title — żeby user wiedział że right-click coś robi
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Right-click for dock options')
  end

  -- 2. Subtitle inline (caption, dim) — voices status
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  theme.push_caption(ctx)
  local subtitle
  if opts.voices_source == 'api' then
    subtitle = ('· %d voices'):format(opts.voices_count or 0)
  elseif opts.voices_source == 'cache' then
    subtitle = ('· %d voices · cache %dm'):format(
      opts.voices_count or 0, opts.voices_age_min or 0)
  else
    subtitle = '· no voices loaded'
  end
  reaper.ImGui_TextDisabled(ctx, subtitle)
  theme.pop_caption(ctx)

  -- Update-check: dyskretna nutka po cichym starcie (PHASE-USER-GUIDE §3
  -- — nigdy modal). Widoczna tylko gdy znaleziono nowszą wersję.
  if opts.update_tag then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    if reaper.ImGui_SmallButton(ctx, ('Update %s##hdr_upd'):format(opts.update_tag)) then
      out.open_releases = true
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, 'A newer version is available - open the releases page')
    end
  end

  -- 3. Right-align action buttons na tej samej linii. Quota indicator
  --    (PM9 iter4) renderowany po lewej od buttons jako slim ProgressBar
  --    + "X% used" caption + tooltip z full details.
  local win_w = reaper.ImGui_GetWindowWidth(ctx)
  local target_x = win_w - theme.SPACING.lg - total_btn

  -- Quota strip: bar 100×8 + " X% used" text. Total ~150px width budget.
  local QUOTA_BAR_W = 100
  local QUOTA_BAR_H = 8
  local quota_total_w = 0
  local has_quota = opts.quota_status == 'ok'
    and opts.quota_total and opts.quota_total > 0
  local quota_pct = 0
  local quota_pct_str = ''
  if has_quota then
    quota_pct = math.min(1.0, (opts.quota_used or 0) / opts.quota_total)
    quota_pct_str = (' %d%% used'):format(math.floor(quota_pct * 100 + 0.5))
    local tw = reaper.ImGui_CalcTextSize(ctx, quota_pct_str)
    quota_total_w = QUOTA_BAR_W + (tw or 0) + theme.SPACING.lg
  end

  local btn_out
  if target_x > 220 then
    if has_quota and target_x - quota_total_w > 220 then
      reaper.ImGui_SameLine(ctx, target_x - quota_total_w, 0)
      -- Color tier per usage: red >95% / yellow 80-95% / amber default
      local bar_color = theme.COLORS.primary
      if quota_pct >= 0.95 then bar_color = theme.COLORS.danger
      elseif quota_pct >= 0.80 then bar_color = theme.COLORS.status_stale end
      -- Vertical center bar w line: AlignTextToFramePadding nie dotyczy
      -- ProgressBar, użyj small SetCursorPosY shift dla visual balance.
      local cur_y = select(2, reaper.ImGui_GetCursorPos(ctx))
      reaper.ImGui_SetCursorPosY(ctx, cur_y + 8)   -- center 8px bar w ~22px line
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PlotHistogram(), bar_color)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x2D2D2DFF)
      reaper.ImGui_ProgressBar(ctx, quota_pct, QUOTA_BAR_W, QUOTA_BAR_H, '')
      reaper.ImGui_PopStyleColor(ctx, 2)
      local hover_bar = reaper.ImGui_IsItemHovered(ctx)
      reaper.ImGui_SetCursorPosY(ctx, cur_y)
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_TextDisabled(ctx, quota_pct_str)
      if hover_bar or reaper.ImGui_IsItemHovered(ctx) then
        local left = (opts.quota_total or 0) - (opts.quota_used or 0)
        local reset_str = 'unknown'
        if opts.quota_reset_unix and opts.quota_reset_unix > 0 then
          local days = math.floor((opts.quota_reset_unix - os.time()) / 86400)
          if days <= 0 then reset_str = 'today / past due'
          elseif days == 1 then reset_str = 'in 1 day'
          else reset_str = ('in %d days'):format(days) end
        end
        reaper.ImGui_SetTooltip(ctx, ('ElevenLabs account quota\n' ..
          'Used:      %s chars\n' ..
          'Total:     %s chars\n' ..
          'Remaining: %s chars\n' ..
          'Tier:      %s\n' ..
          'Resets:    %s'):format(
          fmt_thousands(opts.quota_used or 0),
          fmt_thousands(opts.quota_total or 0),
          fmt_thousands(left),
          tostring(opts.quota_tier or 'unknown'),
          reset_str))
      end
    elseif opts.quota_status == 'error' and target_x - 80 > 220 then
      reaper.ImGui_SameLine(ctx, target_x - 80, 0)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_TextColored(ctx, theme.COLORS.status_error, 'Quota: ?')
      if reaper.ImGui_IsItemHovered(ctx) then
        local err_suffix = opts.quota_error and ('\n' .. tostring(opts.quota_error)) or ''
        reaper.ImGui_SetTooltip(ctx,
          'Quota fetch failed. Check API key in Settings.' .. err_suffix)
      end
    elseif opts.quota_status == 'fetching' and target_x - 100 > 220 then
      -- Active async fetch — spinner glyph (mirror voice_admin spinner pattern).
      reaper.ImGui_SameLine(ctx, target_x - 100, 0)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_TextDisabled(ctx, ('Quota: %s'):format(voice_admin.spinner_glyph()))
    elseif opts.quota_status == 'unknown' and opts.has_api_key
      and target_x - 100 > 220 then
      -- Loading state: API key set ale first refresh tick jeszcze nie odpalił
      -- (initial 30-frame startup delay).
      reaper.ImGui_SameLine(ctx, target_x - 100, 0)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_TextDisabled(ctx, 'Quota: loading…')
    end
    reaper.ImGui_SameLine(ctx, target_x, 0)
    btn_out = render_buttons(ctx, opts)
  else
    reaper.ImGui_NewLine(ctx)
    btn_out = render_buttons(ctx, opts)
  end

  out.settings      = btn_out.settings
  out.voice_manager = btn_out.voice_manager
  out.library       = btn_out.library
  return out
end

return M
