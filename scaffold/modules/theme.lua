-- modules/theme.lua
-- Centralny theme: design tokens + custom font (Inter) + push/pop styles.
-- Cel: jeden punkt prawdy dla kolorów, spacingu, typografii. Wszystkie gui/*
-- używają theme.button_primary / theme.status_pill / theme.COLORS / theme.SPACING
-- zamiast hardcoded RGBA.
--
-- Wymagane: ReaImGui v0.10+ (ImGui_CreateFontFromFile, PushFont(ctx, font, size)).

local M = {}

----------------------------------------------------------------------------
-- Color tokens (0xRRGGBBAA)
----------------------------------------------------------------------------
M.COLORS = {
  -- Surfaces (subtelne, nadbudowują REAPER bg)
  surface_raised = 0x242424FF,
  surface_sunken = 0x171717FF,
  surface_hover  = 0x2A2A2AFF,
  border         = 0x2E2E2EFF,
  border_strong  = 0x3A3A3AFF,
  divider        = 0x252525FF,

  -- Text
  text           = 0xE8E8E8FF,
  text_dim       = 0x9A9A9AFF,
  text_muted     = 0x6B6B6BFF,
  text_on_amber  = 0x1A1A1AFF,   -- ciemny tekst na primary

  -- Brand / primary CTA — Studio amber
  primary        = 0xF59E0BFF,
  primary_hover  = 0xFBB935FF,
  primary_active = 0xD17F08FF,

  -- Secondary (default Button after theme.push)
  -- PM9 iter3: alpha reduced (FF→B0/D0/E0) — background.png widoczny przez
  -- przyciski subtle. Active opaque'iej dla wyraźnej feedback gdy klik.
  secondary       = 0x383838B0,
  secondary_hover = 0x474747D0,
  secondary_active= 0x2E2E2EE0,

  -- Destructive
  danger        = 0xDC4444FF,
  danger_hover  = 0xE85555FF,
  danger_active = 0xB83333FF,

  -- Status (jest mirror w colors.lua dla item I_CUSTOMCOLOR; tu tokeny do GUI)
  status_new      = 0xFFC864FF,
  status_pending  = 0x5096FFFF,
  status_done     = 0x64C878FF,
  status_error    = 0xDC5A5AFF,
  status_stale    = 0xEAB308FF,   -- chrome yellow (był amber, kolidował z primary)
  status_output   = 0xB482DCFF,
  status_skipped  = 0x8C8C8CFF,
  -- W3 UI/UX (2026-06-10): praca async W TOKU. Odróżnialny od primary
  -- (CTA) i status_stale (yellow) — wcześniej jeden amber niósł ~6 znaczeń.
  status_running  = 0xFFB060FF,

  -- Override indicator (per-track voice_settings) — teal, bez konfliktu z amber
  override        = 0x14B8A6FF,

  -- Soft amber-tinted surfaces (W3 2026-06-10) — przygaszone "powiązane
  -- z selekcją, ale nie wybrane" (np. context words w Repair transcript)
  amber_soft        = 0x4A3A1FFF,
  amber_soft_hover  = 0x5A4828FF,
  amber_soft_active = 0x3A2E18FF,

  -- Frame fill (input fields, sliders, combos) — kontrastowe wobec window bg
  -- ale z transparency żeby background.png prześwitywał (PM9 iter3).
  -- Active stage opaque'iej żeby wyraźny "edit mode" feedback przy focus.
  frame_bg         = 0x2D2D2DB0,
  frame_bg_hover   = 0x363636D0,
  frame_bg_active  = 0x3F3F3FE0,
}

----------------------------------------------------------------------------
-- Mode accent colors (W3 2026-06-10) — jedno źródło prawdy dla kart trybów
-- (mode_selector), proceduralnego tła (reasonate.lua) i przyszłych akcentów.
----------------------------------------------------------------------------
M.MODE_ACCENTS = {
  tts               = 0x14B8A6FF,   -- teal
  voice_replacement = 0xF59E0BFF,   -- amber
  dubbing           = 0x6366F1FF,   -- indigo
  repair            = 0x9B6BFAFF,   -- lavender/violet
  sfx               = 0xF43F5EFF,   -- rose (NS-SFX 2026-06-10)
}

----------------------------------------------------------------------------
-- Spacing (px)
----------------------------------------------------------------------------
M.SPACING = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32 }

----------------------------------------------------------------------------
-- Font sizes
----------------------------------------------------------------------------
M.SIZE = {
  caption = 11,
  body    = 13,
  body_lg = 15,
  heading = 17,
  display = 22,
}

----------------------------------------------------------------------------
-- Font init: load + attach Inter Regular + SemiBold. Idempotentne.
----------------------------------------------------------------------------
M.FONTS = nil
M.font_loaded = false

----------------------------------------------------------------------------
-- 2026-05-14 PM8: shared main-window geometry helper.
-- reasonate.lua main loop calls `M.set_main_center(cx, cy)` co frame z
-- centrem głównego okna (po Begin). Każdy modal renderer może wywołać
-- `M.center_next_modal(ctx, w, h)` przed BeginPopupModal żeby modal pojawił
-- się centered w głównym oknie (NIE screen) — działa też gdy główne okno
-- jest na innym monitorze.
--
-- Cond_Appearing → ustawia tylko przy każdym popup open, user może później
-- przesunąć modal (preserved przez ImGui internal state aż do close).
----------------------------------------------------------------------------
M._main_cx = nil
M._main_cy = nil

function M.set_main_center(cx, cy)
  M._main_cx = cx
  M._main_cy = cy
end

-- W3 UI/UX (2026-06-10): work area viewportu (x, y, w, h) dla clampu modali
-- i popupów pozycjonowanych przy myszy. ReaImGui Lua MA Viewport_GetWorkPos/
-- GetWorkSize (multi-return; zweryfikowane w ReaImGui_Demo.lua linie
-- 8526-8528 — index MCP błędnie raportuje c/eel2-only). Presence-check
-- + pcall = graceful degrade (nil → caller pomija clamp).
function M.viewport_work_rect(ctx)
  if not (reaper.ImGui_GetMainViewport and reaper.ImGui_Viewport_GetWorkSize
          and reaper.ImGui_Viewport_GetWorkPos) then
    return nil
  end
  local ok, vp = pcall(reaper.ImGui_GetMainViewport, ctx)
  if not (ok and vp) then return nil end
  local okp, vx, vy = pcall(reaper.ImGui_Viewport_GetWorkPos, vp)
  local oks, vw, vh = pcall(reaper.ImGui_Viewport_GetWorkSize, vp)
  if not (okp and oks and type(vw) == 'number' and vw > 0) then return nil end
  return vx, vy, vw, vh
end

function M.center_next_modal(ctx, w, h, cond)
  if not (M._main_cx and M._main_cy) then return end
  cond = cond or reaper.ImGui_Cond_Appearing()
  local cx, cy = M._main_cx, M._main_cy
  if w and h then
    -- Fixed-size modale (h > 0) clampowane do ~92% work area — sztywne
    -- 980×640 itp. wychodziły poza okno na małych ekranach. h == 0
    -- (auto-fit height) zostaje bez zmian — te modale są małe.
    if h > 0 then
      local vx, vy, vw, vh = M.viewport_work_rect(ctx)
      if vw then
        w = math.min(w, math.floor(vw * 0.92))
        h = math.min(h, math.floor(vh * 0.92))
        -- W3 (2026-06-10, user-reported): clamp POZYCJI, nie tylko rozmiaru.
        -- Pivot = środek głównego okna Reasonate — gdy panel jest zadokowany
        -- nisko/przy krawędzi, modal otwierał się ucięty krawędzią ekranu
        -- mimo poprawnego rozmiaru (live: Segment inspector ucięty na dole).
        -- Środek dosuwany tak, by cały prostokąt mieścił się w work area.
        local margin = 12
        cx = math.max(vx + w / 2 + margin, math.min(cx, vx + vw - w / 2 - margin))
        cy = math.max(vy + h / 2 + margin, math.min(cy, vy + vh - h / 2 - margin))
      end
    end
    reaper.ImGui_SetNextWindowPos(ctx, cx, cy, cond, 0.5, 0.5)
    reaper.ImGui_SetNextWindowSize(ctx, w, h, cond)
  else
    reaper.ImGui_SetNextWindowPos(ctx, cx, cy, cond, 0.5, 0.5)
  end
end

----------------------------------------------------------------------------
-- 2026-05-14 PM9 iter3 v2: force-keep popup modal on top of ImGui z-order.
--
-- Why: per diag data 2026-05-14, ReaImGui v0.10.0.5 modal popups lose
-- z-order against main window content (visually "stuck behind"), even
-- though IsWindowFocused reports popup focused. Globalne modale dispatched
-- po End głównego window (reasonate.lua line 438+) — może contributing.
--
-- v1 attempt: SetNextWindowFocus before BeginPopupModal (consumed by next
-- Begin). FAILED per live test 2026-05-14 — modal still hides under main.
--
-- v2: SetWindowFocusEx(ctx, popup_id) — direct named target. Forces named
-- window to top of z-stack regardless of Begin call ordering. Safe when
-- popup is closed (IsPopupOpen guard skips the call).
--
-- v3 (W3 fix, 2026-06-10 — REGRESJA user-reported): v2 wymuszał focus CO
-- KLATKĘ przez cały czas życia modala. Combo/nested popup wewnątrz modala
-- otwiera się jako popup NAD modalem — wymuszenie focusu na rodzicu w
-- następnej klatce zamyka go natychmiast (ImGui ClosePopupsOverWindow) →
-- wszystkie comba w modalach wyglądały na martwe (Start Dubbing TTS model /
-- Style preset, filtry voice pickera, Settings...). Fix: focus wymuszany
-- TYLKO przy przejściu closed→open (stuck-behind bug występuje przy
-- otwarciu; otwarty modal blokuje input i nie ma jak zostać zakopany).
----------------------------------------------------------------------------
local keep_top_fired = {}

function M.popup_keep_top(ctx, popup_id)
  if reaper.ImGui_IsPopupOpen(ctx, popup_id) then
    if not keep_top_fired[popup_id] then
      keep_top_fired[popup_id] = true
      reaper.ImGui_SetWindowFocusEx(ctx, popup_id)
    end
  else
    keep_top_fired[popup_id] = nil
  end
end

function M.init(ctx, script_dir)
  if M.font_loaded then return true end

  local font_dir = (script_dir or '') .. 'assets/fonts/'
  local reg_path = font_dir .. 'Inter-Regular.ttf'
  local sb_path  = font_dir .. 'Inter-SemiBold.ttf'

  local ok_r, font_regular  = pcall(reaper.ImGui_CreateFontFromFile, reg_path)
  local ok_s, font_semibold = pcall(reaper.ImGui_CreateFontFromFile, sb_path)

  -- Fallback: gdy plików nie ma, użyj system sans-serif (named font)
  if not (ok_r and font_regular) then
    ok_r, font_regular = pcall(reaper.ImGui_CreateFont, 'sans-serif')
  end
  if not (ok_s and font_semibold) then
    ok_s, font_semibold = pcall(reaper.ImGui_CreateFont, 'sans-serif-bold')
    if not (ok_s and font_semibold) then
      -- Ostatni fallback — semibold = regular
      font_semibold = font_regular
      ok_s = ok_r
    end
  end

  if not (ok_r and font_regular) then
    return false  -- nie udało się załadować nawet system fontu
  end

  reaper.ImGui_Attach(ctx, font_regular)
  if font_semibold and font_semibold ~= font_regular then
    reaper.ImGui_Attach(ctx, font_semibold)
  end

  M.FONTS = { regular = font_regular, semibold = font_semibold }
  M.font_loaded = true
  return true
end

----------------------------------------------------------------------------
-- Push / pop globalny theme (ramy stylu dla całego frame)
----------------------------------------------------------------------------
local PUSHED_VAR_COUNT = 0
local PUSHED_COL_COUNT = 0

function M.push(ctx)
  -- Style vars (counted)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),     6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(),      6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_PopupRounding(),     8.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(),     6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarRounding(), 8.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_TabRounding(),       6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),     10, 6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),      10, 8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemInnerSpacing(),  6, 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),    16, 14)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_CellPadding(),       8, 6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize(),    12)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabMinSize(),       8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_SeparatorTextBorderSize(), 1)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_SeparatorTextPadding(),    16, 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(),         1.0)
  PUSHED_VAR_COUNT = 16

  -- Style colors
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),             M.COLORS.text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TextDisabled(),     M.COLORS.text_dim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),           M.COLORS.secondary)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),    M.COLORS.secondary_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),     M.COLORS.secondary_active)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),          M.COLORS.frame_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(),   M.COLORS.frame_bg_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),    M.COLORS.frame_bg_active)
  -- PM9 iter3: header alpha reduced — tab bar items prześwitują background.png.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),           0x2D2D2DB0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(),    0x363636D0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),     0x404040E0)
  -- Border używany dla okien I dla frame'ów (gdy FrameBorderSize > 0).
  -- Używamy border_strong żeby input boxy miały wyraźną krawędź.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),           M.COLORS.border_strong)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(),        M.COLORS.border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SeparatorHovered(), M.COLORS.border_strong)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderLight(), M.COLORS.border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableBorderStrong(),M.COLORS.border_strong)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableHeaderBg(),    0x1F1F1FB0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableRowBg(),       0x00000000)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TableRowBgAlt(),    0x1E1E1E80)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(),       M.COLORS.primary)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(), M.COLORS.primary_active)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(),        M.COLORS.primary)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),          0x1A1A1AFB)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ModalWindowDimBg(), 0x000000B0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(),      0x14141400)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(),    0x404040FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabHovered(), 0x4D4D4DFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabActive(),  0x595959FF)
  PUSHED_COL_COUNT = 28

  -- Body font (size 13) — pushed if loaded
  if M.FONTS and M.FONTS.regular then
    reaper.ImGui_PushFont(ctx, M.FONTS.regular, M.SIZE.body)
  end
end

function M.pop(ctx)
  if M.FONTS and M.FONTS.regular then
    reaper.ImGui_PopFont(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, PUSHED_COL_COUNT)
  reaper.ImGui_PopStyleVar(ctx,   PUSHED_VAR_COUNT)
end

----------------------------------------------------------------------------
-- Typography helpers (font + size — wymaga uprzedniego pop body fontu)
----------------------------------------------------------------------------
function M.push_heading(ctx, size)
  if not (M.FONTS and M.FONTS.semibold) then return false end
  -- Body font był pushnięty w M.push; trzeba go najpierw popnąć żeby PushFont
  -- nie nakładał się. ALBO — ImGui obsługuje stack, więc Push semibold = stack
  -- top. Potem PopFont przywróci body. Tak jest OK.
  reaper.ImGui_PushFont(ctx, M.FONTS.semibold, size or M.SIZE.heading)
  return true
end
-- M0-3 (audit 2026-07): pop_* symetryczne z push_* — gdy M.FONTS==nil
-- (totalny fail load fontów) push nic nie pushuje, więc bezwarunkowy
-- PopFont robiłby underflow font stacka.
function M.pop_heading(ctx)
  if M.FONTS and M.FONTS.semibold then reaper.ImGui_PopFont(ctx) end
end

function M.push_body_lg(ctx)
  if not (M.FONTS and M.FONTS.regular) then return false end
  reaper.ImGui_PushFont(ctx, M.FONTS.regular, M.SIZE.body_lg)
  return true
end
function M.pop_body_lg(ctx)
  if M.FONTS and M.FONTS.regular then reaper.ImGui_PopFont(ctx) end
end

function M.push_caption(ctx)
  if not (M.FONTS and M.FONTS.regular) then return false end
  reaper.ImGui_PushFont(ctx, M.FONTS.regular, M.SIZE.caption)
  return true
end
function M.pop_caption(ctx)
  if M.FONTS and M.FONTS.regular then reaper.ImGui_PopFont(ctx) end
end

----------------------------------------------------------------------------
-- Button helpers
----------------------------------------------------------------------------
function M.button_primary(ctx, label, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        M.COLORS.primary)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), M.COLORS.primary_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  M.COLORS.primary_active)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          M.COLORS.text_on_amber)
  local clicked = reaper.ImGui_Button(ctx, label, w or 0, h or 0)
  reaper.ImGui_PopStyleColor(ctx, 4)
  return clicked
end

function M.button_danger(ctx, label, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        M.COLORS.danger)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), M.COLORS.danger_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  M.COLORS.danger_active)
  local clicked = reaper.ImGui_Button(ctx, label, w or 0, h or 0)
  reaper.ImGui_PopStyleColor(ctx, 3)
  return clicked
end

function M.button_neutral(ctx, label, w, h)
  -- Default theme button (secondary). Existing PushStyleColor in theme.push
  -- supplies the colors.
  return reaper.ImGui_Button(ctx, label, w or 0, h or 0)
end

function M.button_ghost(ctx, label, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x00000000)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x2E2E2EFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x383838FF)
  local clicked = reaper.ImGui_Button(ctx, label, w or 0, h or 0)
  reaper.ImGui_PopStyleColor(ctx, 3)
  return clicked
end

----------------------------------------------------------------------------
-- Segmented control — przełącznik widoków / trybów (W3 2026-06-11).
-- Jedna zaokrąglona obudowa; aktywny segment wypełniony kolorem akcentu
-- z ciemnym tekstem (mirror primary CTA), nieaktywne wygaszone, hover
-- rozjaśnia. Szerokości mierzone ZAWSZE SemiBoldem (szersza z dwóch wag),
-- więc segment nie zmienia szerokości gdy staje się aktywny.
--
-- items: { {key, label, accent?, tooltip?}, ... } — accent per item (pasek
--        trybów) albo wspólny przez opts.accent (sub-mode toggles).
-- opts:  { size='lg'|'sm' (default 'lg'), accent=0xRRGGBBAA }
-- Zwraca kliknięty key (różny od active_key) albo nil.
----------------------------------------------------------------------------
local function lighten(col, f)
  local r = (col >> 24) & 0xFF
  local g = (col >> 16) & 0xFF
  local b = (col >>  8) & 0xFF
  r = math.floor(r + (255 - r) * f + 0.5)
  g = math.floor(g + (255 - g) * f + 0.5)
  b = math.floor(b + (255 - b) * f + 0.5)
  return (r << 24) | (g << 16) | (b << 8) | (col & 0xFF)
end

local function calc_text_w(ctx, text, f_size)
  -- CalcTextSize JEST w Lua (multi-return; ReaImGui_Demo.lua:4788) — index MCP
  -- błędnie raportuje c/eel2-only (znany bug dla output-paramów, KNOWN-ISSUES).
  if reaper.ImGui_CalcTextSize then
    local w, h = reaper.ImGui_CalcTextSize(ctx, text)
    return w, h
  end
  return #text * f_size * 0.55, f_size  -- fallback: estymacja jak footer
end

function M.segmented(ctx, id, items, active_key, opts)
  opts = opts or {}
  local sm     = opts.size == 'sm'
  local f_size = M.SIZE.body
  local h      = sm and 24 or 30
  local pad_x  = sm and 12 or 16
  local inset  = sm and 2 or 3
  local round  = sm and 6 or 8

  local sb  = M.FONTS and M.FONTS.semibold
  local reg = M.FONTS and M.FONTS.regular

  -- Pomiar etykiet (SemiBold) → stałe szerokości segmentów.
  if sb then reaper.ImGui_PushFont(ctx, sb, f_size) end
  local widths, total = {}, 0
  for i, it in ipairs(items) do
    local tw = calc_text_w(ctx, it.label, f_size)
    widths[i] = math.floor(tw + 2 * pad_x + 0.5)
    total = total + widths[i]
  end
  if sb then reaper.ImGui_PopFont(ctx) end

  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  -- Faza 1: hit-testy. InvisibleButton nic nie rysuje — całe wizualia idą
  -- w fazie 2 (DrawList), dzięki czemu tło ląduje "pod" tekstem mimo że
  -- submitowane po buttonach.
  local seg, clicked = {}, nil
  reaper.ImGui_PushID(ctx, id)
  local x = x0
  for i, it in ipairs(items) do
    reaper.ImGui_SetCursorScreenPos(ctx, x, y0)
    local pressed = reaper.ImGui_InvisibleButton(ctx, '##seg_' .. it.key, widths[i], h)
    local hovered = reaper.ImGui_IsItemHovered(ctx)
    if hovered then
      reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
      if it.tooltip then reaper.ImGui_SetTooltip(ctx, it.tooltip) end
    end
    if pressed and it.key ~= active_key then clicked = it.key end
    seg[i] = { x = x, w = widths[i], hovered = hovered,
               held = reaper.ImGui_IsItemActive(ctx),
               active = (it.key == active_key) }
    x = x + widths[i]
  end
  reaper.ImGui_PopID(ctx)

  -- Faza 2: obudowa → wypełnienia → separatory → teksty → ramka.
  local x1 = x0 + total
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y0 + h,
    M.COLORS.surface_sunken, round)

  for i, it in ipairs(items) do
    local sg = seg[i]
    local px1, py1 = sg.x + inset, y0 + inset
    local px2, py2 = sg.x + sg.w - inset, y0 + h - inset
    if sg.active then
      local accent = it.accent or opts.accent or M.COLORS.primary
      reaper.ImGui_DrawList_AddRectFilled(dl, px1, py1, px2, py2,
        accent, round - inset)
      -- Cienka linia świetlna przy górnej krawędzi — subtelny połysk pilla.
      local sheen = (lighten(accent, 0.35) & 0xFFFFFF00) | 0x66
      reaper.ImGui_DrawList_AddLine(dl,
        px1 + round, py1 + 1, px2 - round, py1 + 1, sheen, 1)
    elseif sg.held then
      reaper.ImGui_DrawList_AddRectFilled(dl, px1, py1, px2, py2,
        M.COLORS.secondary_active, round - inset)
    elseif sg.hovered then
      reaper.ImGui_DrawList_AddRectFilled(dl, px1, py1, px2, py2,
        M.COLORS.surface_hover, round - inset)
    end
  end

  -- Pionowe separatory tylko między dwoma "spokojnymi" segmentami
  -- (Apple style: znikają przy aktywnym / hover sąsiedzie).
  for i = 1, #items - 1 do
    local a, b = seg[i], seg[i + 1]
    if not (a.active or b.active or a.hovered or b.hovered) then
      local dx = a.x + a.w
      reaper.ImGui_DrawList_AddLine(dl,
        dx, y0 + inset + 4, dx, y0 + h - inset - 4, M.COLORS.border, 1)
    end
  end

  for i, it in ipairs(items) do
    local sg = seg[i]
    local font = sg.active and sb or reg
    local col
    if sg.active then
      col = M.COLORS.text_on_amber
    elseif sg.hovered or sg.held then
      col = M.COLORS.text
    else
      col = M.COLORS.text_dim
    end
    if font then reaper.ImGui_PushFont(ctx, font, f_size) end
    local tw, th = calc_text_w(ctx, it.label, f_size)
    reaper.ImGui_DrawList_AddText(dl,
      math.floor(sg.x + (sg.w - tw) / 2 + 0.5),
      math.floor(y0 + (h - th) / 2 + 0.5),
      col, it.label)
    if font then reaper.ImGui_PopFont(ctx) end
  end

  reaper.ImGui_DrawList_AddRect(dl, x0, y0, x1, y0 + h, M.COLORS.border,
    round, reaper.ImGui_DrawFlags_RoundCornersAll(), 1)

  return clicked
end

----------------------------------------------------------------------------
-- Status pill — kolorowane tło + tekst, klikalne (clicked = ignorowany przez
-- caller). Umożliwia wizualną grupę "● 14 new" jako filled chip.
----------------------------------------------------------------------------
function M.status_pill(ctx, status, count)
  local colors_mod = require 'modules.colors'
  local p = colors_mod.PALETTE[status]
  if not p then return end

  -- Soft tinted bg (same hue, ~25% alpha)
  local r  = (p.rgba >> 24) & 0xFF
  local g  = (p.rgba >> 16) & 0xFF
  local bl = (p.rgba >>  8) & 0xFF
  local soft_bg = (r << 24) | (g << 16) | (bl << 8) | 0x40

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        soft_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), soft_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  soft_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          p.rgba)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 10, 3)

  reaper.ImGui_SmallButton(ctx, ('● %d %s##pill_%s'):format(count, p.label, status))

  reaper.ImGui_PopStyleVar(ctx, 1)
  reaper.ImGui_PopStyleColor(ctx, 4)
end

----------------------------------------------------------------------------
-- Override dot — mały kolorowy ● inline (np. obok voice name)
----------------------------------------------------------------------------
function M.override_dot(ctx, tooltip)
  reaper.ImGui_TextColored(ctx, M.COLORS.override, '●')
  if tooltip and reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, tooltip)
  end
end

----------------------------------------------------------------------------
-- Flash — transient inline confirmation (W3 quick wins, 2026-06-10).
-- Dla akcji których jedynym feedbackiem byłoby "modal się zamknął" (zapis /
-- delete presetu). Keyed per call site. draw_flash_inline = SameLine + tekst
-- z fade-out (alpha w kanale koloru — StyleVar_Alpha niepotrzebny); no-op
-- gdy nic aktywnego, więc bezpieczny do bezwarunkowego wywołania po wierszu.
----------------------------------------------------------------------------
local flashes = {}

function M.flash(key, text, color, secs)
  flashes[key] = { text = text, color = color or M.COLORS.status_done,
                   until_t = reaper.time_precise() + (secs or 2.8) }
end

function M.draw_flash_inline(ctx, key, spacing)
  local f = flashes[key]
  if not f then return end
  local remain = f.until_t - reaper.time_precise()
  if remain <= 0 then flashes[key] = nil; return end
  local a = math.floor(math.min(1.0, remain / 0.6) * 255 + 0.5)  -- fade out last 0.6s
  reaper.ImGui_SameLine(ctx, 0, spacing or M.SPACING.md)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), (f.color & ~0xFF) | a)
  reaper.ImGui_Text(ctx, f.text)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

return M
