-- modules/gui/dubbing_inspector.lua
-- NS-B M3.3+M3.4+M3.5: per-segment editor modal.
--
-- Opens via right-click na segment row → Inspect... lub double-click row.
-- Fields:
--   - Source text (read-only)
--   - Translated text (editable, marks segment stale per-edit via
--     mode_module.propagate_segment_stale)
--   - Director's note textarea (M3.5 — appended do LLM user_prompt during translate)
--   - Voice override z "Pick voice..." button (uses voice_picker callback)
--   - Generate alternatives ×N button (M3.4 — adds N takes z różnymi seeds)
--   - Re-generate single button (replaces last take via AddTake — same flow as variants×1)
--   - Cancel running re-gen
--
-- Layout: 2-col z left side source/translated, right side metadata + actions.

local theme        = require 'modules.theme'
local voice_picker = require 'modules.gui.voice_picker'
local voice_settings_dlg = require 'modules.gui.dubbing_voice_settings'
local dub_project  = require 'modules.dubbing_project'
local util         = require 'modules.util'

-- W3 (user-reported): wrapped-view pattern (mirror dubbing_panel inline edit
-- + tts_dialogue_panel) — ImGui InputTextMultiline NIE zawija natywnie.
-- Bufory pre-wrapowane na granicach słów; commit zwija do single-line
-- (normalize_whitespace) żeby stored text był czysty (LLM cache / splice).
local WRAP_COLS = 80

local M = {}

local POPUP_ID = 'Segment inspector'

local s = {
  pending_open = false,
  pending_reopen = false,    -- Polish #1 (PM5): re-open po unsaved warning cancel
  seg_id       = nil,        -- which segment is open; nil = closed
  -- Local buffers (re-init per open from segment data so user can cancel)
  buf_translated   = '',
  buf_director_note= '',
  -- M4.4: initial values snapshotted on open dla unsaved-changes detection
  initial_translated    = '',
  initial_director_note = '',
  variant_count    = 3,      -- default
  initialized      = false,
}

function M.open(seg_id)
  s.pending_open = true
  s.seg_id       = seg_id
  s.initialized  = false
end

function M.is_open() return s.seg_id ~= nil end
function M.get_seg_id() return s.seg_id end
function M.get_variant_count() return s.variant_count end

local function load_buffers(seg, lang)
  -- Wrapped-view: bufor trzyma tekst łamany wizualnie; porównania unsaved
  -- (wrapped vs wrapped snapshot) pozostają spójne.
  s.buf_translated    = util.soft_wrap_text((seg.translations and seg.translations[lang]) or '', WRAP_COLS)
  s.buf_director_note = util.soft_wrap_text(seg.director_note or '', WRAP_COLS)
  -- M4.4: snapshot dla unsaved-changes detection
  s.initial_translated    = s.buf_translated
  s.initial_director_note = s.buf_director_note
  -- W2 M2: bufor gestu suwaka tempa nie przeżywa zmiany segmentu
  s.tempo_slider_val = nil
  s.initialized = true
end

local function has_unsaved_changes()
  return s.buf_translated ~= s.initial_translated
      or s.buf_director_note ~= s.initial_director_note
end

----------------------------------------------------------------------------
-- Public: render(ctx, state, mode_module) → returns action or nil
-- Actions: 'close' (modal closed), 'commit' (user saved edits → caller may
--          want to mark dirty / propagate stale), 'regen' / 'variants' /
--          'cancel_regen' (mode_module handles), 'change_voice' (voice picker
--          opens itself via callback).
----------------------------------------------------------------------------
function M.render(ctx, state, mode_module)
  if not s.seg_id then return nil end

  if s.pending_open or s.pending_reopen then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    s.pending_open   = false
    s.pending_reopen = false
  end

  local ms = mode_module.init_state(state)
  if not ms.project then return nil end
  local lang = ms.project.active_target_language
  if not lang then return nil end

  local seg = dub_project.find_segment(ms.project, s.seg_id)
  if not seg then
    s.seg_id = nil
    return 'close'
  end

  if not s.initialized then load_buffers(seg, lang) end

  -- W3 (user-reported ×3): wymiar = zawartość, zero martwej przestrzeni.
  -- 680 wys. mieści cały content (pola mają stałe wysokości → content ~stały;
  -- 580 wymuszało scroll). 640 szer. przylega do tekstu łamanego na
  -- WRAP_COLS=80 (~576px) — przy 800 prawa 1/4 okna była pusta. Na małych
  -- ekranach clamp ≤92% w center_next_modal przywróci scroll (świadomie).
  theme.center_next_modal(ctx, 640, 680)
  theme.popup_keep_top(ctx, POPUP_ID)
  local visible = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then
    -- Popup auto-closed (X / Esc). Polish #1 (PM5): gdy unsaved buffer →
    -- prompt Discard/Cancel; jeśli user cancel → re-open popup w next frame
    -- (zachowuje edits). Mirror logic Cancel button (line ~338).
    if has_unsaved_changes() then
      local choice = reaper.MB(
        'You have unsaved edits do translation or director\'s note.\n\nDiscard changes?',
        'Unsaved changes', 1)
      if choice ~= 1 then
        -- Cancel → keep modal open w next frame z preserved buffers
        s.pending_reopen = true
        return nil
      end
    end
    s.seg_id = nil
    return 'close'
  end

  local action = nil

  -- Header z seg id + speaker + time
  local spk = dub_project.find_speaker(ms.project, seg.speaker_id)
  local spk_label = spk and (spk.label or spk.id) or (seg.speaker_id or '?')
  theme.push_heading(ctx)
  reaper.ImGui_Text(ctx, ('%s · %s · %.2fs → %.2fs'):format(
    seg.id, spk_label, seg.t_start or 0, seg.t_end or 0))
  theme.pop_heading(ctx)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  local trans_st = (seg.translation_status and seg.translation_status[lang]) or 'pending'
  local dub_st   = (seg.dub_status and seg.dub_status[lang]) or 'pending'
  local is_pw    = seg.dub_per_word and seg.dub_per_word[lang] == true
  local fb_reason = seg.dub_per_word_fallback_reason and seg.dub_per_word_fallback_reason[lang] or ''
  local mode_str
  if dub_st == 'generated' then
    if is_pw then
      mode_str = 'per-word splice (stretch markers)'
    elseif fb_reason ~= '' and fb_reason ~= 'toggle_off' then
      mode_str = ('full-segment (per-word fallback: %s)'):format(fb_reason)
    else
      mode_str = 'full-segment splice'
    end
  else
    mode_str = 'not generated yet'
  end
  reaper.ImGui_Text(ctx, ('Status: translation=%s · dub=%s · mode=%s'):format(trans_st, dub_st, mode_str))
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Source text (read-only) — wrapped do display (pole nie zawija natywnie)
  reaper.ImGui_Text(ctx, 'Source text (read-only):')
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x1A1A1AFF)
  reaper.ImGui_InputTextMultiline(ctx, '##insp_source',
    util.soft_wrap_text(seg.source_text or '', WRAP_COLS), -1, 60,
    reaper.ImGui_InputTextFlags_ReadOnly())
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)

  -- Translated text (editable)
  reaper.ImGui_Text(ctx, ('Translation (%s):'):format(lang:upper()))
  local rv_t, new_trans = reaper.ImGui_InputTextMultiline(ctx, '##insp_trans',
    s.buf_translated, -1, 80)
  if rv_t then s.buf_translated = new_trans end
  -- Reflow po blur (mirror tts_dialogue_panel): podczas aktywnej edycji
  -- buforem rządzi widget — live re-wrap walczyłby z kursorem (ImGui
  -- constraint). Po wyjściu z pola tekst łamie się od nowa.
  if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
    s.buf_translated = util.soft_wrap_text(
      util.normalize_whitespace(s.buf_translated), WRAP_COLS)
  end

  reaper.ImGui_Spacing(ctx)

  -- Director's note (M3.5)
  reaper.ImGui_Text(ctx, "Director's note (per-segment LLM hint):")
  local rv_d, new_note = reaper.ImGui_InputTextMultiline(ctx, '##insp_dir',
    s.buf_director_note, -1, 60)
  if rv_d then s.buf_director_note = new_note end
  if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
    s.buf_director_note = util.soft_wrap_text(
      util.normalize_whitespace(s.buf_director_note), WRAP_COLS)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Optional hint passed to the LLM on next translation of THIS segment.\n'
        .. 'Examples: "whisper, emotional", "sarcastic tone", "translate fragment X as Y".\n'
        .. 'Note NOT included in global system prompt — stays per-segment to preserve cache.')
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Voice override row
  local override_id = (seg.voice_id_overrides and seg.voice_id_overrides[lang]) or nil
  local speaker_voice_id = spk and spk.voices and spk.voices[lang] or nil
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Voice for this segment:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if override_id then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.override)
    reaper.ImGui_Text(ctx, 'Override active')
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    if reaper.ImGui_SmallButton(ctx, 'Clear override') then
      seg.voice_id_overrides[lang] = nil
      mode_module.mark_dirty(state)
      mode_module.propagate_segment_stale(state, seg, lang, 'dub_only')
    end
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_Text(ctx, ('Using speaker default (%s)'):format(
      (spk and spk.voice_names and spk.voice_names[lang]) or '(no voice)'))
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if reaper.ImGui_SmallButton(ctx, 'Pick voice override...') then
    voice_picker.open({
      state            = state,
      current_voice_id = override_id,
      allow_clear      = true,
      on_pick = function(voice_id, voice_name)
        if voice_id then
          seg.voice_id_overrides[lang] = voice_id
        else
          seg.voice_id_overrides[lang] = nil
        end
        mode_module.mark_dirty(state)
        -- Voice change: dub_only (translation text unchanged)
        mode_module.propagate_segment_stale(state, seg, lang, 'dub_only')
      end,
    })
  end

  -- M4+: per-segment voice settings override
  local seg_vs_override = (seg.voice_settings_overrides and seg.voice_settings_overrides[lang]) or nil
  local spk_default     = (spk and spk.voice_settings_per_lang and spk.voice_settings_per_lang[lang]) or nil
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Voice settings:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if seg_vs_override then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.override)
    reaper.ImGui_Text(ctx, ('Override active (stab %.2f / sim %.2f / spd %.2f)'):format(
      seg_vs_override.stability or 0.5,
      seg_vs_override.similarity_boost or 0.75,
      seg_vs_override.speed or 1.0))
    reaper.ImGui_PopStyleColor(ctx, 1)
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_Text(ctx, 'Using speaker default')
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if reaper.ImGui_SmallButton(ctx, 'Edit voice settings...') then
    voice_settings_dlg.open({
      title    = 'Voice settings — segment ' .. seg.id,
      subtitle = (spk_label or '?') .. ' / ' .. lang:upper(),
      current_settings = seg_vs_override or spk_default,
      has_override = seg_vs_override ~= nil,
      allow_clear  = true,
      on_apply = function(new_settings)
        if not seg.voice_settings_overrides then seg.voice_settings_overrides = {} end
        seg.voice_settings_overrides[lang] = new_settings
        mode_module.mark_dirty(state)
        mode_module.propagate_segment_stale(state, seg, lang, 'dub_only')
      end,
      on_clear = function()
        if seg.voice_settings_overrides then seg.voice_settings_overrides[lang] = nil end
        mode_module.mark_dirty(state)
        mode_module.propagate_segment_stale(state, seg, lang, 'dub_only')
      end,
    })
  end

  -- W2 M2 (PHASE-W2 §3): Speech tempo — suwak zawsze w Inspektorze
  -- (drugi konsument obok popovera w tabeli; ta sama ścieżka commit →
  -- mode_module.set_stretch_override = refit in-place, 1 Undo block/gest).
  -- Tylko span-fitted segmenty (per-word/natural mają własne reguły tempa).
  local insp_fit = seg.dub_fit and seg.dub_fit[lang]
  local can_stretch = dub_st == 'generated' and insp_fit
    and insp_fit.strategy ~= 'per_word' and insp_fit.strategy ~= 'natural'
  if can_stretch then
    reaper.ImGui_Spacing(ctx)
    local stretch_override = seg.dub_stretch_override and seg.dub_stretch_override[lang]
    local stretch_busy = mode_module.is_segment_busy(state, seg.id)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, 'Speech tempo:')
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    if stretch_busy then reaper.ImGui_BeginDisabled(ctx) end
    local cur = s.tempo_slider_val or stretch_override or insp_fit.applied_rate or 1.0
    reaper.ImGui_SetNextItemWidth(ctx, 220)
    local rv_s, v_s = reaper.ImGui_SliderDouble(ctx, '##insp_tempo', cur,
      mode_module.STRETCH_OVERRIDE_MIN, mode_module.STRETCH_OVERRIDE_MAX, '%.2fx')
    if rv_s then s.tempo_slider_val = v_s end
    if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
      mode_module.set_stretch_override(state, seg.id, s.tempo_slider_val or cur)
      s.tempo_slider_val = nil
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Lower = faster speech, higher = slower (1.00x = natural TTS pace).\n'
        .. 'Free — re-fits the existing audio on the timeline, no API call.')
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    if stretch_override then
      if reaper.ImGui_SmallButton(ctx, 'Reset to auto##insp_tempo_rst') then
        mode_module.clear_stretch_override(state, seg.id)
        s.tempo_slider_val = nil
      end
    else
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
      reaper.ImGui_Text(ctx, 'auto')
      reaper.ImGui_PopStyleColor(ctx, 1)
    end
    if stretch_busy then reaper.ImGui_EndDisabled(ctx) end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Re-gen / Variants row
  local regen_in_flight = ms.regen_state and ms.regen_state[seg.id] or nil
  if regen_in_flight then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_running)
    reaper.ImGui_Text(ctx, ('Re-generating... %d remaining'):format(regen_in_flight.target_remaining or 0))
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    if reaper.ImGui_SmallButton(ctx, 'Cancel re-gen') then
      action = 'cancel_regen'
    end
  else
    -- T2 (UX-POLISH): odsłuch tłumaczenia bez wstawiania — ten sam
    -- request/cache co Generate (zero podwójnego billingu).
    if theme.button_neutral(ctx, '\xe2\x96\xb6 Preview##insp_pv') then
      action = 'preview'
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Play the translated line (voice + settings as Generate).\nGenerate afterwards reuses this render.')
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    -- Regenerate single (1 take)
    if theme.button_neutral(ctx, 'Re-generate (1 take)') then
      action = 'regen_1'
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'TTS z current translation + voice + new random seed → AddTake do dub item.\n'
          .. 'User cycles takes via REAPER T key.')
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    reaper.ImGui_SetNextItemWidth(ctx, 60)
    local rv_n, new_n = reaper.ImGui_InputInt(ctx, '##insp_n_variants', s.variant_count)
    if rv_n then
      s.variant_count = math.max(1, math.min(10, new_n))
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    if theme.button_primary(ctx, ('Generate alternatives x%d'):format(s.variant_count)) then
      action = 'variants'
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Spawn N TTS in sequence, each with a different seed → AddTake per result.\n'
          .. 'Audition takes after all are done. Best take selected via REAPER T key.')
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Footer: Apply / Cancel
  if theme.button_primary(ctx, 'Apply changes') then
    -- Commit buffer changes to segment. Wrapped-view: bufory mają wizualne
    -- \n z soft_wrap — commit zwija do single-line PRZED porównaniem i
    -- zapisem (stored text musi być czysty: LLM cache key + splice).
    local commit_trans = util.normalize_whitespace(s.buf_translated)
    local commit_note  = util.normalize_whitespace(s.buf_director_note)
    local trans_changed = (commit_trans ~= ((seg.translations and seg.translations[lang]) or ''))
    local note_changed  = (commit_note ~= (seg.director_note or ''))
    if trans_changed then
      seg.translations[lang] = commit_trans
      -- User-edited translation = treat as translated state (skip LLM re-run)
      seg.translation_status[lang] = (commit_trans == '') and 'pending' or 'translated'
    end
    if note_changed then
      seg.director_note = commit_note
      -- Director's note change → translation stale (cache key includes it indirectly)
      mode_module.propagate_segment_stale(state, seg, lang)
    end
    if trans_changed and not note_changed then
      -- Translation manually edited → dub stale, ale translation NOT stale
      -- (user edit is "final"; only dub regen needed)
      if seg.dub_status and seg.dub_status[lang] == 'generated' then
        seg.dub_status[lang] = 'stale'
        local item_guid = seg.item_guids and seg.item_guids[lang]
        if item_guid and item_guid ~= '' then
          -- Cascade I_CUSTOMCOLOR through propagate_segment_stale (it covers item too)
          local find_item = function(guid)
            local count = reaper.CountMediaItems(0)
            for i = 0, count - 1 do
              local it = reaper.GetMediaItem(0, i)
              local _, g = reaper.GetSetMediaItemInfo_String(it, 'GUID', '', false)
              if g == guid then return it end
            end
          end
          local item = find_item(item_guid)
          if item then require('modules.dubbing_splicer').mark_item_stale(item) end
        end
      end
    end
    if trans_changed or note_changed then
      mode_module.mark_dirty(state)
      -- W3 quick win: modal closes on Apply — confirm w status line + next step
      -- (note edit → translation stale → Translate all; text edit → dub stale).
      local next_step = note_changed and 'Translate all' or 'Generate dub'
      mode_module.set_status(state,
        ('Segment %s saved — next: %s.'):format(seg.id, next_step),
        theme.COLORS.status_done)
    end
    reaper.ImGui_CloseCurrentPopup(ctx)
    s.seg_id = nil
    action = action or 'commit'
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if theme.button_neutral(ctx, 'Cancel') then
    -- M4.4: warn jeśli unsaved changes
    local discard = true
    if has_unsaved_changes() then
      discard = (reaper.MB(
        'You have unsaved edits do translation or director\'s note.\n\nDiscard changes?',
        'Unsaved changes', 1) == 1)
    end
    if discard then
      reaper.ImGui_CloseCurrentPopup(ctx)
      s.seg_id = nil
      action = 'close'
    end
  end

  reaper.ImGui_EndPopup(ctx)
  return action
end

return M
