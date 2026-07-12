-- modules/gui/tts_panel.lua
-- NS-2b single-voice TTS sub-mode — UI panel (+ v3 audio-tags palette).
--
-- Wydzielone z modes/tts.lua (audit M3-1, 2026-06-10; plik miał 4257 LOC)
-- — czysto mechaniczne przeniesienie render functions, zero zmian
-- zachowania. Logika zostaje w modes/tts.lua, wchodzi przez tabelę A
-- (M.init(actions)). Konwencja mirror: gui/repair_panel + modes/repair.

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

local M = {}

local A = nil   -- akcje + stałe z modes/tts.lua (patrz tamtejsza tabela A)
function M.init(actions) A = actions end

----------------------------------------------------------------------------
-- Render — audio tags palette (M2). Pasek po prawej ~220 px, rendered TYLKO
-- gdy model.audio_tags=true (czyli v3) — patrz M.render, conditional layout.
-- Każda kategoria ma collapsible header (manual toggle via Selectable —
-- historyczny wybór; CollapsingHeader JEST w Lua, stary komentarz kłamał
-- — M7 errata 2026-07-11). Klik w tag →
-- audio_tags.insert_tag append na końcu s.text_buffer.
----------------------------------------------------------------------------
local function render_palette(ctx, s, cb)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.override)
  reaper.ImGui_Text(ctx, 'v3 TAGS')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
  local hint = cb and 'Click inserts [tag] at cursor position.'
                  or  'Click inserts [tag] at end of text.'  -- fallback gdy EEL niedostępny
  reaper.ImGui_TextWrapped(ctx, hint)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Separator(ctx)

  -- W3 UI/UX (2026-06-10): tag search — niepusty query → płaska lista trafień
  -- cross-category (zamiast ręcznego rozwijania kategorii). InputTextWithHint
  -- nie istnieje w Lua API (KNOWN-ISSUES) — label 'Find' przed polem.
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Find')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  local q = s.tag_search or ''
  reaper.ImGui_SetNextItemWidth(ctx, q ~= '' and -28 or -1)
  local rv_q, new_q = reaper.ImGui_InputText(ctx, '##tag_search', q)
  if rv_q then s.tag_search = new_q; q = new_q end
  if q ~= '' then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    if reaper.ImGui_SmallButton(ctx, 'x##tag_search_clear') then
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
      if reaper.ImGui_Selectable(ctx, ('  [%s]##stag_%s'):format(t.tag, t.tag), false) then
        local tag_str = '[' .. t.tag .. '] '
        local inserted = cb and A.request_insert_at_cursor(cb, tag_str, s)
        if not inserted then
          s.text_buffer = audio_tags.insert_tag(s.text_buffer, t.tag)
          A.mark_dirty(s)
        end
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, (t.tooltip or t.tag) .. '\nCategory: ' .. t.cat)
      end
    end
    return
  end

  if reaper.ImGui_SmallButton(ctx, 'Expand all##tagcats') then
    for _, cat in ipairs(audio_tags.CATEGORIES) do s.tag_cat_collapsed[cat.name] = false end
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if reaper.ImGui_SmallButton(ctx, 'Collapse all##tagcats') then
    for _, cat in ipairs(audio_tags.CATEGORIES) do s.tag_cat_collapsed[cat.name] = true end
  end

  for _, cat in ipairs(audio_tags.CATEGORIES) do
    local key = cat.name
    if s.tag_cat_collapsed[key] == nil then
      s.tag_cat_collapsed[key] = (cat.expanded_default ~= true)
    end
    local collapsed = s.tag_cat_collapsed[key]
    local arrow = collapsed and '▶' or '▼'
    if reaper.ImGui_Selectable(ctx, ('%s %s##cat_%s'):format(arrow, key, key), false) then
      s.tag_cat_collapsed[key] = not collapsed
    end
    if not collapsed then
      -- Experimental categories (SFX, Body state) get a dim warning banner
      -- explaining inconsistent results + practical mitigation tips.
      if cat.experimental_note then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
        reaper.ImGui_TextWrapped(ctx, '  ' .. cat.experimental_note)
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_Spacing(ctx)
      end
      for _, t in ipairs(cat.tags) do
        if reaper.ImGui_Selectable(ctx,
            ('  [%s]##tag_%s'):format(t.tag, t.tag), false) then
          -- Prefer EEL callback insertion at cursor; fallback to append-end.
          local tag_str = '[' .. t.tag .. '] '
          local inserted = cb and A.request_insert_at_cursor(cb, tag_str, s)
          if not inserted then
            s.text_buffer = audio_tags.insert_tag(s.text_buffer, t.tag)
            A.mark_dirty(s)
          end
        end
        if reaper.ImGui_IsItemHovered(ctx) and t.tooltip then
          reaper.ImGui_SetTooltip(ctx, t.tooltip)
        end
      end
    end
  end
end

----------------------------------------------------------------------------
-- Render — left content (text + voice + model + sliders + track + generate).
-- Extracted z M.render do split layout content + palette (M2).
----------------------------------------------------------------------------
local function render_content(ctx, state, deps, s, model, busy)
  -- ====== Tekst ======
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Text')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)

  local char_count = util.utf8_len(s.text_buffer or '')
  local over_limit = char_count > model.char_limit
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
    over_limit and theme.COLORS.status_error or theme.COLORS.text_dim)
  reaper.ImGui_Text(ctx, ('%d / %d'):format(char_count, model.char_limit))
  reaper.ImGui_PopStyleColor(ctx, 1)

  if model.audio_tags then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.override)
    reaper.ImGui_Text(ctx, 'v3 audio tags available — type [whispers], [excited], [laughs]…')
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  -- EEL callback gives us cursor position + insertion. Pending focus from tag
  -- click drives Keyboard focus back to InputText so callback fires next frame.
  local cb = A.get_input_callback(ctx)
  if s.pending_focus_input then
    reaper.ImGui_SetKeyboardFocusHere(ctx, 0)
    s.pending_focus_input = false
  end

  local flags = 0
  if cb then flags = reaper.ImGui_InputTextFlags_CallbackAlways() end
  local rv_text, new_text = reaper.ImGui_InputTextMultiline(ctx, '##tts_text',
    s.text_buffer or '', -1, 120, flags, cb)
  if rv_text then s.text_buffer = new_text; A.mark_dirty(s) end

  -- (Tag preview/chip row removed per user feedback — `[tag]` syntax in the
  -- editor itself is sufficient; ImGui InputTextMultiline can't render
  -- inline color/bold per fragment so any preview was supplementary clutter.)

  reaper.ImGui_Spacing(ctx)

  -- ====== Voice + Model row ======
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Voice:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if s.selected_voice then
    reaper.ImGui_Text(ctx, s.selected_voice.name or s.selected_voice.voice_id or '?')
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
    reaper.ImGui_Text(ctx, '(not selected)')
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if theme.button_neutral(ctx, 'Pick voice…', 150, 0) then
    voice_picker.open({
      state            = state,
      track_guid       = nil,
      current_voice_id = s.selected_voice and s.selected_voice.voice_id or nil,
      on_pick = function(voice_id, voice_name)
        if voice_id and voice_id ~= '' then
          s.selected_voice = { voice_id = voice_id, name = voice_name }
          A.mark_dirty(s)
        end
      end,
      allow_clear = false,
    })
  end

  -- ====== Preset row (B#6) ======
  -- Named save of voice + model + settings — useful when a project has many
  -- characters. Right-click a preset in the dropdown to delete it.
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Preset:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_SetNextItemWidth(ctx, 220)

  local preset_names = cfg.list_tts_preset_names()
  local preset_combo_label = (#preset_names == 0) and '(no presets)' or '(pick to apply)'

  if reaper.ImGui_BeginCombo(ctx, '##tts_preset', preset_combo_label) then
    if #preset_names == 0 then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
      reaper.ImGui_Text(ctx, '  No presets yet — use "Save as…" to create one.')
      reaper.ImGui_PopStyleColor(ctx, 1)
    end
    for _, name in ipairs(preset_names) do
      if reaper.ImGui_Selectable(ctx, name .. '##preset_' .. name, false) then
        A.apply_preset(s, cfg.get_tts_preset(name))
      end
      if reaper.ImGui_BeginPopupContextItem(ctx, 'preset_ctx_' .. name) then
        if reaper.ImGui_MenuItem(ctx, 'Delete preset') then
          cfg.delete_tts_preset(name)
          theme.flash('tts_preset', ('Deleted preset "%s".'):format(name), theme.COLORS.text_dim)
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
  reaper.ImGui_BeginDisabled(ctx, not (s.selected_voice and s.selected_voice.voice_id))
  if theme.button_neutral(ctx, 'Save as…##preset_save', 100, 0) then
    s.preset_save_name = (s.selected_voice and s.selected_voice.name) or 'Preset'
    reaper.ImGui_OpenPopup(ctx, 'tts_preset_save')
  end
  reaper.ImGui_EndDisabled(ctx)
  if (not (s.selected_voice and s.selected_voice.voice_id))
      and reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Pick a voice first.')
  end
  theme.draw_flash_inline(ctx, 'tts_preset')

  -- Preset save modal — InputText for name + Save/Cancel.
  theme.center_next_modal(ctx)
  theme.popup_keep_top(ctx, 'tts_preset_save')
  if reaper.ImGui_BeginPopupModal(ctx, 'tts_preset_save', nil,
       reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    reaper.ImGui_Text(ctx, 'Save current voice + model + settings as preset.')
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, 'Name:')
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    reaper.ImGui_SetNextItemWidth(ctx, 260)
    local rv_p, new_p = reaper.ImGui_InputText(ctx, '##preset_name', s.preset_save_name or '')
    if rv_p then s.preset_save_name = new_p end
    reaper.ImGui_Spacing(ctx)
    local can_save = s.preset_save_name and s.preset_save_name ~= ''
    reaper.ImGui_BeginDisabled(ctx, not can_save)
    if theme.button_primary(ctx, 'Save##preset_save_ok', 110, 0) then
      cfg.save_tts_preset(s.preset_save_name, A.build_current_preset(s))
      theme.flash('tts_preset', ('Saved preset "%s".'):format(s.preset_save_name))
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndDisabled(ctx)
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    -- Esc parity z modalem castu w dialogu (unifikacja preset UI, C/D).
    if theme.button_neutral(ctx, 'Cancel##preset_save_cancel', 110, 0)
       or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  reaper.ImGui_Spacing(ctx)

  -- ====== Model picker (4 radio buttons w jednym rzędzie) ======
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Model:')
  for _, m in ipairs(A.MODELS) do
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    if reaper.ImGui_RadioButton(ctx, m.label, s.model_id == m.id) then
      s.model_id = m.id
      A.mark_dirty(s)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, m.tooltip)
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- ====== Voice settings ======
  -- Stability: v3 → 3 dyskretne mody; inne → slider 0-1
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Stability:')
  if model.id == 'eleven_v3' then
    for _, mode in ipairs(A.V3_STABILITY_MODES) do
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
      if reaper.ImGui_RadioButton(ctx, mode.label, s.v3_stability == mode.id) then
        s.v3_stability = mode.id
        A.mark_dirty(s)
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, mode.tooltip)
      end
    end
  else
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    reaper.ImGui_SetNextItemWidth(ctx, 240)
    local rv_stab, new_stab = reaper.ImGui_SliderDouble(ctx, '##stab',
      s.stability, 0.0, 1.0, '%.2f')
    if rv_stab then s.stability = new_stab; A.mark_dirty(s) end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Low = more variation/expression; high = stability and consistency.')
    end
  end

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Similarity:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 240)
  local rv_sim, new_sim = reaper.ImGui_SliderDouble(ctx, '##similarity',
    s.similarity, 0.0, 1.0, '%.2f')
  if rv_sim then s.similarity = new_sim; A.mark_dirty(s) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'How close to original voice. Too high + weak sample = artifacts.')
  end

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Style:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 240)
  local rv_sty, new_sty = reaper.ImGui_SliderDouble(ctx, '##style',
    s.style, 0.0, 1.0, '%.2f')
  if rv_sty then s.style = new_sty; A.mark_dirty(s) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Speaker style amplification. Default 0 (per docs). Increases latency.')
  end

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Speed:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 240)
  local rv_spd, new_spd = reaper.ImGui_SliderDouble(ctx, '##speed',
    s.speed, 0.7, 1.2, '%.2f×')
  if rv_spd then s.speed = new_spd; A.mark_dirty(s) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Speech tempo. 1.0 = natural. Range 0.7–1.2.')
  end

  reaper.ImGui_BeginDisabled(ctx, not model.supports_speaker_boost)
  local rv_sb, new_sb = reaper.ImGui_Checkbox(ctx, 'Speaker boost', s.speaker_boost)
  if rv_sb then s.speaker_boost = new_sb; A.mark_dirty(s) end
  reaper.ImGui_EndDisabled(ctx)
  if (not model.supports_speaker_boost) and reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Not available for v3 model.')
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- ====== Target track ======
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Target track:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 320)

  local tracks = A.list_tracks_for_dropdown()
  local current_label = '(none — will be created)'
  for _, t in ipairs(tracks) do
    if t.guid == s.target_track_guid then
      current_label = ('%d. %s'):format(t.idx,
        (t.name ~= '' and t.name) or '(unnamed)')
      break
    end
  end

  if reaper.ImGui_BeginCombo(ctx, '##tts_target_track', current_label) then
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
      if reaper.ImGui_Selectable(ctx, lbl .. '##trk_' .. t.guid,
                                  t.guid == s.target_track_guid) then
        local switching = (t.guid ~= s.target_track_guid)
        s.target_track_guid = t.guid
        A.mark_dirty(s)
        -- B#5: load track's saved TTS defaults (voice + model + settings)
        -- only when actually switching to a different track. No-op if the
        -- track was never used for TTS (no P_EXT defaults stored).
        if switching then
          A.apply_track_tts_defaults(s, helpers.find_track_by_guid(t.guid))
        end
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
  reaper.ImGui_Text(ctx, '· position: edit cursor')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)

  -- ====== Generate + Variants buttons (primary CTA — always visible) ======
  -- When busy: Generate becomes Cancel (clickable), Variants disabled.
  -- When idle: Generate primary, Variants secondary.
  local btn_label
  if busy then
    local elapsed = util.now() - (s.gen_handle.started_at or util.now())
    btn_label = ('Cancel  %s   %.1fs'):format(voice_admin.spinner_glyph(), elapsed)
  else
    btn_label = 'Generate    ' .. (deps and deps.mod_label or 'Cmd') .. '+Enter'
  end

  if theme.button_primary(ctx, btn_label, 280, 40) then
    if busy then
      A.cancel_generation(s)
    else
      A.spawn_generate(s, deps)
    end
  end
  if busy and reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Stop the current generation. In-flight request finishes in the\n' ..
      'background and is cached, but no item is created.')
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_BeginDisabled(ctx, busy)
  if theme.button_neutral(ctx, 'Variants ×3', 140, 40) then
    A.spawn_variants(s, deps, 3)
  end
  if (not busy) and reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Generate 3 takes with different seeds, all on one item.\n' ..
      'Each take billed separately. Cmd-Z undoes all.')
  end
  reaper.ImGui_EndDisabled(ctx)

  -- ====== Enhance: LLM dodaje v3 audio tagi (words-preserved guaranteed).
  -- Tylko v3 — pozostałe modele ignorują tagi (zostałyby przeczytane). ======
  if model.audio_tags then
    -- Layout (user, 3. iteracja 2026-06-11): Enhance+▼ pełne 40, Revert
    -- jako ghost zaraz za strzałką.
    local enhance_busy = s.enhance_handle ~= nil
    local provider     = llm.effective_provider()
    local text_empty   = #((s.text_buffer or ''):gsub('%s', '')) < 3
    local has_revert   = (s.enhance_revert and s.enhance_revert.kind == 'single') or false
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    reaper.ImGui_BeginDisabled(ctx, busy or enhance_busy or (not provider) or text_empty)
    local enh_label = enhance_busy
      and ('Enhance ' .. voice_admin.spinner_glyph() .. '##single_enhance')
      or 'Enhance##single_enhance'
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
          'to the text. Your words are never altered — guaranteed.\n' ..
          'One short request to ' .. (provider or '?') .. '.')
      end
    end
    reaper.ImGui_SameLine(ctx, 0, 2)
    reaper.ImGui_BeginDisabled(ctx, busy or enhance_busy)
    -- Trójkąt DrawList zamiast glyphu ▼ — w Inter glyph siedzi niesymetrycznie
    -- w przycisku (user 2026-06-11); geometria centruje się sama.
    local opts_clicked = theme.button_neutral(ctx, '##single_enh_opts', 26, 40)
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
      reaper.ImGui_OpenPopup(ctx, 'single_enhance_opts')
    end
    reaper.ImGui_EndDisabled(ctx)
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Enhance settings: intensity + director's note.")
    end
    if reaper.ImGui_BeginPopup(ctx, 'single_enhance_opts') then
      reaper.ImGui_Text(ctx, 'Tagging intensity')
      for _, it in ipairs(A.ENHANCE_INTENSITIES) do
        if reaper.ImGui_RadioButton(ctx, it.label .. '##single_enh_int',
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
        'Allow pauses & emphasis##single_enh_punct', s.enhance_punct == true)
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
      local note_chg, note_txt = reaper.ImGui_InputText(ctx, '##single_enh_note',
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
      if theme.button_ghost(ctx, 'Revert enhance##single', 0, 40) then
        A.revert_enhance(s)
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          'Restore the text from before Enhance\n' ..
          '(also discards edits made after it).')
      end
    end

    -- Potwierdzenie z fade-out
    theme.draw_flash_inline(ctx, 'tts_enhance')
  end

  -- ====== Status (sits with Generate so user sees feedback) ======
  if s.gen_status_text and s.gen_status_text ~= '' then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      s.gen_status_color or theme.COLORS.text_dim)
    reaper.ImGui_TextWrapped(ctx, s.gen_status_text)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_Spacing(ctx)

  -- ====== M3: Per-item history list ======
  local target_tr = nil
  if s.target_track_guid and s.target_track_guid ~= '' then
    target_tr = helpers.find_track_by_guid(s.target_track_guid)
  end
  if target_tr then
    local items = A.scan_tts_items_on_track(target_tr)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, ('Generated on track · %d %s'):format(
      #items, #items == 1 and 'item' or 'items'))

    if #items == 0 then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
      reaper.ImGui_TextWrapped(ctx,
        'None yet — click Generate to create the first one.')
      reaper.ImGui_PopStyleColor(ctx, 1)
    else
      local TABLE_FLAGS = reaper.ImGui_TableFlags_BordersInnerH()
                        | reaper.ImGui_TableFlags_RowBg()
                        | reaper.ImGui_TableFlags_PadOuterX()
      if reaper.ImGui_BeginTable(ctx, 'tts_items', 2, TABLE_FLAGS, -1, 0) then
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
          if reaper.ImGui_Selectable(ctx, '##row_' .. row.guid, is_sel, sel_flags) then
            A.select_item_in_timeline(row.item)
            s.selected_tts_guid = row.guid
          end
          -- W3 quick win: menu istniało tylko pod prawym klikiem bez śladu w UI
          -- (audyt W3). ForTooltip = delayed + stationary — nie spamuje przy
          -- przelocie myszą po liście.
          if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_ForTooltip()) then
            reaper.ImGui_SetTooltip(ctx,
              'Click selects the item in REAPER.\nRight-click: preview · delete take · delete item · reveal file.')
          end

          -- Right-click context menu (attached to the row Selectable, which
          -- spans the full row; per AllowOverlap, action buttons still own
          -- left-clicks). MenuItem labels match button labels where they
          -- overlap so the menu is discoverable rather than redundant.
          if reaper.ImGui_BeginPopupContextItem(ctx, 'tts_row_ctx_' .. row.guid) then
            local rc_prev_id = 'tts_row_' .. row.guid
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
              reaper.Undo_EndBlock('Reasonate: Delete TTS item', -1)
              reaper.UpdateArrange()
              -- Stop preview if it was for this row (handle now points to dead item)
              if rc_playing then preview.stop() end
              -- Cancel pending regen for this row (handle file still arrives but item gone)
              s.row_handles[row.guid] = nil
            end

            reaper.ImGui_Separator(ctx)

            if reaper.ImGui_MenuItem(ctx, 'Reveal audio file…') then
              A.reveal_active_take_audio(row.item)
            end

            reaper.ImGui_EndPopup(ctx)
          end

          -- Preview button + text line. SmallButton overlaps the SpanAllColumns
          -- Selectable per ImGui AllowOverlap (click hits button, not row select).
          reaper.ImGui_SameLine(ctx, 0, 0)
          local prev_id = 'tts_row_' .. row.guid
          local prev_playing = preview.is_playing(prev_id)
          local prev_label = (prev_playing and '■##prev_' or '▶##prev_') .. row.guid
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
          reaper.ImGui_Text(ctx, '"' .. A.format_short_text(row.text, 50) .. '"')
          if reaper.ImGui_IsItemHovered(ctx) and row.text and row.text ~= '' then
            reaper.ImGui_SetTooltip(ctx, row.text)
          end
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
          local short_model = row.model_id ~= '' and row.model_id:gsub('eleven_', '') or '?'
          reaper.ImGui_Text(ctx, ('   %s · %s · %s · gen %s'):format(
            row.voice_name ~= '' and row.voice_name or '?',
            short_model,
            A.format_duration(row.duration),
            A.format_gen_time(row.generated_at)))
          reaper.ImGui_PopStyleColor(ctx, 1)

          -- Col 1: action buttons (take nav · lock · regen)
          reaper.ImGui_TableSetColumnIndex(ctx, 1)

          if row.take_count > 1 then
            if reaper.ImGui_SmallButton(ctx, '◀##nav_l_' .. row.guid) then
              A.cycle_take(row.item, -1)
            end
            reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
            reaper.ImGui_Text(ctx, ('%d/%d'):format(
              row.active_take_idx + 1, row.take_count))
            reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
            if reaper.ImGui_SmallButton(ctx, '▶##nav_r_' .. row.guid) then
              A.cycle_take(row.item, 1)
            end
            reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
          end

          -- Lock toggle (Inter font nie ma 🔒 emoji — używamy tekst)
          local lock_label
          if row.locked then
            lock_label = 'Unlock##lock_' .. row.guid
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
              theme.COLORS.status_error)
          else
            lock_label = 'Lock##lock_' .. row.guid
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

          -- Regen (♻ jako emoji nie wspiera Inter — używamy 'Regen')
          local handle = s.row_handles[row.guid]
          if handle then
            reaper.ImGui_BeginDisabled(ctx, true)
            reaper.ImGui_SmallButton(ctx,
              voice_admin.spinner_glyph() .. '##regen_' .. row.guid)
            reaper.ImGui_EndDisabled(ctx)
          else
            reaper.ImGui_BeginDisabled(ctx, row.locked)
            if reaper.ImGui_SmallButton(ctx, 'Regen##regen_' .. row.guid) then
              A.spawn_regen(s, row)
            end
            reaper.ImGui_EndDisabled(ctx)
            if reaper.ImGui_IsItemHovered(ctx) then
              reaper.ImGui_SetTooltip(ctx, row.locked
                and 'Locked — unlock to regenerate'
                or  'Regenerate with new seed (appends take)')
            end
          end
        end

        reaper.ImGui_EndTable(ctx)
      end
    end
  end

end


M.render         = render_content
M.render_palette = render_palette

return M
