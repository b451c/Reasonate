-- modules/gui/repair_panel.lua
--
-- NS-F: side panel UI for Repair mode. Per PHASE-NS-F.md §UI.
-- Layout single-column (T3 UX-POLISH 2026-07-11: sidebar usunięty — jego
-- funkcje żyją w nagłówku; transkrypt na pełną szerokość):
--   Header: item label + STT/align status + item k/N + Voice + Isolator
--   Transcript (BeginChild scrollable, ~250px h, word chips)
--   Edit mode radio (M1: Replace only; M2: +Insert+Delete)
--   Edit textarea (InputTextMultiline, ~120px h)
--   AI context (scope radio + sees before/after)
--   Voice section (+ override expand)
--   History (M3 placeholder w M1)
--   Action band (Cancel / Preview / Regen)
--
-- Callbacks (z modes/repair.lua):
--   on_select_word(idx, extend), on_unselect(),
--   on_edit_change(text), on_regen_click(), on_preview_click(),
--   on_reset_voice_settings()

local helpers    = require 'modules.reaper_helpers'
local theme      = require 'modules.theme'
local cfg        = require 'modules.config'
local util       = require 'modules.util'
local transcript = require 'modules.transcript'
local preview    = require 'modules.preview'

local M = {}

local TRANSCRIPT_H = 240
local EDIT_AREA_H  = 120
local SCRATCH_PAD  = 12

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------
local function format_status_pill(state)
  if state == 'idle' then return 'idle', theme.COLORS.text_dim end
  if state == 'preparing_isolate' then return 'cleaning audio…', theme.COLORS.status_pending end
  if state == 'transcribing'      then return 'transcribing…',   theme.COLORS.status_pending end
  if state == 'aligning_source'   then return 'aligning words…', theme.COLORS.status_pending end
  if state == 'ready'             then return 'ready',           theme.COLORS.status_done    end
  if state == 'error'             then return 'error',           theme.COLORS.status_error   end
  return state, theme.COLORS.text_dim
end

local function format_regen_status(state, status_text)
  if state == 'idle'         then return nil, nil end
  if state == 'tts'          then return 'TTS generating…',     theme.COLORS.status_pending end
  if state == 'aligning_tts' then return 'Aligning TTS audio…', theme.COLORS.status_pending end
  if state == 'splicing'     then return 'Splicing…',           theme.COLORS.status_pending end
  if state == 'error'        then return 'error',               theme.COLORS.status_error   end
  return status_text or state, theme.COLORS.status_pending
end

-- T3 (UX-POLISH, user decision 2026-07-11): lewy sidebar USUNIĘTY —
-- zajmował 240 px na licznik itemów + warning + 1 checkbox. Wszystko żyje
-- teraz w nagłówku (render_header); transkrypt dostaje pełną szerokość.

----------------------------------------------------------------------------
-- Render header — item label + STT status + Voice resolution.
----------------------------------------------------------------------------
local function render_header(ctx, s, callbacks)
  -- Item label (heading-ish)
  theme.push_heading(ctx)
  reaper.ImGui_TextWrapped(ctx, s.item_label or 'No item selected')
  theme.pop_heading(ctx)

  -- T3: hint dla pustego stanu (przeniesiony z usuniętego sidebara)
  if not s.source_item_guid then
    theme.push_caption(ctx)
    reaper.ImGui_TextDisabled(ctx, 'Click an audio item in the REAPER timeline to start.')
    theme.pop_caption(ctx)
    return
  end

  -- T3: pozycja itemu na tracku + warning długiego audio żyją w nagłówku
  -- (sidebar usunięty — user decision 2026-07-11).
  local item  = helpers.find_item_by_guid(s.source_item_guid)
  local track = item and reaper.GetMediaItemTrack(item)
  local item_pos_str = ''
  local long_audio_min = nil
  if item and track then
    local count = reaper.CountTrackMediaItems(track)
    for i = 0, count - 1 do
      if reaper.GetTrackMediaItem(track, i) == item then
        item_pos_str = (' · item %d/%d'):format(i + 1, count)
        break
      end
    end
    -- Scribe STT może timeoutować dla bardzo długich plików (curl
    -- --max-time 600 = 10 min budget) — warning >25 min.
    local item_len    = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
    local take_active = reaper.GetActiveTake(item)
    local playrate    = take_active
      and (reaper.GetMediaItemTakeInfo_Value(take_active, 'D_PLAYRATE') or 1) or 1
    if playrate <= 0 then playrate = 1 end
    local audio_secs = item_len * playrate
    if audio_secs > 25 * 60 then long_audio_min = audio_secs / 60 end
  end

  -- STT / Align status line
  theme.push_caption(ctx)
  local stt_label, stt_color = format_status_pill(s.stt_state)
  reaper.ImGui_TextDisabled(ctx, 'STT:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
  reaper.ImGui_TextColored(ctx, stt_color, stt_label)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_TextDisabled(ctx, '·')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_TextDisabled(ctx, ('source: %s · %.2fs elapsed%s'):format(
    s.load_source or '?', s.load_elapsed or 0, item_pos_str))
  theme.pop_caption(ctx)

  if long_audio_min then
    theme.push_caption(ctx)
    reaper.ImGui_TextColored(ctx, theme.COLORS.status_stale,
      ('Audio %.0f min — STT may timeout, consider splitting the item.')
        :format(long_audio_min))
    theme.pop_caption(ctx)
  end

  -- M1-4a (audit 2026-06-10): non-fatal degradation warning — forced
  -- alignment failed, splice działa na surowych granicach STT (mniejsza
  -- precyzja cięcia). Wcześniej fallback był całkowicie cichy.
  if s.align_warning then
    theme.push_caption(ctx)
    reaper.ImGui_TextColored(ctx, theme.COLORS.status_stale, '⚠ ' .. s.align_warning)
    theme.pop_caption(ctx)
  end

  -- Voice resolution + change/re-clone controls (M1.5b).
  -- T7: gdy selekcja należy do mówcy z castingiem / zlinkowaną postacią,
  -- pokazujemy EFEKTYWNY głos edycji (ten pójdzie do TTS) zamiast tracka.
  if s.selection_voice or s.voice then
    local v = s.selection_voice or s.voice
    local label, color
    if v.source == 'speaker_cast' then
      label, color = ('Voice: %s · for %s (cast)'):format(
                       v.name ~= '' and v.name or v.voice_id,
                       v.speaker_label or '?'),
                     theme.COLORS.status_done
    elseif v.source == 'cast_registry_auto' then
      label, color = ('Voice: %s · for %s (project cast)'):format(
                       v.name ~= '' and v.name or v.voice_id,
                       v.speaker_label or '?'),
                     theme.COLORS.status_output
    elseif v.source == 'track_voice' then
      label, color = ('Voice: %s · from track casting'):format(v.name or v.voice_id or '?'),
                     theme.COLORS.status_done
    elseif v.source == 'voice_clone' then
      label, color = ('Voice: cloned (%s…)'):format((v.voice_id or ''):sub(1, 8)),
                     theme.COLORS.status_output
    elseif v.source == 'voice_clone_fallback' then
      label, color = ('Voice: %s · library fallback'):format(v.name or v.voice_id or '?'),
                     theme.COLORS.status_output
    elseif v.source == 'needs_clone_confirm' then
      label, color = 'Voice: needs IVC training (confirm before regen)',
                     theme.COLORS.status_new
    elseif v.source == 'cast_registry' then
      -- W2 M3.2 (b): głos zaaplikowany 1-klikiem z propozycji rejestru —
      -- obowiązuje dla bieżącej edycji, track P_EXT nietknięty.
      label, color = ('Voice: %s · from project cast (this edit)'):format(
                       v.name or v.voice_id or '?'),
                     theme.COLORS.status_output
    else
      label, color = 'Voice: not yet assigned', theme.COLORS.status_new
    end
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_TextColored(ctx, color, label)

    -- Voice change / re-clone buttons. Visible zawsze (nawet gdy 'needs_clone_confirm'
    -- — user może pickować library voice zamiast trenować).
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    if theme.button_ghost(ctx, 'Change voice…##rep_change_voice', 0, 0) then
      if callbacks and callbacks.on_change_voice_click then
        callbacks.on_change_voice_click()
      end
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Pick a different voice from your library or favorites.\nOverrides cached clone (sets track voice via casting).')
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    if theme.button_ghost(ctx, 'Re-clone##rep_reclone', 0, 0) then
      if callbacks and callbacks.on_reclone_click then
        callbacks.on_reclone_click()
      end
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Re-train voice clone (IVC) on current source audio.\nUse when the source recording has changed or the cached clone is from a previous recording.')
    end
  else
    reaper.ImGui_TextDisabled(ctx, 'Voice resolution: pending…')
  end

  -- T3: Voice Isolator toggle (NS-C, per-track) — przeniesiony z sidebara
  -- do linii głosu; zmiana flagi resetuje pipeline STT (cleaned audio =
  -- inny input) dokładnie jak dotąd.
  if track then
    local cur = helpers.get_track_isolate_flag(track)
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    local rv, new_val = reaper.ImGui_Checkbox(ctx, 'Voice Isolator##rep_iso', cur)
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Per-track flag — clean audio before STT + voice clone.\nAffects future Repair sessions on this track.')
    end
    if rv and new_val ~= cur then
      helpers.set_track_isolate_flag(track, new_val)
      -- Reset STT state so user can re-trigger transcribe z cleaned audio
      s.stt_state = 'idle'
      s.transcript = nil
      s.source_alignment = nil
      s.words_tbl = nil
      s.visible_words = nil
      s.cleaned_audio_path = nil
      s.isolate_handle = nil
      s.stt_handle = nil
      s.align_handle = nil
      s.sel_first = nil
      s.sel_last = nil
      s.scope = nil
      s.edit_buffer = ''
    end
  end
end

----------------------------------------------------------------------------
-- Render word chip — single word display z selection (per user UX feedback
-- 2026-05-14: per-chip ▶ button usunięty — playerki zaśmiecały strukturę
-- tekstu transkrypcji. Odsłuch przez **prawy klik** na chip → toggle play/stop.)
-- Returns: clicked (bool, left-click only)
----------------------------------------------------------------------------
local function render_word_chip(ctx, s, i, entry, layout)
  local w = entry.word or entry  -- entry could be word_table row (has .word) or words_tbl direct
  local text = entry.text or (w and w.text) or '?'
  local label_id = ('%s##rep_word_%d'):format(text, i)

  local sel_lo = s.sel_first or -1
  local sel_hi = s.sel_last  or sel_lo
  -- M5-4: highlight "AI context" = DOKŁADNIE okno CONTEXT_N_WORDS wokół
  -- selekcji (to, co pipeline regeneruje) — stare pola scope.ctx_* usunięte.
  local ctx_n = layout.context_n or 3
  local in_selection = (i >= sel_lo and i <= sel_hi)
  local in_context   = sel_lo > 0 and not in_selection
    and i >= (sel_lo - ctx_n) and i <= (sel_hi + ctx_n)
  local is_low_conf  = transcript.is_low_confidence(w, -0.5)

  -- Push button colors per state
  local pushed = 0
  if in_selection then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        theme.COLORS.primary)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), theme.COLORS.primary_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  theme.COLORS.primary_active)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          theme.COLORS.text_on_amber)
    pushed = 4
  elseif in_context then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        theme.COLORS.amber_soft)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), theme.COLORS.amber_soft_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  theme.COLORS.amber_soft_active)
    pushed = 3
  elseif is_low_conf then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        theme.COLORS.status_error)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), theme.COLORS.danger_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  theme.COLORS.danger_active)
    pushed = 3
  end

  local shift_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
  local clicked = false
  if reaper.ImGui_SmallButton(ctx, label_id) then
    clicked = true
    if layout.callbacks.on_select_word then
      layout.callbacks.on_select_word(i, shift_held)
    end
  end
  -- W3 Pakiet B+: marker słowa pod playheadem — podkreślenie w akcencie trybu
  -- (lawenda; nie koliduje z kolorami selekcji/kontekstu/low-conf). Rect
  -- czytany OD RAZU po SmallButton (tooltip niżej nadpisuje last-item data).
  if i == s.playhead_word_idx then
    local x1, _  = reaper.ImGui_GetItemRectMin(ctx)
    local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddLine(dl, x1 + 1, y2 - 1, x2 - 1, y2 - 1,
      theme.MODE_ACCENTS.repair, 2.0)
    if s.playhead_scroll_pending then
      reaper.ImGui_SetScrollHereY(ctx, 0.35)
      s.playhead_scroll_pending = nil
    end
  end
  -- Search highlight (user 2026-07-11): trafienie = ramka amber; bieżące
  -- trafienie (< > nav) = mocniejsza ramka primary + one-shot scroll.
  if layout.search_lc and layout.search_lc ~= ''
     and text:lower():find(layout.search_lc, 1, true) then
    local x1, y1 = reaper.ImGui_GetItemRectMin(ctx)
    local x2, y2 = reaper.ImGui_GetItemRectMax(ctx)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local focused = (i == s.search_focus_idx)
    reaper.ImGui_DrawList_AddRect(dl, x1, y1, x2, y2,
      focused and theme.COLORS.primary or theme.COLORS.status_stale,
      3.0, 0, focused and 2.0 or 1.0)
    if focused and s.search_scroll_pending then
      reaper.ImGui_SetScrollHereY(ctx, 0.35)
      s.search_scroll_pending = nil
    end
  end
  -- Right-click → toggle play/stop dla tego słowa (D9 — replaces ▶ button).
  -- IsItemClicked(ctx, 1) = right mouse button; references last item (= chip).
  if reaper.ImGui_IsItemClicked(ctx, 1) and layout.source_path then
    local preview_id = 'rep_preview_' .. i
    if preview and preview.is_playing and preview.is_playing(preview_id) then
      if preview.stop then preview.stop() end
    else
      local s_sec = tonumber(entry.start) or (w and tonumber(w.start)) or 0
      local e_sec = tonumber(entry['end']) or (w and tonumber(w['end'])) or s_sec
      if e_sec > s_sec then
        local pad = 0.030   -- AD7 padding maskuje plosive release
        preview.play_file_range(layout.source_path,
          math.max(0, s_sec - pad), e_sec + pad,
          preview_id)
      end
    end
  end
  -- Tooltip z time + logprob + hint (updated dla right-click pattern).
  -- M0-3: EndTooltip TYLKO gdy Begin zwrócił true (inv #6 — bezwarunkowy
  -- End po false-return = double-pop assert).
  if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_BeginTooltip(ctx) then
    local s_sec = tonumber(entry.start) or (w and tonumber(w.start)) or 0
    local e_sec = tonumber(entry['end']) or (w and tonumber(w['end'])) or 0
    local logprob = (w and tonumber(w.logprob)) or 0
    reaper.ImGui_Text(ctx, ('%s\n%s — %s · logprob=%.3f%s'):format(
      text,
      transcript.format_time(s_sec),
      transcript.format_time(e_sec),
      logprob,
      entry.aligned and '\naligned' or ''))
    reaper.ImGui_TextDisabled(ctx,
      'click: select word  ·  Shift+click: extend range  ·  right-click: play this word')
    reaper.ImGui_EndTooltip(ctx)
  end
  if pushed > 0 then reaper.ImGui_PopStyleColor(ctx, pushed) end

  return clicked
end

----------------------------------------------------------------------------
-- Render insert-cursor marker (▎ in primary color, inline z chipsami).
----------------------------------------------------------------------------
local function render_insert_cursor_marker(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextColored(ctx, theme.COLORS.primary, '▎')
end

----------------------------------------------------------------------------
-- NS-G: speaker tabs nad chip flow. Tabs: [Wszyscy] [Speaker 1 · N] [Speaker 2 · N].
-- Right-click na zakładce speakera → popup rename (custom label persistuje
-- w P_EXT na itemie). 1 speaker lub brak diarize → tabs hidden (graceful
-- fallback, no UI clutter).
----------------------------------------------------------------------------
local function render_speaker_tabs(ctx, s, callbacks)
  local speakers = s.speakers or {}
  if #speakers < 2 then return end

  if not reaper.ImGui_BeginTabBar(ctx, '##rep_speaker_tabs') then return end

  local detected = nil

  -- "All" tab — default selected (chronological view)
  local all_total = 0
  for _, spk in ipairs(speakers) do all_total = all_total + spk.word_count end
  if reaper.ImGui_BeginTabItem(ctx, ('All · %d##rep_tab_all'):format(all_total)) then
    detected = 'all'
    reaper.ImGui_EndTabItem(ctx)
  end

  -- Per-speaker tabs + right-click rename popup
  for _, spk in ipairs(speakers) do
    local tab_label = ('%s · %d##rep_tab_%s'):format(spk.label, spk.word_count, spk.id)
    if reaper.ImGui_BeginTabItem(ctx, tab_label) then
      detected = spk.id
      reaper.ImGui_EndTabItem(ctx)
    end
    -- Right-click context menu na ostatnim TabItemie (rename)
    local ctx_id = 'rep_tab_ctx_' .. spk.id
    if reaper.ImGui_BeginPopupContextItem(ctx, ctx_id) then
      -- Init buffer pri pierwszym otwarciu tej popup-instance
      if not s.speaker_rename_pending or s.speaker_rename_pending.sid ~= spk.id then
        s.speaker_rename_pending = { sid = spk.id, buffer = spk.label or '' }
      end
      reaper.ImGui_Text(ctx, 'Rename speaker (' .. spk.id .. '):')
      reaper.ImGui_SetNextItemWidth(ctx, 220)
      local rv, new_buf = reaper.ImGui_InputText(ctx, '##spk_rename_input',
        s.speaker_rename_pending.buffer or '')
      if rv then s.speaker_rename_pending.buffer = new_buf end
      reaper.ImGui_Spacing(ctx)
      if theme.button_primary(ctx, 'Save##spk_rename_save') then
        if callbacks.on_rename_speaker then
          callbacks.on_rename_speaker(spk.id, s.speaker_rename_pending.buffer or '')
        end
        s.speaker_rename_pending = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_SameLine(ctx)
      if theme.button_neutral(ctx, 'Reset to default##spk_rename_reset') then
        if callbacks.on_rename_speaker then
          callbacks.on_rename_speaker(spk.id, '')   -- empty → revert do default
        end
        s.speaker_rename_pending = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_SameLine(ctx)
      if theme.button_neutral(ctx, 'Cancel##spk_rename_cancel') then
        s.speaker_rename_pending = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      end

      -- T7 (UX-POLISH): casting mówcy — zakładka jest powierzchnią obsady.
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      local pv = s.speaker_voices and s.speaker_voices[spk.id]
      theme.push_caption(ctx)
      if pv and pv.voice_id and pv.voice_id ~= '' then
        reaper.ImGui_TextColored(ctx, theme.COLORS.status_done,
          ('Voice: %s'):format(pv.voice_name ~= '' and pv.voice_name or pv.voice_id))
      else
        reaper.ImGui_TextDisabled(ctx, 'Voice: not cast (uses track voice)')
      end
      theme.pop_caption(ctx)
      if reaper.ImGui_Selectable(ctx, 'Assign voice\xe2\x80\xa6##spk_assign_' .. spk.id, false) then
        if callbacks.on_assign_voice_click then callbacks.on_assign_voice_click(spk.id) end
      end
      if reaper.ImGui_Selectable(ctx, 'Train clone\xe2\x80\xa6##spk_clone_' .. spk.id, false) then
        if callbacks.on_train_clone_speaker then callbacks.on_train_clone_speaker(spk.id) end
      end
      if pv and pv.voice_id and pv.voice_id ~= '' then
        if reaper.ImGui_Selectable(ctx, 'Clear cast voice##spk_clearv_' .. spk.id, false) then
          if callbacks.on_clear_speaker_voice then callbacks.on_clear_speaker_voice(spk.id) end
        end
      end
      reaper.ImGui_EndPopup(ctx)
    end
  end

  reaper.ImGui_EndTabBar(ctx)

  -- Tooltip hint
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
  theme.push_caption(ctx)
  reaper.ImGui_Text(ctx, '(right-click a speaker tab to rename or cast a voice)')
  theme.pop_caption(ctx)
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- Sync state z user click
  if detected and detected ~= s.active_speaker_tab then
    if callbacks.on_speaker_tab_change then
      callbacks.on_speaker_tab_change(detected)
    end
  end
end

----------------------------------------------------------------------------
-- T7 (UX-POLISH): modal "Cast voices" — wiersz per mówca: Name | ▶ próbka
-- (najdłuższy run, cap 5 s) | głos | Train clone. Wybór głosu idzie przez
-- voice_picker (osobne okno) — modal ZAMYKA się przed otwarciem pickera
-- (zagnieżdżony modal blokowałby input) i wraca po wyborze
-- (s.cast_modal_reopen_after_pick konsumowane w on_pick).
----------------------------------------------------------------------------
local function render_cast_voices_modal(ctx, s, callbacks, source_path)
  if s.cast_modal_pending_open then
    reaper.ImGui_OpenPopup(ctx, 'Cast voices')
    s.cast_modal_pending_open = false
    s.cast_modal_names = nil
  end
  theme.center_next_modal(ctx, 620, 0)
  theme.popup_keep_top(ctx, 'Cast voices')
  local visible = reaper.ImGui_BeginPopupModal(ctx, 'Cast voices', true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end

  if not s.cast_modal_names then
    s.cast_modal_names = {}
    for _, spk in ipairs(s.speakers or {}) do
      s.cast_modal_names[spk.id] =
        (s.speaker_labels and s.speaker_labels[spk.id]) or ''
    end
  end

  -- Commit zmian nazw (rename → registry link) — przy Done i przed akcjami.
  local function commit_names()
    for _, spk in ipairs(s.speakers or {}) do
      local buf = s.cast_modal_names and s.cast_modal_names[spk.id]
      local cur = (s.speaker_labels and s.speaker_labels[spk.id]) or ''
      if buf ~= nil and buf ~= cur and callbacks.on_rename_speaker then
        callbacks.on_rename_speaker(spk.id, buf)
      end
    end
  end

  reaper.ImGui_TextWrapped(ctx,
    'Assign a voice per detected speaker — edits inside a speaker then use their voice automatically. Naming a speaker also saves the pairing to the project cast (visible in Dubbing and TTS).')
  reaper.ImGui_Spacing(ctx)

  if reaper.ImGui_BeginTable(ctx, '##rep_cast_tbl', 4,
       reaper.ImGui_TableFlags_RowBg() | reaper.ImGui_TableFlags_BordersInnerH()) then
    reaper.ImGui_TableSetupColumn(ctx, 'Name (optional)',
      reaper.ImGui_TableColumnFlags_WidthFixed(), 170)
    reaper.ImGui_TableSetupColumn(ctx, '',
      reaper.ImGui_TableColumnFlags_WidthFixed(), 30)
    reaper.ImGui_TableSetupColumn(ctx, 'Voice')
    reaper.ImGui_TableSetupColumn(ctx, '',
      reaper.ImGui_TableColumnFlags_WidthFixed(), 100)
    reaper.ImGui_TableHeadersRow(ctx)
    for _, spk in ipairs(s.speakers or {}) do
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, -1)
      local rv_n, new_n = reaper.ImGui_InputText(ctx,
        '##cast_name_' .. spk.id, s.cast_modal_names[spk.id] or '')
      if rv_n then s.cast_modal_names[spk.id] = new_n end
      if reaper.ImGui_IsItemHovered(ctx)
         and (s.cast_modal_names[spk.id] or '') == '' then
        reaper.ImGui_SetTooltip(ctx,
          ('Default: %s. Naming shares this speaker with Dubbing/TTS.')
            :format(spk.label))
      end

      reaper.ImGui_TableNextColumn(ctx)
      local pid = 'rep_cast_pv_' .. spk.id
      local playing = preview.is_playing(pid)
      local pv_label = (playing and '\xe2\x96\xa0' or '\xe2\x96\xb6')
        .. '##cast_play_' .. spk.id
      if reaper.ImGui_SmallButton(ctx, pv_label) then
        if playing then
          preview.stop()
        elseif callbacks.speaker_sample_range and source_path then
          local a, b = callbacks.speaker_sample_range(spk.id)
          if a then preview.play_file_range(source_path, a, b, pid) end
        end
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, playing and 'Stop'
          or 'Play a sample of this speaker (longest run, max 5 s)')
      end

      reaper.ImGui_TableNextColumn(ctx)
      local pv = s.speaker_voices and s.speaker_voices[spk.id]
      local v_label = (pv and pv.voice_id and pv.voice_id ~= '')
        and ((pv.voice_name ~= '' and pv.voice_name) or pv.voice_id)
        or 'Pick voice\xe2\x80\xa6'
      if theme.button_neutral(ctx, v_label .. '##cast_pick_' .. spk.id, -1, 0) then
        commit_names()
        s.cast_modal_reopen_after_pick = true
        reaper.ImGui_CloseCurrentPopup(ctx)
        if callbacks.on_assign_voice_click then
          callbacks.on_assign_voice_click(spk.id)
        end
      end

      reaper.ImGui_TableNextColumn(ctx)
      if reaper.ImGui_SmallButton(ctx, 'Train clone##cast_clone_' .. spk.id) then
        commit_names()
        reaper.ImGui_CloseCurrentPopup(ctx)
        if callbacks.on_train_clone_speaker then
          callbacks.on_train_clone_speaker(spk.id)
        end
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          "Train an instant voice clone from this speaker's audio (paid, uses a voice slot).")
      end
    end
    reaper.ImGui_EndTable(ctx)
  end

  reaper.ImGui_Spacing(ctx)
  if theme.button_primary(ctx, 'Done##cast_done') then
    commit_names()
    s.cast_modal_names = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

----------------------------------------------------------------------------
-- Render word chips in a wrapping flow inside BeginChild scrollable area.
-- M2: Insert mode renders cursor marker BEFORE chip when s.cursor_idx == i-1,
-- AND po ostatnim chipie pokazuje [↑ Insert at end] button + marker gdy
-- cursor_idx == N (cursor po wszystkich słowach).
----------------------------------------------------------------------------
local function render_transcript_chips(ctx, s, callbacks, source_path)
  if not s.visible_words or #s.visible_words == 0 then
    theme.push_caption(ctx)
    reaper.ImGui_TextDisabled(ctx, '(no words detected yet — waiting for STT)')
    theme.pop_caption(ctx)
    return
  end

  local layout = {
    callbacks   = callbacks,
    source_path = source_path,
    -- M5-4: okno kontekstu do highlightu chipów = stała pipeline'u.
    context_n   = callbacks.context_n_words or 3,
  }

  local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  if avail <= 0 then avail = 600 end
  local x_used = 0
  local CHIP_PAD = 10
  local insert_mode = (s.edit_mode == 'insert')
  local cursor_idx = s.cursor_idx
  local CURSOR_W = 16   -- approx render width of '▎' marker

  -- Search = HIGHLIGHT, nie filtr (user 2026-07-11): wszystkie słowa
  -- widoczne (pełny kontekst), trafienia oznaczone ramką w render_word_chip,
  -- bieżące trafienie (< > nav) mocniejszą ramką + one-shot scroll.
  local search_lc = ''
  if s.transcript_search and s.transcript_search ~= '' then
    search_lc = s.transcript_search:lower():gsub('^%s+', ''):gsub('%s+$', '')
  end
  layout.search_lc = search_lc

  -- NS-G: speaker tab filter (active speaker_id z s.active_speaker_tab; 'all'
  -- = no filter). Skip chip jeśli word.speaker_id ≠ active. Words bez
  -- speaker_id (pre-diarize cached STT) pass through tylko gdy active='all'.
  local speaker_filter = (s.active_speaker_tab and s.active_speaker_tab ~= 'all')
    and s.active_speaker_tab or nil

  for i, entry in ipairs(s.visible_words) do
    local text = entry.text or (entry.word and entry.word.text) or '?'
    -- Skip chip if doesn't match speaker tab filter
    if speaker_filter then
      local w_spk = entry.word and (entry.word.speaker_id or entry.word.speaker)
      if w_spk ~= speaker_filter then
        goto continue_chip
      end
    end
    -- Estimate chip width: text width + play button width + paddings
    -- ImGui doesn't give exact pre-render width — approximate.
    local chip_w = math.max(44, #text * 8 + CHIP_PAD * 2)  -- right-click play, no extra ▶
    -- W Insert mode: cursor before this chip dodaje width
    local extra_w = (insert_mode and cursor_idx == (i - 1)) and CURSOR_W or 0
    if x_used > 0 and x_used + chip_w + extra_w > avail - 8 then
      reaper.ImGui_NewLine(ctx)
      x_used = 0
    end
    if x_used > 0 then
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    end
    -- Cursor marker BEFORE chip i (cursor_idx == i-1)
    if insert_mode and cursor_idx == (i - 1) then
      render_insert_cursor_marker(ctx)
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
      x_used = x_used + CURSOR_W + theme.SPACING.xs
    end
    render_word_chip(ctx, s, i, entry, layout)
    x_used = x_used + chip_w + theme.SPACING.xs
    ::continue_chip::
  end

  -- Po ostatnim chipie: w Insert mode pokazuje cursor marker (gdy cursor==N) + "Insert at end" button
  if insert_mode then
    local n = #s.visible_words
    if x_used > 0 then
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    end
    if cursor_idx == n then
      render_insert_cursor_marker(ctx)
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    end
    if theme.button_ghost(ctx, '↑ Insert at end##rep_ins_end', 0, 0) then
      if callbacks.on_set_cursor_end then callbacks.on_set_cursor_end() end
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Place cursor after the last word (append speech at the end of item).')
    end
  end

  -- M5-9b (user decision 2026-07-11: warning, nie restrykcja): shift+click
  -- przy aktywnym filtrze mówcy może objąć słowa UKRYTE przez filtr —
  -- ostrzeż zanim edycja podmieni coś, czego user nie widzi.
  if speaker_filter and s.sel_first and s.sel_last then
    local hidden = 0
    for i = s.sel_first, s.sel_last do
      local e = s.visible_words[i]
      local w_spk = e and e.word and (e.word.speaker_id or e.word.speaker)
      if w_spk ~= speaker_filter then hidden = hidden + 1 end
    end
    if hidden > 0 then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
      reaper.ImGui_TextWrapped(ctx,
        ('Warning: selection spans %d word(s) hidden by the speaker filter — the edit would replace them too. Switch the filter to "All" to review the full range.')
          :format(hidden))
      reaper.ImGui_PopStyleColor(ctx, 1)
    end
  end

  -- Guard wielu mówców w zaznaczeniu (user 2026-07-11): poprawka jest
  -- generowana JEDNYM głosem — zakres przez kilku mówców to niemal zawsze
  -- pomyłka zaznaczenia (spójnie z M5-9b: warning, nie blokada).
  if s.sel_first and s.sel_last and s.sel_last > s.sel_first then
    local seen_spk, n_spk = {}, 0
    for i = s.sel_first, s.sel_last do
      local e = s.visible_words[i]
      local sp = e and e.word and (e.word.speaker_id or e.word.speaker)
      if sp and not seen_spk[sp] then
        seen_spk[sp] = true
        n_spk = n_spk + 1
      end
    end
    if n_spk > 1 then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
      reaper.ImGui_TextWrapped(ctx,
        ('Warning: selection spans %d different speakers — the patch is generated with ONE voice. Edit each speaker\'s words separately for a clean result.')
          :format(n_spk))
      reaper.ImGui_PopStyleColor(ctx, 1)
      -- W2 M3 (c-lite): 1-klik przycięcie selekcji do pierwszego mówcy.
      if theme.button_neutral(ctx, 'Split at speaker boundary##rep_split_spk', 0, 0) then
        if callbacks.on_split_selection_at_speaker then
          callbacks.on_split_selection_at_speaker()
        end
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          "Trim the selection to the first speaker's words.\nApply that edit, then select the remaining words — each edit gets its own speaker's voice.")
      end
    end
  end

  -- W2 M3 (c-lite): hint po przycięciu — co zostało do zrobienia drugim głosem.
  local hint = s.split_rest_hint
  if hint and s.sel_first and s.sel_last then
    reaper.ImGui_Spacing(ctx)
    theme.push_caption(ctx)
    reaper.ImGui_TextColored(ctx, theme.COLORS.text_dim,
      ("Selection trimmed to %s's words. Apply this edit, then select the remaining words (%s) and repeat — the voice suggestion will follow.")
        :format(tostring(hint.first), tostring(hint.rest)))
    theme.pop_caption(ctx)
  end

  -- W2 M3.2 (b): propozycja właściwego głosu z Cast Registry — selekcja
  -- w całości jednym mówcą, którego postać ma inny głos niż bieżący.
  -- Aplikuje się TYLKO do tej edycji (track P_EXT nietknięty).
  local sug = s.voice_suggestion
  if sug and s.sel_first and s.sel_last then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_output)
    reaper.ImGui_TextWrapped(ctx,
      ('Selected words are spoken by %s — the current voice belongs to someone else.')
        :format(sug.label))
    reaper.ImGui_PopStyleColor(ctx, 1)
    if theme.button_neutral(ctx,
         ("Use %s's voice##rep_use_sug"):format(sug.label), 0, 0) then
      if callbacks.on_use_suggested_voice then callbacks.on_use_suggested_voice() end
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        ('Applies "%s" to this edit only — the track voice assignment is not changed.')
          :format(sug.voice_name or sug.label))
    end
  end
end

----------------------------------------------------------------------------
-- Render mode toggle (Replace / Insert / Delete) — always rendered above body.
-- W3 (2026-06-11): radio → theme.segmented sm (akcent Repair, mirror paska
-- trybów). on_mode_change odpala się tylko przy realnej zmianie (segmented
-- zwraca nil dla kliku w aktywny segment).
----------------------------------------------------------------------------
local EDIT_MODE_ITEMS = {
  { key = 'replace', label = 'Replace' },
  { key = 'insert',  label = 'Insert' },
  { key = 'delete',  label = 'Delete' },
}

local function render_mode_radio(ctx, s, callbacks)
  local clicked = theme.segmented(ctx, 'repair_edit_mode', EDIT_MODE_ITEMS,
    s.edit_mode, { size = 'sm', accent = theme.MODE_ACCENTS.repair })
  if clicked and callbacks.on_mode_change then
    callbacks.on_mode_change(clicked)
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  -- +6px: optyczne wycentrowanie caption (11px) względem railu 24px.
  reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + 6)
  theme.push_caption(ctx)
  reaper.ImGui_TextDisabled(ctx, 'Tab cycles modes')
  theme.pop_caption(ctx)
end

----------------------------------------------------------------------------
-- Trim helpers (used by both Replace + Insert bodies dla AI context preview)
----------------------------------------------------------------------------
local function trim_tail_pretty(t, n)
  if #t <= n then return t end
  return '…' .. t:sub(-n)
end

local function trim_head_pretty(t, n)
  if #t <= n then return t end
  return t:sub(1, n) .. '…'
end

----------------------------------------------------------------------------
-- Replace body — selection-based UI (M1 flow preserved).
----------------------------------------------------------------------------
local function render_replace_body(ctx, s, callbacks)
  if not s.sel_first or not s.scope then
    theme.push_caption(ctx)
    reaper.ImGui_TextDisabled(ctx,
      'Click a word above to select. Shift+click to extend range.')
    theme.pop_caption(ctx)
    return
  end

  local sc = s.scope
  local n_sel = sc.sel_last - sc.sel_first + 1

  -- Selection summary
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextColored(ctx, theme.COLORS.primary,
    ('Replacing %d word%s'):format(n_sel, n_sel == 1 and '' or 's'))
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  theme.push_caption(ctx)
  reaper.ImGui_TextDisabled(ctx, ('· %s — %s · %s · ~$%.4f'):format(
    transcript.format_time(sc.audio_start),
    transcript.format_time(sc.audio_end),
    transcript.format_time(sc.audio_end - sc.audio_start),
    transcript.estimate_tts_cost(s.edit_buffer or '')))
  theme.pop_caption(ctx)

  -- Edit textarea
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Replacement text:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if theme.button_ghost(ctx, 'Reset to original##rep_reset', 0, 0) then
    s.edit_buffer = sc.selected_text
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  theme.push_caption(ctx)
  -- M5-4: rozmiar okna z pipeline'u (modes/repair CONTEXT_N_WORDS) — opis
  -- i highlight mówią DOKŁADNIE to, co program robi (był rozjazd 2 vs 3).
  local CONTEXT_N = callbacks.context_n_words or 3
  reaper.ImGui_TextDisabled(ctx,
    ('TTS regenerates %d words before + replacement + %d words after — smooth prosody blend')
      :format(CONTEXT_N, CONTEXT_N))
  theme.pop_caption(ctx)
  local rv, new_text = reaper.ImGui_InputTextMultiline(ctx, '##rep_edit_buf',
    s.edit_buffer or '', -1, EDIT_AREA_H)
  if rv then
    s.edit_buffer = new_text
    if callbacks.on_edit_change then callbacks.on_edit_change(new_text) end
  end

  -- Show actual context regen window (CONTEXT_N words around selection)
  local words = s.words_tbl or s.visible_words or {}
  local n_words = #words
  local ctx_before_lo = math.max(1, sc.sel_first - CONTEXT_N)
  local ctx_before_hi = sc.sel_first - 1
  local ctx_after_lo  = sc.sel_last + 1
  local ctx_after_hi  = math.min(n_words, sc.sel_last + CONTEXT_N)
  local before_parts, after_parts = {}, {}
  for i = ctx_before_lo, ctx_before_hi do
    local w = words[i]
    local t = w and (w.text or (w.word and w.word.text)) or ''
    if t ~= '' then before_parts[#before_parts + 1] = t end
  end
  for i = ctx_after_lo, ctx_after_hi do
    local w = words[i]
    local t = w and (w.text or (w.word and w.word.text)) or ''
    if t ~= '' then after_parts[#after_parts + 1] = t end
  end
  local context_before = table.concat(before_parts, ' ')
  local context_after  = table.concat(after_parts, ' ')
  if context_before ~= '' or context_after ~= '' then
    theme.push_caption(ctx)
    if context_before ~= '' then
      reaper.ImGui_TextDisabled(ctx, 'Regenerate before: ' .. trim_tail_pretty(context_before, 60))
    end
    if context_after ~= '' then
      reaper.ImGui_TextDisabled(ctx, 'Regenerate after:  ' .. trim_head_pretty(context_after, 60))
    end
    theme.pop_caption(ctx)
  end
end

----------------------------------------------------------------------------
-- Insert body — cursor-based UI. Cursor sits BETWEEN chips (0..N).
----------------------------------------------------------------------------
local function render_insert_body(ctx, s, callbacks)
  if s.cursor_idx == nil then
    theme.push_caption(ctx)
    reaper.ImGui_TextDisabled(ctx,
      'Click a word above to place cursor BEFORE it. Click [Insert at end] for last position.')
    reaper.ImGui_TextDisabled(ctx,
      '←/→ moves cursor word-by-word. Tab cycles modes.')
    theme.pop_caption(ctx)
    return
  end

  local words = s.words_tbl or s.visible_words or {}
  local n = #words
  local idx = math.max(0, math.min(s.cursor_idx, n))

  -- Cursor position label
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextColored(ctx, theme.COLORS.primary,
    ('Insert at position %d / %d'):format(idx, n))
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  theme.push_caption(ctx)
  local position_hint
  if idx == 0 then
    local first_w = words[1]
    local first_t = first_w and (first_w.text or (first_w.word and first_w.word.text)) or '?'
    position_hint = ('before "%s"'):format(first_t)
  elseif idx == n then
    position_hint = '(end of transcript)'
  else
    local prev_w = words[idx]
    local next_w = words[idx + 1]
    local prev_t = prev_w and (prev_w.text or (prev_w.word and prev_w.word.text)) or '?'
    local next_t = next_w and (next_w.text or (next_w.word and next_w.word.text)) or '?'
    position_hint = ('between "%s" and "%s"'):format(prev_t, next_t)
  end
  reaper.ImGui_TextDisabled(ctx, '· ' .. position_hint ..
    (' · ~$%.4f'):format(transcript.estimate_tts_cost(s.edit_buffer or '')))
  theme.pop_caption(ctx)

  reaper.ImGui_Spacing(ctx)

  -- Edit textarea
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Text to insert:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  theme.push_caption(ctx)
  -- M5-4: rozmiar okna z pipeline'u (jedno źródło z modes/repair).
  local CONTEXT_N = callbacks.context_n_words or 3
  reaper.ImGui_TextDisabled(ctx,
    ('TTS regenerates %d words before + your insert + %d words after — smooth prosody blend')
      :format(CONTEXT_N, CONTEXT_N))
  theme.pop_caption(ctx)

  local rv, new_text = reaper.ImGui_InputTextMultiline(ctx, '##rep_edit_buf_ins',
    s.edit_buffer or '', -1, EDIT_AREA_H)
  if rv then
    s.edit_buffer = new_text
    if callbacks.on_edit_change then callbacks.on_edit_change(new_text) end
  end

  -- Show context window (CONTEXT_N words REGENERATED on each side, + prosody hint outside)
  local ctx_before_lo = math.max(1, idx - CONTEXT_N + 1)
  local ctx_before_hi = idx
  local ctx_after_lo  = idx + 1
  local ctx_after_hi  = math.min(n, idx + CONTEXT_N)
  local before_parts, after_parts = {}, {}
  for i = ctx_before_lo, ctx_before_hi do
    local w = words[i]
    local t = w and (w.text or (w.word and w.word.text)) or ''
    if t ~= '' then before_parts[#before_parts + 1] = t end
  end
  for i = ctx_after_lo, ctx_after_hi do
    local w = words[i]
    local t = w and (w.text or (w.word and w.word.text)) or ''
    if t ~= '' then after_parts[#after_parts + 1] = t end
  end
  local context_before = table.concat(before_parts, ' ')
  local context_after  = table.concat(after_parts, ' ')

  if context_before ~= '' or context_after ~= '' then
    theme.push_caption(ctx)
    if context_before ~= '' then
      reaper.ImGui_TextDisabled(ctx, 'Regenerate before: ' .. trim_tail_pretty(context_before, 60))
    end
    if context_after ~= '' then
      reaper.ImGui_TextDisabled(ctx, 'Regenerate after:  ' .. trim_head_pretty(context_after, 60))
    end
    theme.pop_caption(ctx)
  end
end

----------------------------------------------------------------------------
-- Delete body — selection-based UI (mirrors Replace selection collection, but
-- no edit_buffer; action = remove selected audio + close gap).
----------------------------------------------------------------------------
local function render_delete_body(ctx, s, callbacks)
  if not s.sel_first or not s.scope then
    theme.push_caption(ctx)
    reaper.ImGui_TextDisabled(ctx,
      'Click a word above to mark for deletion. Shift+click to extend range.')
    reaper.ImGui_TextDisabled(ctx,
      'Then press Backspace, Delete, or click [Delete N words].')
    theme.pop_caption(ctx)
    return
  end

  local sc = s.scope
  local n_sel = sc.sel_last - sc.sel_first + 1

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextColored(ctx, theme.COLORS.status_error,
    ('Deleting %d word%s'):format(n_sel, n_sel == 1 and '' or 's'))
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  theme.push_caption(ctx)
  reaper.ImGui_TextDisabled(ctx, ('· %s — %s · %s'):format(
    transcript.format_time(sc.audio_start),
    transcript.format_time(sc.audio_end),
    transcript.format_time(sc.audio_end - sc.audio_start)))
  theme.pop_caption(ctx)

  reaper.ImGui_Spacing(ctx)
  theme.push_caption(ctx)
  reaper.ImGui_TextDisabled(ctx, 'Text to remove:')
  reaper.ImGui_TextWrapped(ctx, '"' .. (sc.selected_text or '') .. '"')
  local del_ctx_n = callbacks.context_n_words or 3
  reaper.ImGui_TextDisabled(ctx,
    ('TTS regenerates %d surrounding words (%d before + %d after) for smooth prosody blending.')
      :format(del_ctx_n * 2, del_ctx_n, del_ctx_n))
  reaper.ImGui_TextDisabled(ctx,
    'Adjacent words connect naturally (punctuation + dynamics). Items downstream shift left.')
  theme.pop_caption(ctx)
end

----------------------------------------------------------------------------
-- Render edit panel: mode radio + per-mode body dispatch.
----------------------------------------------------------------------------
local function render_edit_area(ctx, s, callbacks)
  render_mode_radio(ctx, s, callbacks)
  reaper.ImGui_Spacing(ctx)
  if s.edit_mode == 'insert' then
    render_insert_body(ctx, s, callbacks)
  elseif s.edit_mode == 'delete' then
    render_delete_body(ctx, s, callbacks)
  else
    render_replace_body(ctx, s, callbacks)
  end
end

----------------------------------------------------------------------------
-- Voice settings override panel (mirror Phase 11 NS-4 pattern, collapsible)
----------------------------------------------------------------------------
local function render_voice_settings(ctx, s, callbacks)
  local indicator = s.vs_expanded and '[-]' or '[+]'
  local status_text = s.vs_override_active
    and 'per-repair override active'
    or  'using track defaults'
  local label = ('%s Voice settings (%s)##rep_vs_toggle'):format(indicator, status_text)
  if theme.button_ghost(ctx, label, 0, 0) then
    s.vs_expanded = not s.vs_expanded
  end
  if not s.vs_expanded then return end

  -- Pre-fill sliders z track effective on first expand
  if not s.vs_settings_init then
    local item = helpers.find_item_by_guid(s.source_item_guid)
    if item then
      local track = reaper.GetMediaItemTrack(item)
      if track then
        local eff = helpers.effective_voice_settings(track)
        s.vs_settings.stability         = eff.stability
        s.vs_settings.similarity_boost  = eff.similarity_boost
        s.vs_settings.style             = eff.style
        s.vs_settings.use_speaker_boost = eff.use_speaker_boost
        s.vs_settings.speed             = eff.speed or 1.0
        s.vs_settings_init = true
      end
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Indent(ctx, theme.SPACING.md)

  reaper.ImGui_Text(ctx, 'Stability')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local rv, v = reaper.ImGui_SliderDouble(ctx, '##rep_vs_stab',
    s.vs_settings.stability, 0.0, 1.0, '%.2f')
  if rv then s.vs_settings.stability = v; s.vs_override_active = true end

  reaper.ImGui_Text(ctx, 'Similarity boost')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  rv, v = reaper.ImGui_SliderDouble(ctx, '##rep_vs_sim',
    s.vs_settings.similarity_boost, 0.0, 1.0, '%.2f')
  if rv then s.vs_settings.similarity_boost = v; s.vs_override_active = true end

  reaper.ImGui_Text(ctx, 'Style')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  rv, v = reaper.ImGui_SliderDouble(ctx, '##rep_vs_style',
    s.vs_settings.style, 0.0, 1.0, '%.2f')
  if rv then s.vs_settings.style = v; s.vs_override_active = true end

  -- Auto-match speaker pace (M2 v3.1) — gdy ON, slider speed jest read-only
  -- z displayed last-applied auto value. Od 2026-06-10: flaga trwała w
  -- ExtState (default OFF — natural pacing), mirror w Settings → Repair.
  local match_pace = cfg.get_repair_match_pace()
  local mp_rv, mp_v = reaper.ImGui_Checkbox(ctx,
    'Auto-match speaker pace##rep_match_pace', match_pace)
  if mp_rv then
    cfg.set_repair_match_pace(mp_v)
    match_pace = mp_v
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'OFF (default): the voice and surrounding text decide the pacing — ' ..
      'set Speed below manually if needed.\n\n' ..
      'ON: analyzes the source recording tempo and auto-sets speed to match ' ..
      '(per-voice baseline learned from your edits; may re-render once and ' ..
      'gently time-stretch at the speed floor).\n\n' ..
      'Saved globally — also in Settings → Repair.')
  end

  reaper.ImGui_Text(ctx, 'Speed')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  -- Gdy match_pace ON: slider read-only + pokazuje ostatni auto-applied speed
  -- Gdy OFF: slider editable, value = s.vs_settings.speed
  local display_speed = s.vs_settings.speed or 1.0
  if match_pace then
    display_speed = s.last_applied_pace_speed or 1.0
  end
  reaper.ImGui_BeginDisabled(ctx, match_pace)
  rv, v = reaper.ImGui_SliderDouble(ctx, '##rep_vs_speed',
    display_speed, 0.7, 1.2,
    match_pace and '%.2fx (auto)' or '%.2fx')
  reaper.ImGui_EndDisabled(ctx)
  if rv and not match_pace then
    s.vs_settings.speed = v; s.vs_override_active = true
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    if match_pace then
      reaper.ImGui_SetTooltip(ctx,
        'Auto-applied speed = source pace ÷ TTS baseline (clamped 0.7-1.2). ' ..
        'Last value shown. Uncheck "Auto-match" above for manual control.')
    else
      reaper.ImGui_SetTooltip(ctx,
        'ElevenLabs voice_settings.speed. 1.0 = native pace. ' ..
        '<1.0 slower, >1.0 faster. Safe range 0.7-1.2 (extreme values may ' ..
        'degrade quality). Multilingual v2 + Turbo support speed; Flash bypasses it.')
    end
  end

  local cb_rv, cb_v = reaper.ImGui_Checkbox(ctx, 'Use speaker boost##rep_vs_sb',
    s.vs_settings.use_speaker_boost)
  if cb_rv then s.vs_settings.use_speaker_boost = cb_v; s.vs_override_active = true end

  if s.vs_override_active then
    reaper.ImGui_Spacing(ctx)
    if theme.button_ghost(ctx, 'Reset to track defaults##rep_vs_reset', 0, 0) then
      s.vs_override_active = false
      s.vs_settings_init   = false
      if callbacks.on_reset_voice_settings then callbacks.on_reset_voice_settings() end
    end
  end

  reaper.ImGui_Unindent(ctx, theme.SPACING.md)
end

----------------------------------------------------------------------------
-- History panel (M3 placeholder — w M1 wyświetla session-local history).
----------------------------------------------------------------------------
local function render_history(ctx, s)
  if not s.history or #s.history == 0 then
    theme.push_caption(ctx)
    reaper.ImGui_TextDisabled(ctx, 'HISTORY (0)  · M3: persistent + undo per-edit')
    theme.pop_caption(ctx)
    return
  end
  theme.push_caption(ctx)
  reaper.ImGui_TextDisabled(ctx, ('HISTORY (%d)  · session only (M3: persistent)'):format(#s.history))
  theme.pop_caption(ctx)

  -- Show last 5 entries (M3 full UI: scrollable + per-row undo)
  local n_show = math.min(5, #s.history)
  for i = #s.history, math.max(1, #s.history - n_show + 1), -1 do
    local h = s.history[i]
    local from = (h.from_text or ''):sub(1, 24)
    local to   = (h.to_text or ''):sub(1, 24)
    local time_str = os.date('%H:%M:%S', h.timestamp or 0)
    theme.push_caption(ctx)
    reaper.ImGui_TextDisabled(ctx, ('[%s]  "%s" → "%s"'):format(time_str, from, to))
    theme.pop_caption(ctx)
  end
end

----------------------------------------------------------------------------
-- Action band — Cancel / Preview / primary action (per mode).
-- M2: button label + can-act logic dispatch per s.edit_mode.
----------------------------------------------------------------------------
local function render_action_band(ctx, s, callbacks)
  local stt_ok = (s.stt_state == 'ready')
  local regen_idle = (s.regen_state == 'idle' or s.regen_state == 'error')
  local can_act, action_label, missing_hint, button_w
  local action_color_primary = true   -- use button_primary unless delete

  if s.edit_mode == 'insert' then
    can_act = stt_ok and regen_idle
              and s.cursor_idx ~= nil
              and s.edit_buffer and s.edit_buffer ~= ''
    action_label  = '⌘+↵  Generate + Insert##rep_act'
    button_w      = 240
    if not can_act then
      if not stt_ok then
        missing_hint = 'Transcript not ready yet'
      elseif s.cursor_idx == nil then
        missing_hint = 'Click a word above to position cursor'
      elseif s.edit_buffer == '' then
        missing_hint = 'Text to insert cannot be empty'
      elseif not regen_idle then
        missing_hint = 'Generation in progress'
      else
        missing_hint = 'Cannot act at this time'
      end
    end
  elseif s.edit_mode == 'delete' then
    can_act = stt_ok and regen_idle and s.scope ~= nil
    local n_sel = s.scope and (s.scope.sel_last - s.scope.sel_first + 1) or 0
    action_label  = (n_sel > 0)
      and ('⌫  Delete %d word%s##rep_act'):format(n_sel, n_sel == 1 and '' or 's')
      or  '⌫  Delete##rep_act'
    button_w      = 220
    action_color_primary = false   -- destructive — use danger color
    if not can_act then
      if not stt_ok then
        missing_hint = 'Transcript not ready yet'
      elseif not s.scope then
        missing_hint = 'Click a word above to select'
      elseif not regen_idle then
        missing_hint = 'Splice in progress'
      else
        missing_hint = 'Cannot act at this time'
      end
    end
  else
    -- Replace mode (M1)
    can_act = stt_ok and regen_idle and s.scope ~= nil
              and s.edit_buffer and s.edit_buffer ~= ''
    action_label  = '⌘+↵  Apply edit##rep_act'
    button_w      = 240
    if not can_act then
      if not stt_ok then
        missing_hint = 'Transcript not ready yet'
      elseif not s.scope then
        missing_hint = 'Click a word above to set selection'
      elseif s.edit_buffer == '' then
        missing_hint = 'Replacement text cannot be empty'
      elseif not regen_idle then
        missing_hint = 'Edit in progress'
      else
        missing_hint = 'Cannot apply right now'
      end
    end
  end

  -- Cancel — unselect (Esc-like)
  if theme.button_neutral(ctx, 'Cancel##rep_cancel', 100, 0) then
    if callbacks.on_unselect then callbacks.on_unselect() end
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)

  -- M5-5: Preview — generuje poprawkę i gra ją BEZ wklejania; Apply potem
  -- bierze ten sam take z cache (zero dodatkowego kosztu).
  -- Delete mode: no preview button (no audio to preview).
  if s.edit_mode ~= 'delete' then
    reaper.ImGui_BeginDisabled(ctx, not can_act)
    if theme.button_ghost(ctx, '▶ Preview##rep_preview', 100, 0) then
      if callbacks.on_preview_click then callbacks.on_preview_click() end
    end
    reaper.ImGui_EndDisabled(ctx)
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Generate and play the patch WITHOUT splicing it in. Apply afterwards reuses the same take from cache (no extra cost).')
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  end

  -- Primary action button (per mode)
  reaper.ImGui_BeginDisabled(ctx, not can_act)
  local clicked
  if action_color_primary then
    clicked = theme.button_primary(ctx, action_label, button_w, 0)
  else
    -- Delete = danger color
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        theme.COLORS.danger)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), theme.COLORS.danger_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  theme.COLORS.danger_active)
    clicked = reaper.ImGui_Button(ctx, action_label, button_w, 0)
    reaper.ImGui_PopStyleColor(ctx, 3)
  end
  if clicked then
    if callbacks.on_regen_click then callbacks.on_regen_click() end
  end
  reaper.ImGui_EndDisabled(ctx)

  -- M0-3: EndTooltip tylko po true-return z Begin (inv #6).
  if reaper.ImGui_IsItemHovered(ctx) and not can_act and missing_hint
     and reaper.ImGui_BeginTooltip(ctx) then
    reaper.ImGui_Text(ctx, missing_hint)
    reaper.ImGui_EndTooltip(ctx)
  end

  -- W3 Pakiet B: lekki undo ostatniej edycji. REAPER cofa splice natywnie
  -- (inv #4), ale panel desynchronizował się po Cmd+Z — przycisk robi undo +
  -- resync transkryptu naraz (logika w modes/repair on_undo_click). Enabled
  -- tylko gdy szczyt undo stacka to edycja Repair (s.undo_top_is_ours z
  -- detektora w modes/repair — gate broni cofnięcia cudzej akcji).
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
  reaper.ImGui_BeginDisabled(ctx, not s.undo_top_is_ours)
  if theme.button_ghost(ctx, 'Undo last edit##rep_undo', 130, 0) then
    if callbacks.on_undo_click then callbacks.on_undo_click() end
  end
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
    reaper.ImGui_SetTooltip(ctx, s.undo_top_is_ours
      and 'Undo the last Repair edit — restores the timeline and reloads the transcript.'
      or  'Nothing to undo — the most recent project change is not a Repair edit.\nREAPER undo (Cmd+Z) still works; the transcript reloads automatically.')
  end
  if s.undo_notice then
    theme.flash('rep_undo', s.undo_notice, theme.COLORS.text_dim)
    s.undo_notice = nil
  end
  theme.draw_flash_inline(ctx, 'rep_undo')

  -- Regen progress / error status
  local regen_text, regen_color = format_regen_status(s.regen_state, s.regen_status_text)
  if regen_text then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_TextColored(ctx, regen_color, regen_text)
  end
end

----------------------------------------------------------------------------
-- Public M.render
----------------------------------------------------------------------------
function M.render(ctx, s, deps, callbacks)
  if not s.source_item_guid then
    -- No item selected — show centered placeholder
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Spacing(ctx)
    theme.push_caption(ctx)
    reaper.ImGui_TextDisabled(ctx,
      'No item selected. Click an audio item in REAPER timeline to begin.')
    -- M2.x: STT startuje TYLKO z przycisku (cache miss = awaiting_user,
    -- patrz modes/repair select flow) — hint musi mówić prawdę o koszcie.
    reaper.ImGui_TextDisabled(ctx,
      'Cached transcripts load instantly; otherwise click Transcribe (starts the paid STT call).')
    theme.pop_caption(ctx)
    return
  end

  -- Get source path for word preview (used in transcript chips)
  local item = helpers.find_item_by_guid(s.source_item_guid)
  local source_path = nil
  if item then
    -- Prefer cleaned_audio_path gdy Voice Isolator ON; else raw source path
    if s.cleaned_audio_path and s.cleaned_audio_path ~= '' then
      source_path = s.cleaned_audio_path
    else
      local take = reaper.GetActiveTake(item)
      if take then
        local src = reaper.GetMediaItemTake_Source(take)
        if src then source_path = reaper.GetMediaSourceFileName(src, '') end
      end
    end
  end

  -- T3 (UX-POLISH, user decision 2026-07-11): layout single-column —
  -- sidebar usunięty (jego funkcje żyją w render_header), transkrypt
  -- dostaje pełną szerokość panelu.
  render_header(ctx, s, callbacks)
  -- T7: modal castingu mówców (dispatch niezależny od stanu transkryptu)
  render_cast_voices_modal(ctx, s, callbacks, source_path)
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  do
    if s.error then
      reaper.ImGui_TextColored(ctx, theme.COLORS.status_error,
        'Error: ' .. tostring(s.error))
      if theme.button_neutral(ctx, 'Retry##rep_retry', 120, 0) then
        s.error     = nil
        -- M0-2 (audit 2026-07): 'awaiting_user', NIE 'idle' — z 'idle' nie
        -- wychodzi żadna ścieżka bez zmiany selekcji, więc Retry lądował
        -- w gałęzi spinnera na zawsze. awaiting_user = przycisk ▶ Transcribe.
        s.stt_state = 'awaiting_user'
      end
      return
    end

    -- Show transcript text full if loaded
    if s.transcript and s.transcript.text and s.transcript.text ~= '' then
      -- Header line: transcript stats
      local total_words = s.visible_words and #s.visible_words or 0
      local search_text = (s.transcript_search or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
      -- Search = HIGHLIGHT w pełnym transkrypcie + nawigacja < > (user
      -- 2026-07-11; pre-fix: filtr chował nie-trafienia = utrata kontekstu).
      -- s.search_matches = raw indeksy trafień; s.search_focus_idx = bieżące.
      if search_text ~= s._search_last then
        s._search_last      = search_text
        s.search_matches    = nil
        s.search_focus_pos  = nil
        s.search_focus_idx  = nil
      end
      local matches = {}
      if search_text ~= '' then
        for i, entry in ipairs(s.visible_words or {}) do
          local t = (entry.text or (entry.word and entry.word.text) or ''):lower()
          if t:find(search_text, 1, true) then matches[#matches + 1] = i end
        end
      end
      s.search_matches = matches
      -- Focus może wskazywać nieistniejące trafienie po edycie — clamp.
      if s.search_focus_pos and s.search_focus_pos > #matches then
        s.search_focus_pos = #matches > 0 and 1 or nil
        s.search_focus_idx = matches[s.search_focus_pos or 0]
      end
      theme.push_caption(ctx)
      local stats_text = ('TRANSCRIPT  %d words · language %s'):format(
        total_words, tostring(s.transcript.language_code or '?'))
      if search_text ~= '' then
        stats_text = stats_text .. (' · %d match(es)'):format(#matches)
      end
      reaper.ImGui_TextDisabled(ctx, stats_text)
      theme.pop_caption(ctx)

      -- Search input — highlights chips by case-insensitive substring.
      -- (ImGui_InputTextWithHint nie ma Lua binding per memory + MCP — używamy
      -- InputText z Search: label obok i hint placeholder gdy empty.)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_TextDisabled(ctx, 'Search:')
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
      reaper.ImGui_SetNextItemWidth(ctx, 280)
      local rv_s, new_search = reaper.ImGui_InputText(ctx,
        '##rep_search', s.transcript_search or '')
      if rv_s then
        if callbacks.on_search_change then callbacks.on_search_change(new_search) end
      end
      if (s.transcript_search or '') ~= '' then
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
        if theme.button_ghost(ctx, '×##rep_search_clear', 0, 0) then
          if callbacks.on_search_change then callbacks.on_search_change('') end
        end
        if reaper.ImGui_IsItemHovered(ctx) then
          reaper.ImGui_SetTooltip(ctx, 'Clear search')
        end
        -- Nawigacja po trafieniach: < > + licznik n/N; scroll do trafienia.
        local function jump(delta)
          if #matches == 0 then return end
          local pos = (s.search_focus_pos or 0) + delta
          if pos < 1 then pos = #matches end
          if pos > #matches then pos = 1 end
          s.search_focus_pos      = pos
          s.search_focus_idx      = matches[pos]
          s.search_scroll_pending = true
        end
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
        reaper.ImGui_BeginDisabled(ctx, #matches == 0)
        if reaper.ImGui_SmallButton(ctx, '<##rep_search_prev') then jump(-1) end
        reaper.ImGui_SameLine(ctx, 0, 2)
        if reaper.ImGui_SmallButton(ctx, '>##rep_search_next') then jump(1) end
        reaper.ImGui_EndDisabled(ctx)
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
        theme.push_caption(ctx)
        reaper.ImGui_TextDisabled(ctx,
          #matches > 0 and ('%d/%d'):format(s.search_focus_pos or 0, #matches)
                        or 'no matches')
        theme.pop_caption(ctx)
      end
      -- NS-G: manual Re-transcribe button — force refresh transcript cache.
      -- Right-aligned na tej samej linii co Search. Disabled gdy STT mid-flight.
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
      local stt_busy = (s.stt_state == 'transcribing'
        or s.stt_state == 'preparing_isolate'
        or s.stt_state == 'aligning_source')
      reaper.ImGui_BeginDisabled(ctx, stt_busy)
      if theme.button_ghost(ctx, '↻ Re-transcribe##rep_retrans', 0, 0) then
        if callbacks.on_retranscribe_click then callbacks.on_retranscribe_click() end
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          'Force re-run Scribe STT (clears cached transcript + speaker labels). ' ..
          'Use after enabling diarize default OR if transcript seems wrong.')
      end
      reaper.ImGui_EndDisabled(ctx)
      reaper.ImGui_Spacing(ctx)

      -- NS-G: speaker tabs (jeśli diarize STT wykryło ≥2 mówców)
      render_speaker_tabs(ctx, s, callbacks)

      -- T7 (UX-POLISH): banner castingu — dopóki któryś mówca nie ma głosu
      -- (casting P_EXT ∨ link rejestru); dismissable per item.
      if (s.cast_uncast_n or 0) > 0 and not s.cast_banner_dismissed then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_TextWrapped(ctx,
          ('%d speaker(s) detected — assign a voice per speaker for correct repairs.')
            :format(#(s.speakers or {})))
        reaper.ImGui_PopStyleColor(ctx, 1)
        if theme.button_neutral(ctx, 'Cast voices\xe2\x80\xa6##rep_cast_open', 0, 0) then
          if callbacks.on_open_cast_modal then callbacks.on_open_cast_modal() end
        end
        if reaper.ImGui_IsItemHovered(ctx) then
          reaper.ImGui_SetTooltip(ctx,
            'Assign a voice (or train a clone) per detected speaker.\nEdits inside a speaker then use their voice automatically.')
        end
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
        if theme.button_ghost(ctx, '\xc3\x97##rep_cast_dismiss', 0, 0) then
          if callbacks.on_dismiss_cast_banner then callbacks.on_dismiss_cast_banner() end
        end
        if reaper.ImGui_IsItemHovered(ctx) then
          reaper.ImGui_SetTooltip(ctx, 'Hide for this item')
        end
        reaper.ImGui_Spacing(ctx)
      end

      -- Hint dla right-click play (replaces removed ▶ button per UX feedback)
      theme.push_caption(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
      reaper.ImGui_Text(ctx,
        '(left-click: select word  ·  right-click: play word  ·  Shift+click: extend range)')
      reaper.ImGui_PopStyleColor(ctx, 1)
      theme.pop_caption(ctx)

      -- Word chips in scrollable child
      local child_visible = reaper.ImGui_BeginChild(ctx, '##rep_chips', -1, TRANSCRIPT_H)
      if child_visible then
        render_transcript_chips(ctx, s, callbacks, source_path)
        reaper.ImGui_EndChild(ctx)
      end

      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      -- Edit panel
      render_edit_area(ctx, s, callbacks)

      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      -- Voice settings
      render_voice_settings(ctx, s, callbacks)

      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      -- History
      render_history(ctx, s)

      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      -- Action band
      render_action_band(ctx, s, callbacks)
    elseif s.stt_state == 'awaiting_user'
        or (s.stt_state == 'idle' and not s.stt_handle
            and not s.isolate_handle and not s.align_handle) then
      -- M2.x cache-aware Transcribe button (cache miss; user explicit start).
      -- M0-2 (audit 2026-07): gałąź łapie też defensywnie 'idle' bez handli
      -- in-flight — 'idle' nie ma własnego wyjścia, spinner byłby wieczny.
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_TextColored(ctx, theme.COLORS.status_pending,
        'Ready — no transcript cached for this item region.')
      theme.push_caption(ctx)
      -- Compute approximate audio length + cost estimate dla informacji
      local audio_secs = 0
      if s.stt_render_info then
        local rinfo = s.stt_render_info
        audio_secs = (rinfo.item_length or 0) * (rinfo.playrate or 1)
      end
      local minutes = audio_secs / 60
      -- Scribe ~$0.40/min (Creator tier z user-facing prediction)
      local cost_estimate = minutes * 0.004    -- $0.40/min / 100 chars approximation; pessimistic
      reaper.ImGui_TextDisabled(ctx,
        ('Audio: %.1f min  ·  ~$%.3f  ·  Scribe v2 STT'):format(minutes, cost_estimate * 100))
      reaper.ImGui_TextDisabled(ctx,
        'Renders ONLY visible item region (not full source file). Cached after first run.')
      theme.pop_caption(ctx)
      -- NS-G follow-up: hint gdy legacy cache wykryty (sprzed diarize=true default)
      if s.legacy_cache_hint then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
        reaper.ImGui_TextWrapped(ctx,
          'Cached transcript missing speaker info (from older diarize=off run). ' ..
          'Click Transcribe to refresh — speaker tabs will appear after re-run.')
        reaper.ImGui_PopStyleColor(ctx, 1)
      end
      reaper.ImGui_Spacing(ctx)
      -- ▶ U+25B6 verified Inter glyph (vs ▸ U+25B8 NOT in Inter — patrz
      -- memory reference_inter_font_glyph_safe.md, "small triangle" variants
      -- gap w glyph set).
      if theme.button_primary(ctx, '▶ Transcribe item##rep_transcribe', 240, 0) then
        if callbacks.on_transcribe_click then callbacks.on_transcribe_click() end
      end
    else
      -- STT in progress — show spinner
      local SPIN = { '|', '/', '-', '\\' }
      local idx = math.floor(util.now() * 8) % #SPIN + 1
      local elapsed = 0
      if s.stt_handle and s.stt_handle.started_at then
        elapsed = util.now() - s.stt_handle.started_at
      elseif s.isolate_handle and s.isolate_handle.started_at then
        elapsed = util.now() - s.isolate_handle.started_at
      end
      local label = 'Working…'
      if s.stt_state == 'preparing_isolate' then label = 'Cleaning audio via Voice Isolator…' end
      if s.stt_state == 'transcribing'      then label = 'Transcribing via Scribe…'           end
      if s.stt_state == 'aligning_source'   then label = 'Aligning word boundaries…'          end
      reaper.ImGui_TextColored(ctx, theme.COLORS.status_pending,
        ('%s  %s  (%.1fs elapsed)'):format(SPIN[idx], label, elapsed))
      theme.push_caption(ctx)
      reaper.ImGui_TextDisabled(ctx,
        'Async — UI stays responsive. Worker (POSIX curl) in background.')
      theme.pop_caption(ctx)
    end
  end
end

return M
