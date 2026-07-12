-- modules/gui/tts_dialogue_panel.lua
-- NS-2c multi-speaker dialogue sub-mode — UI panel.
--
-- Wydzielone z modes/tts.lua (audit M3-1, 2026-06-10; plik miał 4257 LOC)
-- — czysto mechaniczne przeniesienie render functions, zero zmian
-- zachowania. Logika (spawn/cancel/cast/validate itd.) zostaje w
-- modes/tts.lua i wchodzi tu przez tabelę A (M.init(actions) wołane raz
-- przy starcie tts.lua). Konwencja mirror: gui/repair_panel + modes/repair.

local theme        = require 'modules.theme'
local cfg          = require 'modules.config'
local util         = require 'modules.util'
local helpers      = require 'modules.reaper_helpers'
local voice_picker = require 'modules.gui.voice_picker'
local voice_admin  = require 'modules.voice_admin'
local audio_tags   = require 'modules.audio_tags'
local preview      = require 'modules.preview'
local json         = require 'modules.lib.json'
local llm          = require 'modules.llm'    -- Enhance: provider check dla disabled state
local colors       = require 'modules.colors' -- speaker accent colors (TRACK_PRESETS)

local M = {}

local A = nil   -- akcje + stałe z modes/tts.lua (patrz tamtejsza tabela A)
function M.init(actions) A = actions end

-- Panel-local: wrapped view buforów linii podczas aktywnej edycji
-- (keyed by line id; cleared na blur/delete — patrz render_dialogue_lines).
-- ln.text w stanie pozostaje ZAWSZE czysty single-line.
local wrap_buf = {}

-- Enhance (modes/tts apply/revert): zewnętrzna zmiana ln.text musi zrzucić
-- panel-local wrapped widok — inaczej do blur widoczny byłby stary tekst.
function M.reset_line_wrap(line_id) wrap_buf[line_id] = nil end

----------------------------------------------------------------------------
-- Kolor akcentu mówcy (W3 2026-06-11, user request: "rozróżnić kolorami
-- dialogi osób"). Po INDEKSIE mówcy na liście (stabilny — brak reorderu
-- mówców; po usunięciu mówcy kolory następnych się przesuwają, acceptable).
-- Kolejność hue dobrana ręcznie: sąsiedni mówcy = wyraźnie różne barwy
-- (TRACK_PRESETS leci tęczą — sąsiednie indeksy są zbyt podobne).
----------------------------------------------------------------------------
local SPEAKER_PRESET_ORDER = { 7, 2, 5, 11, 3, 9, 6, 12, 4, 1 }  -- cyan orange green magenta yellow indigo teal pink lime red

local function speaker_color(s, speaker_id)
  for i, sp in ipairs(s.dialogue_speakers or {}) do
    if sp.id == speaker_id then
      local pi = SPEAKER_PRESET_ORDER[((i - 1) % #SPEAKER_PRESET_ORDER) + 1]
      local p  = colors.TRACK_PRESETS[pi]
      return (p[1] << 24) | (p[2] << 16) | (p[3] << 8) | 0xFF
    end
  end
  return theme.COLORS.text_dim
end

----------------------------------------------------------------------------
-- NS-2c: helper — kolor coding dla cost preview (green / amber / red).
----------------------------------------------------------------------------
local function dialogue_cost_color(total)
  if total > A.DIALOGUE_MAX_CHARS then return theme.COLORS.status_error end
  if total > A.DIALOGUE_LIMIT_AMBER then return theme.COLORS.status_stale end
  if total > A.DIALOGUE_LIMIT_SOFT then return theme.COLORS.text_dim end
  return theme.COLORS.status_done
end

----------------------------------------------------------------------------
-- NS-2c: speakers section render. Chips per speaker (label + voice button +
-- delete) + "Add speaker" button. Voice picker callback ustawia voice_id +
-- voice_name na klikniętym speakerze.
----------------------------------------------------------------------------
local function render_dialogue_speakers(ctx, state, s)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Speakers in dialogue:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
  reaper.ImGui_Text(ctx, ('%d/%d · max %d voices per dialogue')
    :format(#(s.dialogue_speakers or {}), A.DIALOGUE_MAX_SPEAKERS, A.DIALOGUE_MAX_SPEAKERS))
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- Each speaker = chip-like group: label + voice button + ⋯ + ×.
  -- Zawijanie do nowego wiersza gdy chip nie mieści się w kolumnie content
  -- (W3 fix 2026-06-11: chipy uciekały za paletę tagów przy 3+ mówcach).
  -- CalcTextSize brak w Lua API → estymata ~7px/znak (KNOWN-ISSUES pattern);
  -- bajty UTF-8 zawyżają szerokość dla diakrytyków = wcześniejszy wrap (safe).
  local speakers = s.dialogue_speakers or {}
  local function speaker_chip_est_width(sp)
    local voice_label = (sp.voice_id ~= '')
      and (sp.voice_name ~= '' and sp.voice_name or sp.voice_id)
      or '(pick voice)'
    return (#sp.label * 7 + 16)       -- label button
         + (#voice_label * 7 + 16)    -- voice button
         + 26 + 24                    -- ⋯ + ×
         + 3 * theme.SPACING.xs
  end
  for sp_i, sp in ipairs(speakers) do
    local id_suffix = sp.id
    if sp_i > 1 then
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
      local rem_w = reaper.ImGui_GetContentRegionAvail(ctx)
      if rem_w < speaker_chip_est_width(sp) then
        reaper.ImGui_NewLine(ctx)
      end
    end

    -- Label button — left-click opens rename popup; renders as plain text style.
    -- Etykieta w kolorze akcentu mówcy (spójny z paskiem przy liniach).
    local label_display = ('%s##sp_lbl_%s'):format(sp.label, id_suffix)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), speaker_color(s, sp.id))
    if reaper.ImGui_SmallButton(ctx, label_display) then
      s._rename_speaker_id = sp.id
      s._rename_speaker_buf = sp.label
      reaper.ImGui_OpenPopup(ctx, 'speaker_rename')
    end
    reaper.ImGui_PopStyleColor(ctx, 1)
    if reaper.ImGui_IsItemHovered(ctx) then
      -- W2 M3.3: opis postaci (Cast Registry / glossary dubbingu) nad hintem.
      local tip = 'Left-click: rename label.   Menu: … button or right-click.'
      if sp.description and sp.description ~= '' then
        tip = sp.description .. '\n\n' .. tip
      end
      reaper.ImGui_SetTooltip(ctx, tip)
    end
    -- NS-2e Phase A + W3 Pakiet B: speaker menu — otwierany right-clickiem na
    -- etykiecie LUB widocznym przyciskiem ⋯ (ten sam popup id). Defer open
    -- (set flag) — OpenPopup nested w BeginPopupContextItem callback jest
    -- fragile; trigger w bezpiecznym scope po loop iteration.
    if reaper.ImGui_BeginPopupContextItem(ctx, 'sp_ctx_' .. id_suffix) then
      if reaper.ImGui_MenuItem(ctx, 'Rename…') then
        s._open_speaker_rename_pending = sp.id
      end
      if reaper.ImGui_MenuItem(ctx, 'Voice settings…') then
        s._open_speaker_settings_pending = sp.id
      end
      reaper.ImGui_EndPopup(ctx)
    end

    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)

    -- Voice button — opens voice picker callback w/ allow_clear toggle.
    local voice_label = (sp.voice_id ~= '') and (sp.voice_name ~= '' and sp.voice_name or sp.voice_id)
                                          or '(pick voice)'
    local voice_btn_label = ('%s##sp_voice_%s'):format(voice_label, id_suffix)
    if reaper.ImGui_SmallButton(ctx, voice_btn_label) then
      voice_picker.open({
        state            = state,
        track_guid       = nil,
        current_voice_id = sp.voice_id ~= '' and sp.voice_id or nil,
        on_pick = function(voice_id, voice_name)
          if voice_id and voice_id ~= '' then
            sp.voice_id   = voice_id
            sp.voice_name = voice_name or ''
            A.mark_dirty(s)
          end
        end,
        allow_clear = true,
      })
    end

    -- W3 Pakiet B: widoczny ⋯ — voice settings mówcy były TYLKO pod
    -- right-clickiem (zero śladu w UI). Otwiera ten sam popup co right-click.
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    -- '…' (U+2026) zamiast '⋯' (U+22EF) — Inter NIE ma U+22EF, renderował
    -- się jako '?' (live 2026-06-11; weryfikacja ⋯ z 2026-05-08 była na
    -- foncie systemowym, sprzed vendoringu Inter).
    if reaper.ImGui_SmallButton(ctx, ('…##sp_menu_%s'):format(id_suffix)) then
      reaper.ImGui_OpenPopup(ctx, 'sp_ctx_' .. id_suffix)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, 'Speaker menu: rename · voice settings')
    end

    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    if reaper.ImGui_SmallButton(ctx, ('×##sp_del_%s'):format(id_suffix)) then
      A.remove_dialogue_speaker(s, sp.id)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Remove speaker. Lines using this speaker stay (orphaned → reassign).')
    end
  end

  -- "+ Add speaker" button. Disabled when at API limit. Ten sam wrap check
  -- co chipy — przy pełnym wierszu spada do nowego.
  if #speakers > 0 then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    local rem_w = reaper.ImGui_GetContentRegionAvail(ctx)
    if rem_w < (13 * 7 + 16) then
      reaper.ImGui_NewLine(ctx)
    end
  end
  local at_limit = #speakers >= A.DIALOGUE_MAX_SPEAKERS
  reaper.ImGui_BeginDisabled(ctx, at_limit)
  if reaper.ImGui_SmallButton(ctx, '+ Add speaker') then
    A.add_dialogue_speaker(s)
  end
  reaper.ImGui_EndDisabled(ctx)
  if at_limit and reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      ('Reached API limit of %d unique voices per dialogue.'):format(A.DIALOGUE_MAX_SPEAKERS))
  end

  -- M3: Cast preset row — Apply preset dropdown + Save as… modal + per-preset delete.
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Saved cast:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_SetNextItemWidth(ctx, 220)

  local cast_names = cfg.list_tts_dialogue_cast_names()
  local cast_combo_label = (#cast_names == 0) and '(no saved casts)' or '(pick to apply)'

  if reaper.ImGui_BeginCombo(ctx, '##diag_cast_preset', cast_combo_label) then
    if #cast_names == 0 then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
      reaper.ImGui_Text(ctx, '  No saved casts — use "Save cast as…" to create one.')
      reaper.ImGui_PopStyleColor(ctx, 1)
    end
    for _, name in ipairs(cast_names) do
      if reaper.ImGui_Selectable(ctx, name .. '##cast_' .. name, false) then
        A.apply_dialogue_cast(s, cfg.get_tts_dialogue_cast(name))
      end
      if reaper.ImGui_BeginPopupContextItem(ctx, 'cast_ctx_' .. name) then
        if reaper.ImGui_MenuItem(ctx, 'Delete cast') then
          cfg.delete_tts_dialogue_cast(name)
          theme.flash('diag_cast', ('Deleted cast "%s".'):format(name), theme.COLORS.text_dim)
        end
        reaper.ImGui_EndPopup(ctx)
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, 'Left-click applies. Right-click for delete.')
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  local has_any_speaker = #(s.dialogue_speakers or {}) > 0
  reaper.ImGui_BeginDisabled(ctx, not has_any_speaker)
  if theme.button_neutral(ctx, 'Save cast as…##diag_cast_save', 130, 0) then
    s.cast_preset_save_name = ('Cast %d'):format(#cast_names + 1)
    reaper.ImGui_OpenPopup(ctx, 'diag_cast_save')
  end
  reaper.ImGui_EndDisabled(ctx)
  if (not has_any_speaker) and reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Add at least one speaker first.')
  end
  -- W2 M3.3 (PHASE-W2 §4): cast z Cast Registry projektu (zasilany przez
  -- Dubbing). Jawna akcja + wybór Replace/Merge w modes/tts — registry
  -- nigdy nie nadpisuje cicho.
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if theme.button_neutral(ctx, 'Cast from project##diag_cast_proj', 150, 0) then
    if A.apply_project_cast(s) then
      theme.flash('diag_cast', 'Project cast applied.')
    end
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Use the characters collected from this project (e.g. Dubbing mode):\n'
      .. 'names, voices and character descriptions. You choose replace or merge.')
  end
  theme.draw_flash_inline(ctx, 'diag_cast')

  -- Cast save modal — InputText for name + Save/Cancel.
  theme.center_next_modal(ctx)
  theme.popup_keep_top(ctx, 'diag_cast_save')
  if reaper.ImGui_BeginPopupModal(ctx, 'diag_cast_save', nil,
       reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_Text(ctx, 'Save current speakers as cast preset.')
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, 'Name:')
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    reaper.ImGui_SetNextItemWidth(ctx, 260)
    local rv_c, new_c = reaper.ImGui_InputText(ctx, '##cast_name', s.cast_preset_save_name or '')
    if rv_c then s.cast_preset_save_name = new_c end
    reaper.ImGui_Spacing(ctx)
    local can_save = s.cast_preset_save_name and s.cast_preset_save_name ~= ''
    reaper.ImGui_BeginDisabled(ctx, not can_save)
    if theme.button_primary(ctx, 'Save##diag_cast_save_ok', 110, 0) then
      cfg.save_tts_dialogue_cast(s.cast_preset_save_name, A.build_current_dialogue_cast(s))
      theme.flash('diag_cast', ('Saved cast "%s".'):format(s.cast_preset_save_name))
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndDisabled(ctx)
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    if theme.button_neutral(ctx, 'Cancel##diag_cast_save_cancel', 110, 0)
       or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- NS-2e Phase A: deferred open dla voice settings popup. Flag set w context
  -- menu MenuItem callback, here po speakers loop trigger OpenPopup w
  -- bezpiecznym scope (poza nested popup callback).
  if s._open_speaker_settings_pending then
    s._editing_speaker_voice_settings_id = s._open_speaker_settings_pending
    s._open_speaker_settings_pending = nil
    reaper.ImGui_OpenPopup(ctx, 'speaker_voice_settings')
  end

  -- W3 Pakiet B: deferred open dla rename z menu mówcy (ten sam wzorzec —
  -- OpenPopup poza nested popup callback; bufor pre-fill jak left-click).
  if s._open_speaker_rename_pending then
    local sp_r = A.find_speaker_by_id(s, s._open_speaker_rename_pending)
    s._open_speaker_rename_pending = nil
    if sp_r then
      s._rename_speaker_id  = sp_r.id
      s._rename_speaker_buf = sp_r.label
      reaper.ImGui_OpenPopup(ctx, 'speaker_rename')
    end
  end

  -- Voice settings popup — 5 sliders editing sp.voice_settings (stability /
  -- similarity_boost / style / speed / speaker_boost). Used dla SOLO preview
  -- i per-region regen (Phase B). Dialogue endpoint Generate używa global
  -- dialogue_v3_stability (API limitation: per-input voice_settings not
  -- supported w /v1/text-to-dialogue).
  theme.center_next_modal(ctx)
  theme.popup_keep_top(ctx, 'speaker_voice_settings')
  if reaper.ImGui_BeginPopupModal(ctx, 'speaker_voice_settings', nil,
                                   reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    local sp_edit = A.find_speaker_by_id(s, s._editing_speaker_voice_settings_id)
    if not sp_edit then
      reaper.ImGui_CloseCurrentPopup(ctx)
    else
      sp_edit.voice_settings = A.normalize_speaker_voice_settings(sp_edit.voice_settings)
      local vs = sp_edit.voice_settings

      reaper.ImGui_Text(ctx, ('Voice settings — %s: %s'):format(
        sp_edit.label or '?',
        (sp_edit.voice_name ~= '' and sp_edit.voice_name) or sp_edit.voice_id or '(no voice)'))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
      reaper.ImGui_TextWrapped(ctx,
        'Applies to ▶ SOLO preview and per-region regen (single-voice TTS endpoint).\n' ..
        'Dialogue Generate uses the global Stability radio — ElevenLabs dialogue API\n' ..
        'accepts only ONE global stability per request (no per-voice voice_settings).\n\n' ..
        'v3 honors: stability, similarity_boost, style, speed.\n' ..
        'v3 ignores: use_speaker_boost (v2/v2.5 only).')
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_Spacing(ctx); reaper.ImGui_Separator(ctx); reaper.ImGui_Spacing(ctx)

      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, 'Stability:')
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
      reaper.ImGui_SetNextItemWidth(ctx, 280)
      local rv_a, val_a = reaper.ImGui_SliderDouble(ctx, '##sp_vs_stab', vs.stability, 0.0, 1.0, '%.2f')
      if rv_a then vs.stability = val_a; A.mark_dirty(s) end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          'Low = more variation/expression; high = stability + consistency.\n' ..
          'For v3 dialogue endpoint the GLOBAL value (radio above) is used;\n' ..
          'this per-speaker value applies only to SOLO + per-region regen.')
      end

      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, 'Similarity:')
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
      reaper.ImGui_SetNextItemWidth(ctx, 280)
      local rv_b, val_b = reaper.ImGui_SliderDouble(ctx, '##sp_vs_sim', vs.similarity_boost, 0.0, 1.0, '%.2f')
      if rv_b then vs.similarity_boost = val_b; A.mark_dirty(s) end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          'Adherence to the original voice. Honored by v3 in SOLO + per-region regen\n' ..
          '(single-voice TTS endpoint). Dialogue Generate uses voice defaults — API\n' ..
          'supports only global stability per dialogue request.')
      end

      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, 'Style:')
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
      reaper.ImGui_SetNextItemWidth(ctx, 280)
      local rv_c, val_c = reaper.ImGui_SliderDouble(ctx, '##sp_vs_style', vs.style, 0.0, 1.0, '%.2f')
      if rv_c then vs.style = val_c; A.mark_dirty(s) end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          'Speaker style amplification. Honored by v3 in SOLO + regen.\n' ..
          'Default 0 — v3 prefers prompt-driven emotion via audio tags ([excited], [whispers]…)\n' ..
          'over style slider. Raise carefully (extra latency, hallucination risk).')
      end

      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, 'Speed:')
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
      reaper.ImGui_SetNextItemWidth(ctx, 280)
      local rv_d, val_d = reaper.ImGui_SliderDouble(ctx, '##sp_vs_speed', vs.speed, 0.7, 1.2, '%.2f×')
      if rv_d then vs.speed = val_d; A.mark_dirty(s) end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          'Speech tempo. Honored by v3 in SOLO + regen. Range 0.7-1.2.\n' ..
          '1.0 = natural pace from the voice model.')
      end

      -- NS-2e: Speaker boost is v2/v2.5 only — v3 does NOT honor.
      -- Disable visually w dialogue mode (always v3) — checkbox stays w UI dla
      -- transparency + persistence (gdyby user kiedyś wrócił do non-v3 single
      -- mode), ale grayed out z explicit tooltip.
      reaper.ImGui_BeginDisabled(ctx, true)
      local rv_e, val_e = reaper.ImGui_Checkbox(ctx, 'Speaker boost  (v2/v2.5 only — v3 ignores)', vs.speaker_boost)
      if rv_e then vs.speaker_boost = val_e; A.mark_dirty(s) end
      reaper.ImGui_EndDisabled(ctx)
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          'use_speaker_boost is v2/v2.5 only — v3 ignores this field entirely.\n' ..
          'Stored value persists w stanie (would apply if you ever use non-v3 single mode).')
      end

      reaper.ImGui_Spacing(ctx); reaper.ImGui_Separator(ctx); reaper.ImGui_Spacing(ctx)

      if theme.button_neutral(ctx, 'Reset to defaults##sp_vs_reset', 160, 0) then
        sp_edit.voice_settings = A.default_speaker_voice_settings()
        A.mark_dirty(s)
      end
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
      if theme.button_primary(ctx, 'Close##sp_vs_close', 100, 0)
         or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
        s._editing_speaker_voice_settings_id = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- Rename popup (modal-like; single instance across all speakers).
  if reaper.ImGui_BeginPopup(ctx, 'speaker_rename') then
    reaper.ImGui_Text(ctx, 'Rename speaker label')
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local rv, new_buf = reaper.ImGui_InputText(ctx, '##speaker_label_buf',
      s._rename_speaker_buf or '')
    if rv then s._rename_speaker_buf = new_buf end
    reaper.ImGui_Spacing(ctx)
    if theme.button_primary(ctx, 'OK##speaker_rename_ok', 80, 0)
       or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false) then
      local new_label = (s._rename_speaker_buf or ''):gsub('^%s+', ''):gsub('%s+$', '')
      if new_label ~= '' then
        local sp = A.find_speaker_by_id(s, s._rename_speaker_id)
        if sp then sp.label = new_label; A.mark_dirty(s) end
      end
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    if theme.button_neutral(ctx, 'Cancel##speaker_rename_cancel', 80, 0)
       or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

----------------------------------------------------------------------------
-- W3 (user request): rich view linii — tagi [tag] wyróżnione kolorem.
-- ImGui InputText renderuje cały bufor JEDNYM stylem (won't-fix), więc linia
-- NIE będąca w edycji renderuje się naszym widokiem: segmenty jako itemy
-- Text + SameLine(0,0) — itemy mierzą szerokość SAME (CalcTextSize brak
-- w Lua per KNOWN-ISSUES, więc DrawList_AddText z ręcznym pozycjonowaniem
-- odpada na proporcjonalnym foncie). Klik = przejście do pola tekstowego
-- z caretem na KOŃCU (EEL set_cursor — programowy focus domyślnie zaznacza
-- cały tekst → ryzyko nadpisania przy pisaniu).
----------------------------------------------------------------------------
local function render_line_rich_view(ctx, s, ln, shown, box_h)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 8, 6)
  local vis = reaper.ImGui_BeginChild(ctx, '##ln_view_' .. ln.id, -1, box_h)
  reaper.ImGui_PopStyleVar(ctx, 1)
  if not vis then return end

  -- Ramka jak u InputText (bg + border + rounding) — rysowana drawlistą
  -- CHILDA przed tekstem, więc tekst ląduje nad prostokątem.
  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local ww, wh = reaper.ImGui_GetWindowSize(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + ww, wy + wh,
    theme.COLORS.frame_bg, 6.0)
  reaper.ImGui_DrawList_AddRect(dl, wx, wy, wx + ww, wy + wh,
    theme.COLORS.border_strong, 6.0)

  -- Klik w CAŁY obszar (z paddingiem) = wejście w edycję
  reaper.ImGui_SetCursorScreenPos(ctx, wx, wy)
  if reaper.ImGui_InvisibleButton(ctx, '##ln_hit_' .. ln.id,
       math.max(1, ww), math.max(1, wh)) then
    s.dialogue_edit_line_id    = ln.id
    s.dialogue_focused_line_id = ln.id
    local cb = A.get_input_callback and A.get_input_callback(ctx) or nil
    if cb then
      pcall(reaper.ImGui_Function_SetValue, cb, 'target_cursor', #(ln.text or ''))
      pcall(reaper.ImGui_Function_SetValue, cb, 'set_cursor', 1)
      s.dialogue_pending_focus_line_id = ln.id
    end
  end
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_MouseCursor_TextInput then
    reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_TextInput())
  end

  local ox, oy = wx + 8, wy + 6
  if shown == '' then
    reaper.ImGui_SetCursorScreenPos(ctx, ox, oy)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
    reaper.ImGui_Text(ctx, '(empty line — click to edit)')
    reaper.ImGui_PopStyleColor(ctx, 1)
  else
    local line_h = reaper.ImGui_GetTextLineHeight(ctx)
    local li = 0
    for line in (shown .. '\n'):gmatch('([^\n]*)\n') do
      if line ~= '' then
        reaper.ImGui_SetCursorScreenPos(ctx, ox, oy + li * line_h)
        local pos, first = 1, true
        while pos <= #line do
          local s1, e1 = line:find('%[[^%]]-%]', pos)
          local plain_to = s1 and (s1 - 1) or #line
          if plain_to >= pos then
            if not first then reaper.ImGui_SameLine(ctx, 0, 0) end
            reaper.ImGui_Text(ctx, line:sub(pos, plain_to))
            first = false
          end
          if not s1 then break end
          if not first then reaper.ImGui_SameLine(ctx, 0, 0) end
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.override)
          reaper.ImGui_Text(ctx, line:sub(s1, e1))
          reaper.ImGui_PopStyleColor(ctx, 1)
          first = false
          pos = e1 + 1
        end
      end
      li = li + 1
    end
  end
  reaper.ImGui_EndChild(ctx)
end

----------------------------------------------------------------------------
-- NS-2c: lines section render. Per linia: speaker dropdown + text input +
-- reorder + delete. M1 has no ▶ SOLO (M2 polish). Char count per line dim.
----------------------------------------------------------------------------
local function render_dialogue_lines(ctx, s)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Lines:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
  reaper.ImGui_Text(ctx, ('%d %s'):format(
    #(s.dialogue_lines or {}),
    #(s.dialogue_lines or {}) == 1 and 'line' or 'lines'))
  reaper.ImGui_PopStyleColor(ctx, 1)

  local speakers = s.dialogue_speakers or {}
  local lines    = s.dialogue_lines or {}
  local pending_delete = nil
  local pending_move   = nil

  -- Ostatni wygenerowany take (1× per frame): linia niezmieniona od Generate
  -- gra z NIEGO swoją sekwencję (forced-alignment w modes/tts; zero kosztu
  -- TTS) zamiast bilować nowe solo (user 2026-06-11).
  local take_sync  = A.dialogue_take_sync(s)
  -- Klocki per kwestia (po pierwszym line-patchu): line_id → item info.
  local line_items = A.scan_dialogue_line_items(s)
  local gen_busy   = s.dialogue_gen_handle ~= nil
  local function find_take_input_index(inputs, text, voice_id, prefer_idx)
    if text == '' then return nil end
    -- M7: duplikaty linii (ten sam tekst+głos) grały ZAWSZE pierwsze
    -- wystąpienie — najpierw dopasowanie POZYCYJNE (inputs budowane z linii
    -- w kolejności, mirror map_take_inputs_to_lines), potem pierwszy match.
    if prefer_idx then
      local inp = inputs and inputs[prefer_idx]
      if inp and inp.text == text and inp.voice_id == voice_id then
        return prefer_idx
      end
    end
    for i, inp in ipairs(inputs or {}) do
      if inp.text == text and inp.voice_id == voice_id then return i end
    end
    return nil
  end

  -- Layout linii (W3 2026-06-11, user redesign): podpis mówcy NAD tekstem
  -- (dropdown z dopasowaną szerokością — pełne nazwy zamiast uciętych "Kol"),
  -- akcje ▶ ↑ ↓ × wyrównane do prawej w wierszu podpisu, pole tekstu na całą
  -- szerokość pod spodem, pionowy pasek w kolorze mówcy wzdłuż bloku linii.
  local LINE_INDENT = 12
  for idx, ln in ipairs(lines) do
    local id_suffix = ln.id
    local sp_assigned = A.find_speaker_by_id(s, ln.speaker_id)
    local sp_col      = speaker_color(s, ln.speaker_id)

    -- Pasek akcentu rysowany NA KOŃCU bloku (wysokość znana po renderze) —
    -- zapamiętaj start; DrawList może rysować "wstecz" bez kolizji z widgetami.
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local bar_x, bar_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local row_x = reaper.ImGui_GetCursorPosX(ctx)
    local row_w = reaper.ImGui_GetContentRegionAvail(ctx)

    -- Wiersz 1: speaker dropdown (kolor + szerokość pod nazwę) + akcje po prawej
    reaper.ImGui_SetCursorPosX(ctx, row_x + LINE_INDENT)
    local dd_label = (sp_assigned and sp_assigned.label) or '(?)'
    -- 8.5px/znak + strzałka/padding 44px — 7px/znak ucinało nazwy w Inter
    -- (bajty UTF-8 polskich znaków zawyżają = zapas, bezpieczne).
    local dd_w = math.min(240, math.max(80, math.floor(#dd_label * 8.5) + 44))
    reaper.ImGui_SetNextItemWidth(ctx, dd_w)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), sp_col)
    local combo_open = reaper.ImGui_BeginCombo(ctx, ('##ln_sp_%s'):format(id_suffix), dd_label)
    reaper.ImGui_PopStyleColor(ctx, 1)  -- pop przed items — opcje w kolorach per mówca niżej
    if combo_open then
      if #speakers == 0 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
        reaper.ImGui_Text(ctx, '  (add speakers above first)')
        reaper.ImGui_PopStyleColor(ctx, 1)
      end
      for _, sp in ipairs(speakers) do
        local is_sel = (ln.speaker_id == sp.id)
        local lbl = ('%s — %s##ln_sp_opt_%s_%s')
          :format(sp.label,
                  sp.voice_name ~= '' and sp.voice_name or '(no voice)',
                  id_suffix, sp.id)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), speaker_color(s, sp.id))
        if reaper.ImGui_Selectable(ctx, lbl, is_sel) then
          ln.speaker_id = sp.id
          A.mark_dirty(s)
        end
        reaper.ImGui_PopStyleColor(ctx, 1)
      end
      reaper.ImGui_EndCombo(ctx)
    end

    -- Akcje (▶ ↑ ↓ ×) zaraz za podpisem mówcy (user: "obok play nawigacja x";
    -- right-align po estymacie szerokości ucinało × — patrz 2026-06-11).
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    local solo_id   = 'tts_dialogue_solo_' .. ln.id
    local solo_busy = s.dialogue_solo_handles and s.dialogue_solo_handles[ln.id] ~= nil
    -- Trzy źródła odsłuchu linii (priorytet): własny klocek (po patchu) →
    -- sekwencja we wspólnym take (forced-alignment) → solo preview (bilowane).
    local li         = line_items[ln.id]
    local patch_busy = (s.dialogue_split_regen_handles ~= nil)
      and ((li and s.dialogue_split_regen_handles[li.guid] ~= nil)
        or s.dialogue_split_regen_handles['new_' .. ln.id] ~= nil)
    local line_dirty
    if li then
      line_dirty = ((ln.text or '') ~= li.split_text)
        or ((sp_assigned and sp_assigned.voice_id or '') ~= li.split_voice_id)
    end
    -- BUG (user 2026-07-11): voice_id bywa NIL, a `nil ~= ''` = true —
    -- przycisk wyglądał na aktywny, a odsłuch po cichu nie robił nic.
    local has_voice = sp_assigned and (sp_assigned.voice_id or '') ~= ''
    local take_input_idx = (not li) and take_sync and take_sync.audio_path
      and has_voice
      and find_take_input_index(take_sync.inputs, ln.text or '', sp_assigned.voice_id, idx)
      or nil
    local in_take = take_input_idx ~= nil
    if not li then
      line_dirty = take_sync and take_sync.audio_path and not in_take
        and (ln.text or '') ~= ''
        and has_voice
    end
    local align_busy = s.take_align_handle ~= nil
      and s.take_align_pending and s.take_align_pending.line_id == ln.id
    local play_mode, play_id
    if li and li.audio_path and not line_dirty then
      play_mode, play_id = 'item', 'tts_line_' .. ln.id
    elseif in_take then
      play_mode, play_id = 'take', 'tts_dialogue_take'
    else
      play_mode, play_id = 'solo', solo_id
    end
    -- Shared play_id ('tts_dialogue_take') gra dla JEDNEJ linii — gate na
    -- take_play_line_id, inaczej wszystkie in-take linie pokazywałyby ■.
    local playing = preview.is_playing(play_id)
      and (play_mode ~= 'take' or s.take_play_line_id == ln.id)
    local can_play = ((ln.text or '') ~= '')
                  and has_voice
                  and not solo_busy and not patch_busy
    local solo_glyph
    if solo_busy or align_busy or patch_busy then solo_glyph = voice_admin.spinner_glyph()
    elseif playing                            then solo_glyph = '■'
    else                                           solo_glyph = '▶' end
    reaper.ImGui_BeginDisabled(ctx, not (can_play or playing))
    if reaper.ImGui_SmallButton(ctx, ('%s##ln_solo_%s'):format(solo_glyph, id_suffix)) then
      if playing then
        preview.stop()
      elseif play_mode == 'item' then
        preview.play_file_range(li.audio_path, li.startoffs,
          li.startoffs + li.length, play_id, { volume = 0.8 })
      elseif play_mode == 'take' then
        A.request_take_line_play(s, take_sync, take_input_idx, ln.id)
      else
        A.spawn_solo_preview(s, ln, sp_assigned)
      end
    end
    reaper.ImGui_EndDisabled(ctx)
    if reaper.ImGui_IsItemHovered(ctx) then
      if solo_busy then
        reaper.ImGui_SetTooltip(ctx, 'Generating SOLO preview…')
      elseif patch_busy then
        reaper.ImGui_SetTooltip(ctx, 'Re-rendering this line…')
      elseif align_busy then
        reaper.ImGui_SetTooltip(ctx, 'Mapping line timings in the take…')
      elseif playing then
        reaper.ImGui_SetTooltip(ctx, 'Stop playback')
      elseif play_mode == 'item' then
        reaper.ImGui_SetTooltip(ctx,
          'Play this line (it has its own item on the timeline). No API cost.')
      elseif play_mode == 'take' then
        reaper.ImGui_SetTooltip(ctx,
          'Play this line from the generated take (no TTS cost).\n' ..
          'First click maps word timings — one cheap alignment call, cached.')
      elseif not can_play then
        reaper.ImGui_SetTooltip(ctx,
          'Set speaker voice and write line text to enable SOLO preview.')
      else
        reaper.ImGui_SetTooltip(ctx,
          'Preview just this line (single-voice TTS).\n' ..
          'Small extra API call. Cache hit on second click.')
      end
    end

    -- Right-side actions: ↑ ↓ ×
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    reaper.ImGui_BeginDisabled(ctx, idx == 1)
    if reaper.ImGui_SmallButton(ctx, ('↑##ln_up_%s'):format(id_suffix)) then
      pending_move = { id = ln.id, dir = -1 }
    end
    reaper.ImGui_EndDisabled(ctx)

    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    reaper.ImGui_BeginDisabled(ctx, idx == #lines)
    if reaper.ImGui_SmallButton(ctx, ('↓##ln_dn_%s'):format(id_suffix)) then
      pending_move = { id = ln.id, dir = 1 }
    end
    reaper.ImGui_EndDisabled(ctx)

    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    if reaper.ImGui_SmallButton(ctx, ('×##ln_del_%s'):format(id_suffix)) then
      pending_delete = ln.id
    end

    -- Dirty przy linii (user 2026-06-11): kropka + [Re-gen] OD RAZU TUTAJ —
    -- generuje TYLKO tę kwestię (z kontekstem sąsiadów) i podmienia jej
    -- fragment na osi czasu (klocki per kwestia; user decision).
    if line_dirty and not patch_busy then
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
      reaper.ImGui_Text(ctx, '● edited')
      reaper.ImGui_PopStyleColor(ctx, 1)
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, li
          and 'This line changed since its last render.'
          or  'This line changed since the last generated take.')
      end
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
      reaper.ImGui_BeginDisabled(ctx, gen_busy or align_busy == true)
      if reaper.ImGui_SmallButton(ctx, ('Re-gen##ln_patch_%s'):format(id_suffix)) then
        A.request_line_patch(s, ln.id)
      end
      reaper.ImGui_EndDisabled(ctx)
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          'Re-render ONLY this line (billed for its characters) and patch it\n' ..
          'on the timeline. The first patch splits the dialogue item into\n' ..
          'per-line items (boundaries from word timings); the patched line\n' ..
          'gets a new take on its own item — old takes stay.')
      end
    end

    -- Wiersz 2: tekst linii na PEŁNĄ szerokość (akcje wyniesione wyżej).
    --
    -- Word-wrap (2026-06-10, user-reported overflow): ImGui nie wrapuje
    -- natywnie (KNOWN-ISSUES PM11) — widget dostaje WRAPPED view
    -- (util.soft_wrap_text, \n co ~width/7px chars), a ln.text trzyma ZAWSZE
    -- czysty single-line (normalize_whitespace przy każdej edycji) — żaden
    -- konsument (generate/solo/char count/serialize/palette insert) nie widzi
    -- sztucznych newline'ów. Podczas aktywnej edycji buforem rządzi widget
    -- (wrap_buf — bez per-frame reflow, który walczyłby z kursorem); reflow
    -- następuje po blur (wrap_buf cleared → świeży wrap z ln.text).
    reaper.ImGui_SetCursorPosX(ctx, row_x + LINE_INDENT)
    local wrap_chars = math.max(20, math.floor((row_w - LINE_INDENT - 24) / 7))
    local shown = wrap_buf[ln.id] or util.soft_wrap_text(ln.text or '', wrap_chars)
    local _, n_breaks = shown:gsub('\n', '')
    local n_rows = math.min(5, math.max(2, n_breaks + 1))
    local box_h = n_rows * reaper.ImGui_GetTextLineHeight(ctx) + 14
    -- W3 (user request): widok ↔ edycja. Linia nieedytowana = rich view
    -- (tagi kolorowane); klik przełącza na pole tekstowe; blur wraca do
    -- widoku (insert z palety ustawia edycję ponownie przez pending focus).
    local editing = (s.dialogue_edit_line_id == ln.id)
      or (s.dialogue_pending_focus_line_id == ln.id)
    if editing then
      -- W3 (user-reported): EEL cursor callback na KAŻDEJ linii (mirror single
      -- mode) — paleta wstawia tag w pozycji kursora, nie na końcu linii.
      -- Pending focus wraca do linii po kliku w paletę (caret za tagiem).
      local cb = A.get_input_callback and A.get_input_callback(ctx) or nil
      if s.dialogue_pending_focus_line_id == ln.id then
        reaper.ImGui_SetKeyboardFocusHere(ctx, 0)
        s.dialogue_pending_focus_line_id = nil
      end
      local in_flags = cb and reaper.ImGui_InputTextFlags_CallbackAlways() or 0
      local rv_t, new_t = reaper.ImGui_InputTextMultiline(ctx,
        ('##ln_text_%s'):format(id_suffix),
        shown, -1, box_h, in_flags, cb)
      if rv_t then
        wrap_buf[ln.id] = new_t
        ln.text = util.normalize_whitespace(new_t)
        A.mark_dirty(s)
      end
      -- Track focused line — for palette tag insertion target. Aktywne pole
      -- podtrzymuje też tryb edycji (pending focus jest one-shot).
      if reaper.ImGui_IsItemActive(ctx) then
        s.dialogue_focused_line_id = ln.id
        s.dialogue_edit_line_id    = ln.id
      elseif wrap_buf[ln.id] then
        wrap_buf[ln.id] = nil
      end
      if reaper.ImGui_IsItemDeactivated(ctx) then
        s.dialogue_edit_line_id = nil
      end
    else
      render_line_rich_view(ctx, s, ln, shown, box_h)
    end

    -- Wiersz 3: char count (dim, pod polem tekstu).
    reaper.ImGui_SetCursorPosX(ctx, row_x + LINE_INDENT)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
    reaper.ImGui_Text(ctx, ('%d chars'):format(util.utf8_len(ln.text or '')))
    reaper.ImGui_PopStyleColor(ctx, 1)

    -- Pionowy pasek w kolorze mówcy wzdłuż całego bloku linii (gutter).
    local _, end_y = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_DrawList_AddRectFilled(dl, bar_x + 1, bar_y + 2,
      bar_x + 4, end_y - 4, sp_col, 1.5)

    -- Aktywna kwestia (playhead REAPER / ▶ w panelu) → indigo tint bloku
    -- (mirror Dubbing playhead segment z W3 s3; alpha niska — overlay).
    if s.playhead_line_id == ln.id or playing then
      reaper.ImGui_DrawList_AddRectFilled(dl, bar_x + 6, bar_y,
        bar_x + row_w - 2, end_y - 4, 0x6366F11A, 4)
    end
    -- One-shot scroll do granej kwestii (flaga z sync_playhead_line przy
    -- ZMIANIE linii podczas odtwarzania — ręczny scroll nie jest ruszany).
    if s.dialogue_scroll_line_id == ln.id then
      reaper.ImGui_SetScrollHereY(ctx, 0.35)
      s.dialogue_scroll_line_id = nil
    end

    reaper.ImGui_Spacing(ctx)
  end

  -- Apply deferred mutations after iteration (safe table modification).
  if pending_move then
    A.move_dialogue_line(s, pending_move.id, pending_move.dir)
  end
  if pending_delete then
    wrap_buf[pending_delete] = nil
    A.remove_dialogue_line(s, pending_delete)
  end

  -- "+ Add line" button. Disabled when no speakers yet.
  reaper.ImGui_BeginDisabled(ctx, #speakers == 0)
  if reaper.ImGui_SmallButton(ctx, '+ Add line') then
    A.add_dialogue_line(s, nil)  -- defaults to next speaker in rotation (or first)
  end
  reaper.ImGui_EndDisabled(ctx)
  if #speakers == 0 and reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Add at least one speaker first.')
  end

  -- Import skryptu z pliku (W3 2026-06-11). Aktywny też bez mówców —
  -- import sam tworzy mówców z imion w pliku.
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if reaper.ImGui_SmallButton(ctx, 'Import script…') then
    A.import_dialogue_script(s)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Load dialogue from a .txt / .md file. One cue per line:\n\n' ..
      '  Anna: How was the trip?\n' ..
      '  Marek: Long... too long.\n\n' ..
      'Markdown marks (#, **, -) are tolerated; a line without\n' ..
      '"Name:" continues the previous cue. New names become new\n' ..
      'speakers — assign voices after import.')
  end
end

----------------------------------------------------------------------------
-- NS-2c: full dialogue panel content (excluding palette which is rendered by
-- M.render right side for v3). Sub-mode='dialogue' renders this.
----------------------------------------------------------------------------
local function render_dialogue_content(ctx, state, deps, s, busy)
  -- ====== Speakers section ======
  render_dialogue_speakers(ctx, state, s)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- ====== Lines section ======
  render_dialogue_lines(ctx, s)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- W3 (mniej przewijania): Stability / Target track / licznik znaków /
  -- Generate / status PRZENIESIONE do M.render_actions — przyklejony pasek
  -- pod scroll-childem (modes/tts.lua), zawsze widoczny. Linie dialogu
  -- dostają całą przestrzeń scrolla.

  -- ====== NS-2e Phase B: Selected split region mini-section ======
  -- Gdy user wybierze pojedynczy split item w REAPER timeline, panel pokazuje
  -- inline regen action z stored P_EXT (text + voice + settings). Spawn TTS
  -- /v1/text-to-speech (single voice) z new seed → AddTake do split itemu.
  local sel_split_item = nil
  if reaper.CountSelectedMediaItems(0) == 1 then
    local cand = reaper.GetSelectedMediaItem(0, 0)
    if cand and helpers.pext_item_get(cand, 'is_tts_dialogue_split') == '1' then
      sel_split_item = cand
    end
  end

  if sel_split_item then
    local split_guid       = helpers.item_guid(sel_split_item)
    local split_text       = helpers.pext_item_get(sel_split_item, 'split_text')       or ''
    local split_voice_name = helpers.pext_item_get(sel_split_item, 'split_voice_name') or ''
    local split_voice_id   = helpers.pext_item_get(sel_split_item, 'split_voice_id')   or ''
    local split_label      = helpers.pext_item_get(sel_split_item, 'split_speaker_label') or '?'

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.override)
    reaper.ImGui_Text(ctx, 'Selected split region:')
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
    reaper.ImGui_TextWrapped(ctx, ('%s · %s · "%s"'):format(
      split_label,
      (split_voice_name ~= '' and split_voice_name) or split_voice_id,
      split_text))
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx)

    local split_handle = s.dialogue_split_regen_handles and s.dialogue_split_regen_handles[split_guid] or nil
    if split_handle then
      reaper.ImGui_BeginDisabled(ctx, true)
      theme.button_neutral(ctx,
        voice_admin.spinner_glyph() .. ' Regenerating…##split_regen_busy',
        260, 0)
      reaper.ImGui_EndDisabled(ctx)
    else
      local can_regen = (split_text ~= '' and split_voice_id ~= '')
      reaper.ImGui_BeginDisabled(ctx, not can_regen)
      if theme.button_primary(ctx, 'Regenerate region (new seed → take)##split_regen', 320, 0) then
        A.spawn_split_regen(s, sel_split_item)
      end
      reaper.ImGui_EndDisabled(ctx)
      if reaper.ImGui_IsItemHovered(ctx) then
        if not can_regen then
          reaper.ImGui_SetTooltip(ctx,
            'Missing text or voice_id in P_EXT — split item was not created by NS-2e\n' ..
            '(legacy split before update). Re-generate this item by running Generate dialogue again.')
        else
          reaper.ImGui_SetTooltip(ctx,
            'Single-voice TTS via /v1/text-to-speech, same text + voice, new random seed.\n' ..
            'Audio added as a new take on this split item — cycle takes in REAPER take strip.\n' ..
            'Voice settings: per-speaker snapshot saved in P_EXT at split time.')
        end
      end
    end

    reaper.ImGui_Spacing(ctx)
  end

  -- ====== M3: Per-item dialogue history list ======
  local target_tr = nil
  if s.target_track_guid and s.target_track_guid ~= '' then
    target_tr = helpers.find_track_by_guid(s.target_track_guid)
  end
  if target_tr then
    local items = A.scan_dialogue_items_on_track(target_tr)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    -- W3 (mniej przewijania): historia ZWIJANA, domyślnie zwinięta — linie
    -- dialogu są głównym obszarem pracy. Stałe ##id → ImGui pamięta stan
    -- open/closed per sesja niezależnie od licznika w etykiecie.
    if not reaper.ImGui_CollapsingHeader(ctx,
        ('Generated dialogues on track \xc2\xb7 %d %s##diag_history'):format(
          #items, #items == 1 and 'item' or 'items')) then
      goto skip_history
    end

    if #items == 0 then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
      reaper.ImGui_TextWrapped(ctx,
        'None yet — click Generate to create the first dialogue item.')
      reaper.ImGui_PopStyleColor(ctx, 1)
    else
      local TABLE_FLAGS = reaper.ImGui_TableFlags_BordersInnerH()
                        | reaper.ImGui_TableFlags_RowBg()
                        | reaper.ImGui_TableFlags_PadOuterX()
      if reaper.ImGui_BeginTable(ctx, 'diag_items', 2, TABLE_FLAGS, -1, 0) then
        reaper.ImGui_TableSetupColumn(ctx, 'text',
          reaper.ImGui_TableColumnFlags_WidthStretch(), 3)
        reaper.ImGui_TableSetupColumn(ctx, 'actions',
          reaper.ImGui_TableColumnFlags_WidthFixed(), 210)

        for _, row in ipairs(items) do
          reaper.ImGui_TableNextRow(ctx)
          reaper.ImGui_TableSetColumnIndex(ctx, 0)

          -- SpanAllColumns Selectable jako klik target
          local is_sel = reaper.IsMediaItemSelected(row.item)
          local sel_flags = reaper.ImGui_SelectableFlags_SpanAllColumns()
                          | reaper.ImGui_SelectableFlags_AllowOverlap()
          if reaper.ImGui_Selectable(ctx, '##drow_' .. row.guid, is_sel, sel_flags) then
            A.select_item_in_timeline(row.item)
          end
          -- W3 quick win: discoverability ukrytego menu (mirror tts_panel).
          if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
            reaper.ImGui_SetTooltip(ctx,
              'Click selects the item in REAPER.\nRight-click: preview · delete take · delete item · reveal file.')
          end

          -- Right-click context menu
          if reaper.ImGui_BeginPopupContextItem(ctx, 'diag_row_ctx_' .. row.guid) then
            local rc_prev_id = 'diag_row_' .. row.guid
            local rc_playing = preview.is_playing(rc_prev_id)
            if reaper.ImGui_MenuItem(ctx, rc_playing and 'Stop preview' or 'Preview') then
              if rc_playing then
                preview.stop()
              else
                local take = reaper.GetActiveTake(row.item)
                local src  = take and reaper.GetMediaItemTake_Source(take) or nil
                local path = src and reaper.GetMediaSourceFileName(src, '') or nil
                if path and path ~= '' then
                  preview.play_file(path, rc_prev_id, { volume = 0.8 })
                end
              end
            end
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_BeginDisabled(ctx, row.take_count <= 1)
            if reaper.ImGui_MenuItem(ctx, 'Delete current take') then
              A.delete_active_take_action(row.item)
            end
            reaper.ImGui_EndDisabled(ctx)
            if reaper.ImGui_MenuItem(ctx, 'Delete item') then
              local tr = reaper.GetMediaItemTrack(row.item)
              reaper.Undo_BeginBlock()
              reaper.DeleteTrackMediaItem(tr, row.item)
              reaper.Undo_EndBlock('Reasonate: Delete TTS dialogue item', -1)
              reaper.UpdateArrange()
              if rc_playing then preview.stop() end
              s.dialogue_row_handles[row.guid] = nil
            end
            reaper.ImGui_Separator(ctx)
            if reaper.ImGui_MenuItem(ctx, 'Reveal audio file…') then
              A.reveal_active_take_audio(row.item)
            end
            reaper.ImGui_EndPopup(ctx)
          end

          -- Preview button + summary line
          reaper.ImGui_SameLine(ctx, 0, 0)
          local prev_id = 'diag_row_' .. row.guid
          local prev_playing = preview.is_playing(prev_id)
          local prev_label = (prev_playing and '■##dprev_' or '▶##dprev_') .. row.guid
          if reaper.ImGui_SmallButton(ctx, prev_label) then
            if prev_playing then
              preview.stop()
            else
              local take = reaper.GetActiveTake(row.item)
              local src  = take and reaper.GetMediaItemTake_Source(take) or nil
              local path = src and reaper.GetMediaSourceFileName(src, '') or nil
              if path and path ~= '' then
                preview.play_file(path, prev_id, { volume = 0.8 })
              end
            end
          end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, prev_playing
              and 'Stop preview'
              or  'Preview active take (in-app, no REAPER playback)')
          end
          reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)

          -- Summary: first input excerpt + N speakers + N lines
          local first_txt = (row.inputs[1] and row.inputs[1].text) or ''
          local n_lines = #row.inputs
          local n_speakers = 0
          do
            local seen = {}
            for _, it in ipairs(row.inputs) do
              if not seen[it.voice_id] then seen[it.voice_id] = true; n_speakers = n_speakers + 1 end
            end
          end
          -- "Dialog:" text prefix (Inter font reliable) zamiast Unicode glyph
          -- ⛬ U+26EC, który nie jest w Inter v4 verified set.
          reaper.ImGui_Text(ctx, ('Dialog: "%s"'):format(A.format_short_text(first_txt, 50)))
          if reaper.ImGui_IsItemHovered(ctx) then
            -- Tooltip — show all lines if user hovers (preview of full dialogue)
            local lines_preview = {}
            for li, it in ipairs(row.inputs) do
              local short = (it.text or ''):gsub('\n', ' '):sub(1, 80)
              lines_preview[#lines_preview + 1] = ('%d. %s'):format(li, short)
              if li >= 10 then
                lines_preview[#lines_preview + 1] = ('… +%d more lines'):format(#row.inputs - 10)
                break
              end
            end
            reaper.ImGui_SetTooltip(ctx, table.concat(lines_preview, '\n'))
          end
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
          reaper.ImGui_Text(ctx, ('   %d speakers · %d lines · %s · gen %s'):format(
            n_speakers, n_lines,
            A.format_duration(row.duration),
            A.format_gen_time(row.generated_at)))
          reaper.ImGui_PopStyleColor(ctx, 1)

          -- Col 1: action buttons (take nav · lock · regen)
          reaper.ImGui_TableSetColumnIndex(ctx, 1)

          if row.take_count > 1 then
            if reaper.ImGui_SmallButton(ctx, '◀##dnav_l_' .. row.guid) then
              A.cycle_take(row.item, -1)
            end
            reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
            reaper.ImGui_Text(ctx, ('%d/%d'):format(
              row.active_take_idx + 1, row.take_count))
            reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
            if reaper.ImGui_SmallButton(ctx, '▶##dnav_r_' .. row.guid) then
              A.cycle_take(row.item, 1)
            end
            reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
          end

          -- Lock toggle
          local lock_label
          if row.locked then
            lock_label = 'Unlock##dlock_' .. row.guid
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
              theme.COLORS.status_error)
          else
            lock_label = 'Lock##dlock_' .. row.guid
          end
          if reaper.ImGui_SmallButton(ctx, lock_label) then
            A.toggle_item_lock(row.item)
          end
          if row.locked then reaper.ImGui_PopStyleColor(ctx, 1) end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, row.locked
              and 'Locked — click to unlock and regenerate'
              or  'Lock item (prevents regen)')
          end

          reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)

          -- Regen — uses A.spawn_dialogue_regen z P_EXT inputs + new seed
          local rhandle = s.dialogue_row_handles and s.dialogue_row_handles[row.guid] or nil
          if rhandle then
            reaper.ImGui_BeginDisabled(ctx, true)
            reaper.ImGui_SmallButton(ctx,
              voice_admin.spinner_glyph() .. '##dregen_' .. row.guid)
            reaper.ImGui_EndDisabled(ctx)
          else
            reaper.ImGui_BeginDisabled(ctx, row.locked)
            if reaper.ImGui_SmallButton(ctx, 'Regen##dregen_' .. row.guid) then
              A.spawn_dialogue_regen(s, row)
            end
            reaper.ImGui_EndDisabled(ctx)
            if reaper.ImGui_IsItemHovered(ctx) then
              reaper.ImGui_SetTooltip(ctx, row.locked
                and 'Locked — unlock to regenerate'
                or  'Regenerate dialogue with new seed (appends take)')
            end
          end
        end

        reaper.ImGui_EndTable(ctx)
      end
    end
    ::skip_history::
  end
end

----------------------------------------------------------------------------
-- W3 (mniej przewijania): przyklejony pasek akcji — renderowany przez
-- modes/tts.lua POD scroll-childem treści (zawsze widoczny). Zawiera
-- przeniesione z render_dialogue_content: Stability + Target track +
-- licznik znaków (1 zwarty wiersz) oraz Generate / Variants + status.
----------------------------------------------------------------------------
local function render_dialogue_actions(ctx, state, deps, s, busy)
  reaper.ImGui_Separator(ctx)

  -- Wiersz 1: Stability · Track · licznik
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Stability:')
  for _, mode in ipairs(A.V3_STABILITY_MODES) do
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    if reaper.ImGui_RadioButton(ctx, mode.label .. '##diag_stab',
                                s.dialogue_v3_stability == mode.id) then
      s.dialogue_v3_stability = mode.id
      A.mark_dirty(s)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, mode.tooltip)
    end
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
  reaper.ImGui_Text(ctx, 'Track:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_SetNextItemWidth(ctx, 200)
  local tracks = A.list_tracks_for_dropdown()
  local current_label = '(none — will be created)'
  for _, t in ipairs(tracks) do
    if t.guid == s.target_track_guid then
      current_label = ('%d. %s'):format(t.idx,
        (t.name ~= '' and t.name) or '(unnamed)')
      break
    end
  end
  if reaper.ImGui_BeginCombo(ctx, '##diag_target_track', current_label) then
    if reaper.ImGui_Selectable(ctx, '+ Create new "TTS" track', false) then
      reaper.Undo_BeginBlock()
      reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
      local new_tr = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
      reaper.GetSetMediaTrackInfo_String(new_tr, 'P_NAME', 'TTS', true)
      s.target_track_guid = reaper.GetTrackGUID(new_tr)
      A.mark_dirty(s)
      reaper.Undo_EndBlock('Reasonate: Insert TTS track', -1)
      reaper.TrackList_AdjustWindows(false)
    end
    reaper.ImGui_Separator(ctx)
    for _, t in ipairs(tracks) do
      local lbl = ('%d. %s'):format(t.idx,
        (t.name ~= '' and t.name) or '(unnamed)')
      if reaper.ImGui_Selectable(ctx, lbl .. '##diag_trk_' .. t.guid,
                                  t.guid == s.target_track_guid) then
        s.target_track_guid = t.guid
        A.mark_dirty(s)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'New dialogue items are inserted at the edit cursor position.')
  end

  local total_chars = A.count_dialogue_chars(s)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), dialogue_cost_color(total_chars))
  reaper.ImGui_Text(ctx, ('%d / %d chars'):format(total_chars, A.DIALOGUE_MAX_CHARS))
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- Tryb poprawek per linia (user 2026-06-11): OFF = dialog zostaje jednym
  -- plikiem, regen linii ląduje na tracku pod spodem; ON = cięcie na klocki.
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
  local sm_chg, sm_val = reaper.ImGui_Checkbox(ctx,
    'Cut into line items##diag_patch_mode', s.patch_split_mode == true)
  if sm_chg then
    s.patch_split_mode = sm_val
    A.mark_dirty(s)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'How per-line [Re-gen] patches audio:\n' ..
      'OFF — the dialogue stays ONE file; the re-rendered line lands on a\n' ..
      '"TTS · line takes" track below, under its original spot, at its\n' ..
      'full natural length. You comp/mute manually.\n' ..
      'ON — the first [Re-gen] cuts the dialogue item into per-line items;\n' ..
      'the line then gets a new take on its own item.')
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    if total_chars > A.DIALOGUE_MAX_CHARS then
      reaper.ImGui_SetTooltip(ctx, 'Over API limit — trim lines or split into multiple Generate calls.')
    elseif total_chars > A.DIALOGUE_LIMIT_AMBER then
      reaper.ImGui_SetTooltip(ctx, 'Approaching dialogue length limit.')
    else
      reaper.ImGui_SetTooltip(ctx, 'Total characters billed per Generate call.')
    end
  end

  -- Wiersz 2: Generate / Variants + status
  local can_generate = (total_chars <= A.DIALOGUE_MAX_CHARS)
                    and #(s.dialogue_speakers or {}) > 0
                    and #(s.dialogue_lines    or {}) > 0
  local btn_label
  if busy then
    local elapsed = util.now() - (s.dialogue_gen_handle.started_at or util.now())
    btn_label = ('Cancel  %s   %.1fs'):format(voice_admin.spinner_glyph(), elapsed)
  else
    btn_label = 'Generate    ' .. (deps and deps.mod_label or 'Cmd') .. '+Enter'
  end

  reaper.ImGui_BeginDisabled(ctx, not (busy or can_generate))
  if theme.button_primary(ctx, btn_label, 280, 40) then
    if busy then
      A.cancel_dialogue_generation(s)
    else
      A.spawn_generate_dialogue(s, deps)
    end
  end
  reaper.ImGui_EndDisabled(ctx)
  if busy and reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Stop the current generation. In-flight request finishes in the\n' ..
      'background and is cached, but no item is created.')
  end

  -- Variants ×3 USUNIĘTE z dialogu 2026-06-11 (user decision — 3× rachunek
  -- za całą rozmowę; korekty robi się per linia / Re-gen take).

  -- ====== Enhance: LLM dodaje v3 audio tagi (words-preserved guaranteed) ======
  -- Layout (user, 3. iteracja 2026-06-11): Enhance+▼ pełne 40, Revert jako
  -- ghost ZARAZ ZA strzałką (stacked pod spodem wyglądał źle ×2).
  local enhance_busy = s.enhance_handle ~= nil
  local provider     = llm.effective_provider()
  local has_revert   = (s.enhance_revert and s.enhance_revert.kind == 'dialogue') or false
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_BeginDisabled(ctx, busy or enhance_busy or (not provider)
    or #(s.dialogue_lines or {}) == 0)
  local enh_label = enhance_busy
    and ('Enhance ' .. voice_admin.spinner_glyph() .. '##diag_enhance')
    or 'Enhance##diag_enhance'
  if theme.button_neutral(ctx, enh_label, 110, 40) then
    A.request_enhance(s)
  end
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
    if not provider then
      reaper.ImGui_SetTooltip(ctx,
        'Add an LLM provider key in Settings → AI tab to enable Enhance.')
    elseif enhance_busy then
      reaper.ImGui_SetTooltip(ctx, 'Adding audio tags…')
    else
      reaper.ImGui_SetTooltip(ctx,
        'Automatically add v3 audio tags (emotion, delivery, reactions)\n' ..
        'across the whole conversation. Your words are never altered —\n' ..
        'guaranteed. One short request to ' .. provider .. '.')
    end
  end
  reaper.ImGui_SameLine(ctx, 0, 2)
  reaper.ImGui_BeginDisabled(ctx, busy or enhance_busy)
  -- Trójkąt DrawList zamiast glyphu ▼ — w Inter glyph siedzi niesymetrycznie
  -- w przycisku (user 2026-06-11); geometria centruje się sama.
  local opts_clicked = theme.button_neutral(ctx, '##diag_enh_opts', 26, 40)
  do
    local bx1, by1 = reaper.ImGui_GetItemRectMin(ctx)
    local bx2, by2 = reaper.ImGui_GetItemRectMax(ctx)
    local cx, cy = (bx1 + bx2) * 0.5, (by1 + by2) * 0.5
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    -- DrawList nie dziedziczy alpha z BeginDisabled — dociemnij ręcznie
    local tri_col = (busy or enhance_busy) and theme.COLORS.text_muted
                                           or theme.COLORS.text
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      cx - 4, cy - 2.5, cx + 4, cy - 2.5, cx, cy + 3.5, tri_col)
  end
  if opts_clicked then
    reaper.ImGui_OpenPopup(ctx, 'diag_enhance_opts')
  end
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, "Enhance settings: intensity + director's note.")
  end
  if reaper.ImGui_BeginPopup(ctx, 'diag_enhance_opts') then
    reaper.ImGui_Text(ctx, 'Tagging intensity')
    for _, it in ipairs(A.ENHANCE_INTENSITIES) do
      if reaper.ImGui_RadioButton(ctx, it.label .. '##diag_enh_int',
                                  s.enhance_intensity == it.id) then
        s.enhance_intensity = it.id
        A.mark_dirty(s)
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, it.tooltip)
      end
    end
    reaper.ImGui_Spacing(ctx)
    local punct_chg, punct_val = reaper.ImGui_Checkbox(ctx,
      'Allow pauses & emphasis##diag_enh_punct', s.enhance_punct == true)
    if punct_chg then
      s.enhance_punct = punct_val
      A.mark_dirty(s)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'The model may also insert ellipses (...) for weighted pauses and\n' ..
        'write single words in CAPITALS for emphasis — v3 reads both.\n' ..
        'Words themselves still never change (guaranteed).')
    end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, "Director's note (optional)")
    reaper.ImGui_SetNextItemWidth(ctx, 280)
    local note_chg, note_txt = reaper.ImGui_InputText(ctx, '##diag_enh_note',
      s.enhance_note or '')
    if note_chg then
      s.enhance_note = note_txt
      A.mark_dirty(s)
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
    reaper.ImGui_Text(ctx, 'e.g. "horror scene, rising tension"')
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_EndPopup(ctx)
  end

  if has_revert then
    -- Revert obok, za strzałką — ghost (wtórna akcja, lżejsza wizualnie).
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    if theme.button_ghost(ctx, 'Revert enhance##diag', 0, 40) then
      A.revert_enhance(s)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Restore the lines from before Enhance\n' ..
        '(also discards edits made after it).')
    end
  end

  -- Dirty po generacji (W3 2026-06-11): linie panelu różnią się od inputs
  -- ostatnio wygenerowanego itemu → wskaźnik + 1-klik nowy take na tym samym
  -- itemie (stare take'i zostają — mirror dirty→1-klik z dubbingu).
  if not busy then
    local sync = A.dialogue_take_sync(s)
    if sync and sync.dirty then
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
      reaper.ImGui_Text(ctx, '● edited since last take')
      reaper.ImGui_PopStyleColor(ctx, 1)
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          'Lines differ from the most recently generated dialogue item.')
      end
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
      reaper.ImGui_BeginDisabled(ctx, sync.locked == true)
      if reaper.ImGui_SmallButton(ctx, 'Re-gen whole take##diag_dirty') then
        A.regen_dialogue_take(s, deps, sync.guid)
      end
      reaper.ImGui_EndDisabled(ctx)
      if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
        reaper.ImGui_SetTooltip(ctx, sync.locked
          and 'Item is locked — unlock it in the history list first.'
          or  'Regenerate the WHOLE conversation as a new take (billed for\n' ..
              'all characters; best prosody continuity). To fix a single\n' ..
              'line cheaply, use [Re-gen] next to that line instead.')
      end
    end
  end

  -- Status inline po prawej od przycisków (pasek ma stałą wysokość).
  -- Przycinany z '…' do dostępnej szerokości (długie komunikaty wyciekały
  -- pod paletę) — pełna treść zawsze w tooltipie.
  if s.dialogue_gen_status_text and s.dialogue_gen_status_text ~= '' then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    local txt = s.dialogue_gen_status_text
    local rem_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local max_chars = math.max(8, math.floor((rem_w - 10) / 7))
    if #txt > max_chars then
      -- utnij + zdejmij ewentualny niedokończony znak UTF-8 na końcu
      txt = txt:sub(1, max_chars):gsub('[\192-\255][\128-\191]*$', '') .. '…'
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      s.dialogue_gen_status_color or theme.COLORS.text_dim)
    reaper.ImGui_Text(ctx, txt)
    reaper.ImGui_PopStyleColor(ctx, 1)
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, s.dialogue_gen_status_text)
    end
  end

  -- Enhance: potwierdzenie z fade-out (Revert przeniesiony POD Enhance)
  theme.draw_flash_inline(ctx, 'tts_enhance')
end

----------------------------------------------------------------------------
-- NS-2c: palette dla dialogue — same as single v3 palette ale insertion
-- targets s.dialogue_focused_line_id zamiast s.text_buffer. Klik tag →
-- append-end do focused line (M1 no per-line EEL cursor; M2 polish).
----------------------------------------------------------------------------
local function render_dialogue_palette(ctx, s)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.override)
  reaper.ImGui_Text(ctx, 'v3 TAGS')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
  local focused = s.dialogue_focused_line_id
  local hint = focused and 'Click inserts [tag] at end of focused line.'
                       or  'Click in a line first, then tap a tag.'
  reaper.ImGui_TextWrapped(ctx, hint)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Separator(ctx)

  -- Insertion target dla obu gałęzi palety (search hits + kategorie):
  -- append-end do focused line. Wydzielone żeby search nie dublował pętli.
  local function insert_into_focused(tag)
    if not focused then return end
    for _, ln in ipairs(s.dialogue_lines or {}) do
      if ln.id == focused then
        -- W3 (user-reported): wstaw w POZYCJI KURSORA (EEL callback, mirror
        -- single mode), nie na końcu linii. ln.text jest znormalizowany,
        -- a soft_wrap zachowuje długość (separator zawsze 1 znak) → offset
        -- kursora z widoku łamanego mapuje się 1:1 na czysty tekst.
        local cb = A.get_input_callback and A.get_input_callback(ctx) or nil
        local cursor = nil
        if cb then
          local ok_get, c = pcall(reaper.ImGui_Function_GetValue, cb, 'cursor_pos')
          if ok_get then cursor = math.floor(c or 0) end
        end
        local txt = ln.text or ''
        if cb and cursor and cursor >= 0 and cursor <= #txt then
          local before = txt:sub(1, cursor)
          local after  = txt:sub(cursor + 1)
          local ins = '[' .. tag .. ']'
          if before ~= '' and not before:match('%s$') then ins = ' ' .. ins end
          if after  == '' or not after:match('^%s')   then ins = ins .. ' ' end
          ln.text = util.normalize_whitespace(before .. ins .. after)
          wrap_buf[ln.id] = nil   -- świeży wrap w next frame
          pcall(reaper.ImGui_Function_SetValue, cb, 'target_cursor', #before + #ins)
          pcall(reaper.ImGui_Function_SetValue, cb, 'set_cursor', 1)
          s.dialogue_pending_focus_line_id = ln.id
          s.dialogue_edit_line_id          = ln.id   -- widok ↔ edycja: zostań w edycji
        else
          -- Fallback (brak EEL / stale cursor poza zakresem): append-end
          ln.text = audio_tags.insert_tag(txt, tag)
        end
        A.mark_dirty(s)
        break
      end
    end
  end

  -- W3 UI/UX (2026-06-10): tag search — mirror tts_panel.render_palette.
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Find')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  local q = s.tag_search or ''
  reaper.ImGui_SetNextItemWidth(ctx, q ~= '' and -28 or -1)
  local rv_q, new_q = reaper.ImGui_InputText(ctx, '##dtag_search', q)
  if rv_q then s.tag_search = new_q; q = new_q end
  if q ~= '' then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    if reaper.ImGui_SmallButton(ctx, 'x##dtag_search_clear') then
      s.tag_search = ''
      q = ''
    end
  end

  if q ~= '' then
    local hits = audio_tags.search(q)
    if #hits == 0 then
      reaper.ImGui_TextDisabled(ctx, 'No matching tags.')
    end
    for _, t in ipairs(hits) do
      if reaper.ImGui_Selectable(ctx, ('  [%s]##dstag_%s'):format(t.tag, t.tag), false) then
        insert_into_focused(t.tag)
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, (t.tooltip or t.tag) .. '\nCategory: ' .. t.cat)
      end
    end
    return
  end

  if reaper.ImGui_SmallButton(ctx, 'Expand all##dtagcats') then
    for _, cat in ipairs(audio_tags.CATEGORIES) do s.tag_cat_collapsed[cat.name] = false end
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if reaper.ImGui_SmallButton(ctx, 'Collapse all##dtagcats') then
    for _, cat in ipairs(audio_tags.CATEGORIES) do s.tag_cat_collapsed[cat.name] = true end
  end

  for _, cat in ipairs(audio_tags.CATEGORIES) do
    local key = cat.name
    if s.tag_cat_collapsed[key] == nil then
      s.tag_cat_collapsed[key] = (cat.expanded_default ~= true)
    end
    local collapsed = s.tag_cat_collapsed[key]
    local arrow = collapsed and '▶' or '▼'
    if reaper.ImGui_Selectable(ctx, ('%s %s##dcat_%s'):format(arrow, key, key), false) then
      s.tag_cat_collapsed[key] = not collapsed
    end
    if not collapsed then
      if cat.experimental_note then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
        reaper.ImGui_TextWrapped(ctx, '  ' .. cat.experimental_note)
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_Spacing(ctx)
      end
      for _, t in ipairs(cat.tags) do
        if reaper.ImGui_Selectable(ctx,
            ('  [%s]##dtag_%s'):format(t.tag, t.tag), false) then
          insert_into_focused(t.tag)
        end
        if reaper.ImGui_IsItemHovered(ctx) and t.tooltip then
          reaper.ImGui_SetTooltip(ctx, t.tooltip)
        end
      end
    end
  end
end


M.render         = render_dialogue_content
M.render_actions = render_dialogue_actions
M.render_palette = render_dialogue_palette

return M
