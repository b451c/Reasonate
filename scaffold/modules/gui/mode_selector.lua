-- modules/gui/mode_selector.lua
--
-- NS-A: Mode picker view (premium "editorial cards" variant — user pick 2026-05-11).
-- Rendered w main window content area gdy state.current_mode == nil.
--
-- W3 UI/UX (2026-06-10, user-approved "głębia rysowana kodem"): karty w 100%
-- proceduralne DrawList-em — zastępują 4 PNG (~4,5 MB; images/ przestaje być
-- potrzebne do dystrybucji). Kompozycja per karta: drop shadow + ciemna baza
-- + gradient akcentu od góry + miękkie orby świetlne (clipped do karty) +
-- hairline border (akcent na hover) + accent strip.
--
-- Visual design:
--   - 4 cards horizontally centered (TTS / Voice Replacement / Dubbing / Repair)
--   - Title at top, description + 'Start →' w dolnej części
--   - Hover state: jaśniejszy wash + akcentowa ramka + glow pod strip
--
-- Returns: picked_mode (string) gdy user kliknął valid card, inaczej nil.

local theme = require 'modules.theme'

local M = {}

local CARD_W       = 240
local CARD_H       = 320          -- 3:4 aspect match PNG natural ratio
local CARD_GAP     = 24
local CARD_PAD_X   = 20
local CARD_PAD_Y   = 16
local ACCENT_H     = 4
local ROUNDING     = 8
local SHADOW_OFS   = 3
local TITLE_LINE_H = 32           -- heading 17pt approx

-- Text overlay (description + Start) starts at this fraction of card height
-- — górna część karty należy do proceduralnej "grafiki" (orby + gradient).
local TEXT_OVERLAY_Y_FRACTION = 0.62

local CARDS = {
  { name        = 'tts',
    label       = 'TTS',
    description = 'Generate speech from text using ElevenLabs voices.',
    accent      = theme.MODE_ACCENTS.tts,
    disabled    = false },
  { name        = 'voice_replacement',
    label       = 'Voice Replacement',
    description = 'Voice swap in existing recordings. Whole-take conversion via STS.',
    accent      = theme.MODE_ACCENTS.voice_replacement,
    disabled    = false },
  { name        = 'dubbing',
    label       = 'Dubbing',
    description = 'Translate + voice-clone\nin target language.',
    accent      = theme.MODE_ACCENTS.dubbing,
    disabled    = false },
  { name        = 'repair',
    label       = 'Repair',
    description = 'Fix words inline. Precision splice via forced alignment.',
    accent      = theme.MODE_ACCENTS.repair,
    disabled    = false },
  { name        = 'sfx',
    label       = 'SFX & Music',
    description = 'Sound effects and music beds from text — or straight from your scene.',
    accent      = theme.MODE_ACCENTS.sfx,
    disabled    = false },
}

----------------------------------------------------------------------------
-- Draw individual card visuals via DrawList.
----------------------------------------------------------------------------
local function draw_card(ctx, dl, x1, y1, card, hovered)
  local x2, y2 = x1 + CARD_W, y1 + CARD_H
  local disabled = card.disabled
  local active_hover = hovered and not disabled

  -- 1. Drop shadow
  reaper.ImGui_DrawList_AddRectFilled(dl,
    x1 + SHADOW_OFS, y1 + SHADOW_OFS,
    x2 + SHADOW_OFS, y2 + SHADOW_OFS,
    0x00000050, ROUNDING,
    reaper.ImGui_DrawFlags_RoundCornersAll())

  -- 2. Card background — proceduralna "głębia" (W3): ciemna baza + gradient
  -- akcentu od góry + miękkie orby świetlne. Orby clipped do karty (DrawList
  -- rysuje globalnie — bez clipu wychodziłyby na sąsiednią kartę).
  local bg_color
  if disabled then           bg_color = 0x17181BFF
  elseif active_hover then   bg_color = 0x222329FF
  else                       bg_color = 0x1B1C21FF
  end
  reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, bg_color, ROUNDING,
    reaper.ImGui_DrawFlags_RoundCornersAll())

  local wash = card.accent & 0xFFFFFF00
  reaper.ImGui_DrawList_PushClipRect(dl, x1, y1, x2, y2, true)
  -- Accent wash: gradient gasnący od góry do ~55% wysokości karty.
  local wash_a
  if disabled then          wash_a = 0x0E
  elseif active_hover then  wash_a = 0x34
  else                      wash_a = 0x22
  end
  reaper.ImGui_DrawList_AddRectFilledMultiColor(dl,
    x1 + 1, y1 + ACCENT_H, x2 - 1, y1 + math.floor(CARD_H * 0.55),
    wash | wash_a, wash | wash_a, wash, wash)
  -- Orby świetlne w prawej górnej części (2 warstwy, bardzo niska alpha).
  local orb_a1 = disabled and 0x06 or 0x0E
  local orb_a2 = disabled and 0x05 or 0x0C
  reaper.ImGui_DrawList_AddCircleFilled(dl, x2 - 34, y1 + 74, 92, wash | orb_a1)
  reaper.ImGui_DrawList_AddCircleFilled(dl, x2 - 56, y1 + 56, 48, wash | orb_a2)
  reaper.ImGui_DrawList_PopClipRect(dl)

  -- Hairline border: akcent na hover, neutralna kreska normalnie.
  local border_col = active_hover and (wash | 0x90) or 0x2E2E2EFF
  reaper.ImGui_DrawList_AddRect(dl, x1, y1, x2, y2, border_col, ROUNDING,
    reaper.ImGui_DrawFlags_RoundCornersAll(), 1)

  -- 3. Accent strip at top (top-rounded corners)
  reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y1 + ACCENT_H, card.accent, ROUNDING,
    reaper.ImGui_DrawFlags_RoundCornersTop())

  -- 4. Accent glow under strip (hover only)
  if active_hover then
    local glow_color = wash | 0x30
    reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1 + ACCENT_H, x2, y1 + ACCENT_H + 8,
      glow_color, 0)
  end

  -- 2026-05-14 PM8 v2 per user: title at TOP (small dim area pod accent strip),
  -- description + Start w dolnej połowie nad ciemnym obszarem PNG. Border
  -- usunięty — PNG ma już własną wewnętrzną ramkę, dwie ramki = visual noise.

  ------------------------------------------------------------------
  -- TOP child — title only, transparent bg, click pass-through
  ------------------------------------------------------------------
  local title_child_h = CARD_PAD_Y + 28
  reaper.ImGui_SetCursorScreenPos(ctx, x1, y1 + ACCENT_H + 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local top_win_flags = reaper.ImGui_WindowFlags_NoInputs()
                      | reaper.ImGui_WindowFlags_NoScrollbar()
                      | reaper.ImGui_WindowFlags_NoScrollWithMouse()
                      | reaper.ImGui_WindowFlags_NoBackground()
  local top_visible = reaper.ImGui_BeginChild(ctx,
    '##card_title_' .. card.name, CARD_W, title_child_h, 0, top_win_flags)
  reaper.ImGui_PopStyleVar(ctx, 1)

  if top_visible then
    reaper.ImGui_Dummy(ctx, 1, 12)
    reaper.ImGui_Indent(ctx, CARD_PAD_X)
    local pushed_heading = theme.push_heading(ctx, theme.SIZE.heading)
    if disabled then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x808080FF)
      reaper.ImGui_Text(ctx, card.label)
      reaper.ImGui_PopStyleColor(ctx, 1)
    else
      reaper.ImGui_Text(ctx, card.label)
    end
    if pushed_heading then theme.pop_heading(ctx) end
    reaper.ImGui_Unindent(ctx, CARD_PAD_X)
    reaper.ImGui_EndChild(ctx)
  end

  ------------------------------------------------------------------
  -- BOTTOM child — description + Start CTA, w naturalnej ciemnej dolnej
  -- części PNG (TEXT_OVERLAY_Y_FRACTION = 52% h karty).
  ------------------------------------------------------------------
  local text_y_start = y1 + math.floor(CARD_H * TEXT_OVERLAY_Y_FRACTION)
  local child_h = y2 - text_y_start
  reaper.ImGui_SetCursorScreenPos(ctx, x1, text_y_start)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  local win_flags = reaper.ImGui_WindowFlags_NoInputs()
                  | reaper.ImGui_WindowFlags_NoScrollbar()
                  | reaper.ImGui_WindowFlags_NoScrollWithMouse()
                  | reaper.ImGui_WindowFlags_NoBackground()
  local child_visible = reaper.ImGui_BeginChild(ctx,
    '##card_body_' .. card.name, CARD_W, child_h, 0, win_flags)
  reaper.ImGui_PopStyleVar(ctx, 1)

  if child_visible then
    reaper.ImGui_Dummy(ctx, 1, CARD_PAD_Y)
    reaper.ImGui_Indent(ctx, CARD_PAD_X)

    reaper.ImGui_PushTextWrapPos(ctx, CARD_W - CARD_PAD_X)
    local desc_color = disabled and 0x808080FF or 0xCFCFCFFF
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), desc_color)
    reaper.ImGui_TextWrapped(ctx, card.description)
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_PopTextWrapPos(ctx)

    reaper.ImGui_Unindent(ctx, CARD_PAD_X)

    local cta_y = child_h - CARD_PAD_Y - 18
    reaper.ImGui_SetCursorPos(ctx, CARD_PAD_X, cta_y)
    if disabled then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x808080FF)
      reaper.ImGui_Text(ctx, 'Locked')
      reaper.ImGui_PopStyleColor(ctx, 1)
    else
      local cta_color = active_hover and card.accent or 0xCFCFCFFF
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), cta_color)
      reaper.ImGui_Text(ctx, 'Start  →')
      reaper.ImGui_PopStyleColor(ctx, 1)
    end

    reaper.ImGui_EndChild(ctx)
  end
end

----------------------------------------------------------------------------
-- Public render fn
----------------------------------------------------------------------------
local FOOTER_RESERVE_H = 64
local HEADER_TO_CARDS_GAP = 28

function M.render(ctx)
  local picked = nil

  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  avail_w = avail_w or 800
  avail_h = avail_h or 500

  local mode_start_x, mode_start_y = reaper.ImGui_GetCursorScreenPos(ctx)

  -- NS-SFX (2026-06-10): 5 kart nie mieści się w jednym wierszu przy default
  -- 980px — karty zawijają się do wierszy (centrowane per wiersz).
  local per_row = math.min(#CARDS,
    math.max(1, math.floor((avail_w + CARD_GAP) / (CARD_W + CARD_GAP))))
  local n_rows  = math.ceil(#CARDS / per_row)

  local total_cards_w = (CARD_W * per_row) + (CARD_GAP * (per_row - 1))
  local cards_start_x = mode_start_x + math.max(0, math.floor((avail_w - total_cards_w) / 2))
  local cards_center_x = cards_start_x + total_cards_w / 2

  local cards_block_h = n_rows * CARD_H + (n_rows - 1) * CARD_GAP
  local total_block_h = TITLE_LINE_H + HEADER_TO_CARDS_GAP + cards_block_h
  local effective_h = math.max(total_block_h + 40, avail_h - FOOTER_RESERVE_H)
  local block_top_y = mode_start_y + math.max(20, math.floor((effective_h - total_block_h) / 2))

  -- ====== Header ======

  local header_text = 'Choose your mode'

  local pushed_h = theme.push_heading(ctx, theme.SIZE.heading)
  reaper.ImGui_SetCursorScreenPos(ctx, -10000, block_top_y)
  reaper.ImGui_Text(ctx, header_text)
  local ok_rect, header_w_measured = pcall(reaper.ImGui_GetItemRectSize, ctx)
  local header_w = (ok_rect and header_w_measured) or math.floor(#header_text * 9.5)
  if pushed_h then theme.pop_heading(ctx) end

  local header_x = math.max(mode_start_x, math.floor(cards_center_x - header_w / 2))
  reaper.ImGui_SetCursorScreenPos(ctx, header_x, block_top_y)
  pushed_h = theme.push_heading(ctx, theme.SIZE.heading)
  reaper.ImGui_Text(ctx, header_text)
  if pushed_h then theme.pop_heading(ctx) end

  -- ====== Cards ======

  local cards_start_y = block_top_y + TITLE_LINE_H + HEADER_TO_CARDS_GAP

  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  for i, card in ipairs(CARDS) do
    local row    = math.floor((i - 1) / per_row)
    local col    = (i - 1) % per_row
    local in_row = math.min(per_row, #CARDS - row * per_row)
    local row_w  = in_row * CARD_W + (in_row - 1) * CARD_GAP
    local row_x  = mode_start_x + math.max(0, math.floor((avail_w - row_w) / 2))
    local x1 = row_x + col * (CARD_W + CARD_GAP)
    local y1 = cards_start_y + row * (CARD_H + CARD_GAP)

    reaper.ImGui_SetCursorScreenPos(ctx, x1, y1)
    if reaper.ImGui_InvisibleButton(ctx, '##mode_card_' .. card.name, CARD_W, CARD_H) then
      if not card.disabled then
        picked = card.name
      end
    end
    local hovered = reaper.ImGui_IsItemHovered(ctx)

    draw_card(ctx, dl, x1, y1, card, hovered)
  end

  reaper.ImGui_SetCursorScreenPos(ctx, mode_start_x, cards_start_y + cards_block_h + 16)

  return picked
end

return M
