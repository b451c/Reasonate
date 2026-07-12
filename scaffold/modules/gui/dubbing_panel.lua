-- modules/gui/dubbing_panel.lua
-- NS-B Dubbing: hero view (variant A — editorial split, ElevenLabs Studio mirror).
--
-- Layout (user-confirmed 2026-05-12):
--   ┌─ header bar: lang tabs + TTS model ─────────────────────────────┐
--   ├─ translation context (collapsible) ────────────────────────────┤
--   ├─ CAST sidebar (left) │ SEGMENTS table (right) ─────────────────┤
--   ├─ status ticker (segs count, cost) ─────────────────────────────┤
--   ├─ action band (Translate all / Generate dub / Export) ──────────┤
--   └─────────────────────────────────────────────────────────────────┘
--
-- M1 scope: layout + idle view + Start Dubbing modal + project view structural.
-- Pipeline operations (Translate all / Generate dub) wired do mode_module
-- handles ale orchestration body deferred do M2 (chunker + splicer + matcher).
--
-- Wszystkie user-facing strings English-only (per `feedback_ui_english_only`).

local theme           = require 'modules.theme'
local config          = require 'modules.config'
local dub_state       = require 'modules.dubbing_state'
local dub_project     = require 'modules.dubbing_project'
local dubbing_context = require 'modules.gui.dubbing_context'
local dubbing_inspector       = require 'modules.gui.dubbing_inspector'
local dubbing_voice_design    = require 'modules.gui.dubbing_voice_design'
local dubbing_voice_settings  = require 'modules.gui.dubbing_voice_settings'
local voice_picker    = require 'modules.gui.voice_picker'
local speaker_picker  = require 'modules.gui.speaker_picker'   -- NS-G
local stt             = require 'modules.stt'                  -- NS-G: diarize cache check
local audio_concat    = require 'modules.audio_concat'         -- NS-G: regions render

local M = {}

local function word_count(text)
  if not text or text == '' then return 0 end
  local n = 0
  for _ in text:gmatch('%S+') do n = n + 1 end
  return n
end

----------------------------------------------------------------------------
-- NS-G: compute geometry-stable STT cache key dla REAPER item (mirror
-- repair.lua compute_stt_cache_key — refactor opportunity M3: extract to
-- stt.lua public helper, share across Repair + Dubbing).
----------------------------------------------------------------------------
local function compute_item_cache_key(item)
  if not item then return nil end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  -- Walk do root source (section/reverse wrappers)
  local depth = 0
  while depth < 4 do
    local parent = reaper.GetMediaSourceParent and reaper.GetMediaSourceParent(src)
    if not parent then break end
    src = parent; depth = depth + 1
  end
  local src_path = reaper.GetMediaSourceFileName(src, '')
  if not src_path or src_path == '' then return nil end
  local render_info = {
    item_offs   = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0,
    item_length = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0,
    playrate    = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1,
  }
  if render_info.playrate <= 0 then render_info.playrate = 1 end
  return stt.cache_key(src_path, render_info)
end

----------------------------------------------------------------------------
-- NS-G: count unique speakers in diarize transcript.
----------------------------------------------------------------------------
local function count_unique_speakers_in(transcript)
  if not transcript or type(transcript.words) ~= 'table' then return 0 end
  local seen, n = {}, 0
  for _, w in ipairs(transcript.words) do
    local spk = w.speaker_id or w.speaker
    if spk and not seen[spk] then seen[spk] = true; n = n + 1 end
  end
  return n
end

-- Soft-wrap text na word boundaries to approximate visual wrap w edytorze.
-- Soft-wrap + normalize przeniesione do util (2026-06-10 — drugi konsument:
-- tts_dialogue_panel lines). Lokalne aliasy zachowują call sites bez zmian.
local util_text = require 'modules.util'
local soft_wrap_text       = util_text.soft_wrap_text
local normalize_whitespace = util_text.normalize_whitespace

-- Commit pending inline edit (Source or Translation) back to segment data.
-- Marks appropriate stale state via mode_module (propagate / item color).
local function commit_inline_edit(state, ms, project, mode_module)
  if not ms.inline_edit then return end
  local seg = require('modules.dubbing_project').find_segment(project, ms.inline_edit.seg_id)
  if not seg then ms.inline_edit = nil; return end
  local field = ms.inline_edit.field
  -- Normalize whitespace: editor pre-wrapped raw_text z soft_wrap_text (newlines
  -- na ~70 chars). Commit zwija je do single-line żeby seg.source_text /
  -- translations match clean STT format (LLM cache key dependent na normalized text).
  local buf   = normalize_whitespace(ms.inline_edit.buffer or '')
  if field == 'source' then
    if (seg.source_text or '') ~= buf then
      seg.source_text = buf
      -- Source change → all-langs translation + dub stale (cascade)
      mode_module.propagate_segment_stale(state, seg, project.active_target_language, 'all')
    end
  elseif field == 'translation' then
    local elang = ms.inline_edit.lang or project.active_target_language
    if not seg.translations then seg.translations = {} end
    if (seg.translations[elang] or '') ~= buf then
      seg.translations[elang] = buf
      seg.translation_status = seg.translation_status or {}
      -- User edit is final — translation marked translated (skips LLM re-run)
      seg.translation_status[elang] = (buf == '') and 'pending' or 'translated'
      -- Mark dub stale dla tej lang only (translation changed, audio not yet)
      if seg.dub_status and seg.dub_status[elang] == 'generated' then
        seg.dub_status[elang] = 'stale'
        local item_guid = seg.item_guids and seg.item_guids[elang]
        if item_guid and item_guid ~= '' then
          for i = 0, reaper.CountMediaItems(0) - 1 do
            local it = reaper.GetMediaItem(0, i)
            local _, g = reaper.GetSetMediaItemInfo_String(it, 'GUID', '', false)
            if g == item_guid then
              require('modules.dubbing_splicer').mark_item_stale(it)
              break
            end
          end
        end
      end
    end
  end
  mode_module.mark_dirty(state)
  ms.inline_edit = nil
end

----------------------------------------------------------------------------
-- M4-3: pytanie o sprzątanie klonów IVC przy Close/Delete projektu.
-- Zwraca (proceed, note): proceed=false gdy user anulował; note = dopisek
-- o zachowanych klonach do głównego dialogu (albo nil).
-- DECYZJA 2026-07-02: default Delete (Yes); wykluczone (Cast Registry /
-- track voice) NIE są kasowane i lądują w sekcji Kept; sloty głosów
-- pokazane gdy znane (state.quota po Test/Save w Settings).
----------------------------------------------------------------------------
local function prompt_clone_cleanup(state, mode_module)
  local deletable, kept = mode_module.collect_deletable_clones(state)
  if #deletable == 0 and #kept == 0 then return true, nil end

  local kept_note = ''
  if #kept > 0 then
    local knames = {}
    for _, c in ipairs(kept) do
      knames[#knames + 1] = ('  · %s (kept — %s)'):format(c.name, c.kept_reason or 'in use')
    end
    kept_note = '\n\nKept (in use outside this project):\n' .. table.concat(knames, '\n')
  end
  if #deletable == 0 then
    return true, kept_note ~= '' and kept_note or nil
  end

  local names = {}
  for _, c in ipairs(deletable) do names[#names + 1] = '  · ' .. c.name end
  local app_state = require 'modules.state'
  local slots = ''
  if app_state.quota_voice_slots_used and app_state.quota_voice_limit then
    slots = ('\n\nVoice slots used: %d / %d.'):format(
      app_state.quota_voice_slots_used, app_state.quota_voice_limit)
  end
  local choice = reaper.MB(
    ('This project created %d cloned voice(s) on your ElevenLabs account:\n\n%s%s%s\n\n'
      .. 'Clones are one-off artifacts — the dub audio is already rendered and '
      .. 're-cloning takes one click. Delete them to free voice slots?\n\n'
      .. 'YES = delete listed clones · NO = keep all · CANCEL = abort')
      :format(#deletable, table.concat(names, '\n'), kept_note, slots),
    'Cloned voices cleanup', 3)
  if choice == 6 then       -- Yes → delete
    mode_module.delete_clones(state, deletable)
    return true, kept_note ~= '' and kept_note or nil
  elseif choice == 7 then   -- No → keep all
    return true, kept_note ~= '' and kept_note or nil
  end
  return false, nil          -- Cancel
end

----------------------------------------------------------------------------
-- W3 (tabela segmentów): status segmentu policzony w JEDNYM miejscu —
-- pill w kolumnie Status i chipy filtra liczą z tego samego źródła.
-- bucket = etykieta filtra ('DUBBED (per-word)' zlewa się z 'DUBBED').
-- Kolejność gałęzi = nietknięta logika pilla (excluded → generated →
-- running → dub failed → dub stale → trans failed → translated → WAITING
-- → pending).
----------------------------------------------------------------------------
local function segment_status(seg, seg_i, lang, state, mode_module)
  local trans_st = (seg.translation_status and seg.translation_status[lang]) or 'pending'
  local dub_st   = (seg.dub_status and seg.dub_status[lang]) or 'pending'
  local is_pw    = seg.dub_per_word and seg.dub_per_word[lang] == true
  local label, color
  if seg.dub_excluded then
    label, color = 'excluded', theme.COLORS.status_skipped
  elseif dub_st == 'generated' then
    if is_pw then
      label, color = 'DUBBED (per-word)', theme.COLORS.status_done
    else
      label, color = 'DUBBED', theme.COLORS.status_done
    end
    -- W2 M1: tempo/fit w pillu (PHASE-W2 §2) — bucket filtra liczony z
    -- gałęzi WYŻEJ (zostaje 'DUBBED'), suffix tylko w wyświetlanej etykiecie.
    local fit = seg.dub_fit and seg.dub_fit[lang]
    local user_rate = seg.dub_stretch_override and seg.dub_stretch_override[lang]
    if fit and user_rate then
      -- W2 M2: user override (suwak) — amber gdy poza strefą zieloną LUB
      -- geometria nadal woła o uwagę (gap warn / overrun); detale w tooltipie.
      label = ('%s · Custom %.2f×'):format(label, fit.applied_rate or user_rate)
      local r_min, r_max = config.get_dubbing_fit_bounds()
      local r = fit.applied_rate or user_rate
      if r < r_min - 1e-6 or r > r_max + 1e-6
         or (fit.overrun_secs or 0) > 0.001 or fit.gap_warn then
        color = theme.COLORS.status_stale
      end
    elseif fit then
      if fit.strategy == 'gap' then
        label = ('%s · GAP +%.1fs'):format(label, fit.gap_secs or 0)
        if fit.gap_warn then color = theme.COLORS.status_stale end
      elseif fit.strategy == 'overrun' then
        label = ('%s · OVERRUN +%.1fs'):format(label, fit.overrun_secs or 0)
        color = theme.COLORS.status_stale
      elseif fit.applied_rate and fit.strategy ~= 'natural' then
        label = ('%s · %.2f×'):format(label, fit.applied_rate)
      end
    end
  elseif dub_st == 'tts_running' or dub_st == 'align_running' then
    label, color = 'GEN...', theme.COLORS.status_running
  elseif dub_st == 'failed' then
    -- W3 Pakiet B+: terminal dub failure (mirror trans_st 'failed')
    label, color = 'FAILED', theme.COLORS.status_error
  elseif dub_st == 'stale' then
    label, color = 'stale', theme.COLORS.status_stale
  elseif trans_st == 'failed' then
    -- M1-4b: terminal translate failure — bez tej gałęzi 'failed'
    -- renderowałby się jako mylące 'pending'.
    label, color = 'FAILED', theme.COLORS.status_error
  elseif trans_st == 'translated' then
    label, color = 'translated', theme.COLORS.status_pending
  elseif mode_module.is_segment_context_gated
         and mode_module.is_segment_context_gated(state, seg_i, lang) then
    -- W3: wstrzymany świadomie (context-gate), nie zamrożony.
    label, color = 'WAITING', theme.COLORS.status_stale
  else
    label, color = 'pending', theme.COLORS.text_dim
  end
  -- W2 M1: pill ma suffixy (· 1.08× / · GAP / · OVERRUN) — bucket filtra
  -- zlewa wszystkie warianty DUBBED w jeden (prefix match, nie equality).
  local bucket = label:match('^DUBBED') and 'DUBBED' or label
  return label, color, bucket, trans_st, dub_st
end

----------------------------------------------------------------------------
-- Per-row context menu (audit M3-1, 2026-06-10: extracted z 502-liniowego
-- render_segments_table — czysto mechaniczne przeniesienie, zero zmian
-- zachowania). 9 akcji per segment.
----------------------------------------------------------------------------
local function render_segment_context_menu(ctx, seg, project, lang, ms, state, mode_module)
  if reaper.ImGui_BeginPopupContextItem(ctx, 'seg_ctx_' .. seg.id) then
    -- Open inspector
    if reaper.ImGui_Selectable(ctx, 'Open inspector##ctx_insp_' .. seg.id, false) then
      dubbing_inspector.open(seg.id)
      ms.inspector_pending_seg_id = seg.id
    end
    if reaper.ImGui_Selectable(ctx, 'Reveal in REAPER (scroll + select)##ctx_rev_' .. seg.id, false) then
      mode_module.reveal_segment_in_reaper(state, seg.id)
    end

    reaper.ImGui_Separator(ctx)

    -- W3 (user request): edycja widoczna w menu — TO SAMO co dwuklik na
    -- komórce Source/Translation (ten sam ms.inline_edit + deferred open
    -- w render_inline_edit_popup), tylko możliwe do znalezienia.
    if reaper.ImGui_Selectable(ctx, 'Edit source\xe2\x80\xa6##ctx_es_' .. seg.id, false) then
      if ms.inline_edit and ms.inline_edit.seg_id ~= seg.id then
        commit_inline_edit(state, ms, project, mode_module)
      end
      local mx, my = reaper.ImGui_GetMousePos(ctx)
      ms.inline_edit = {
        seg_id       = seg.id,
        field        = 'source',
        lang         = lang,
        buffer       = soft_wrap_text(seg.source_text or '', 70),
        just_entered = true,
        open_pending = true,
        popup_x      = mx - 80,
        popup_y      = my - 30,
      }
    end
    if reaper.ImGui_Selectable(ctx, 'Edit translation\xe2\x80\xa6##ctx_et_' .. seg.id, false) then
      if ms.inline_edit and ms.inline_edit.seg_id ~= seg.id then
        commit_inline_edit(state, ms, project, mode_module)
      end
      local mx, my = reaper.ImGui_GetMousePos(ctx)
      ms.inline_edit = {
        seg_id       = seg.id,
        field        = 'translation',
        lang         = lang,
        buffer       = soft_wrap_text((seg.translations and seg.translations[lang]) or '', 70),
        just_entered = true,
        open_pending = true,
        popup_x      = mx - 80,
        popup_y      = my - 30,
      }
    end

    reaper.ImGui_Separator(ctx)

    -- T2 (UX-POLISH): odsłuch tłumaczenia bez wstawiania — ten sam
    -- request/cache co Generate (odsłuchany fragment nie renderuje się
    -- drugi raz przy Generate).
    do
      local has_trans = ((seg.translations and seg.translations[lang]) or '') ~= ''
      local busy = mode_module.is_segment_previewing
               and mode_module.is_segment_previewing(state, nil)
      reaper.ImGui_BeginDisabled(ctx, not has_trans or busy)
      if reaper.ImGui_Selectable(ctx,
           '\xe2\x96\xb6 Preview translation##ctx_pv_' .. seg.id, false) then
        mode_module.request_segment_preview(state, seg.id)
      end
      reaper.ImGui_EndDisabled(ctx)
    end

    -- Re-translate (force fresh LLM call dla active lang)
    if reaper.ImGui_Selectable(ctx, 'Re-translate this segment##ctx_rt_' .. seg.id, false) then
      mode_module.retranslate_segment(state, seg.id)
    end
    -- Re-gen dub 1 take
    if reaper.ImGui_Selectable(ctx, 'Re-generate dub (1 take)##ctx_rg1_' .. seg.id, false) then
      mode_module.request_regen_segment(state, seg.id, 1)
    end
    -- Generate alternatives x3
    if reaper.ImGui_Selectable(ctx, 'Generate alternatives x3##ctx_var_' .. seg.id, false) then
      mode_module.request_regen_segment(state, seg.id, 3)
    end

    reaper.ImGui_Separator(ctx)

    -- Reassign speaker (submenu z list)
    if reaper.ImGui_BeginMenu(ctx, 'Reassign to speaker##ctx_sp_' .. seg.id) then
      for _, target_spk in ipairs(project.speakers) do
        local is_current = (target_spk.id == seg.speaker_id)
        if reaper.ImGui_MenuItem(ctx, target_spk.label or target_spk.id, nil, is_current, not is_current) then
          mode_module.reassign_segment_speaker(state, seg.id, target_spk.id)
        end
      end
      reaper.ImGui_EndMenu(ctx)
    end

    -- Merge z previous / next
    local has_prev, has_next = false, false
    for i, s2 in ipairs(project.segments) do
      if s2.id == seg.id then
        has_prev = (i > 1)
        has_next = (i < #project.segments)
        break
      end
    end
    reaper.ImGui_BeginDisabled(ctx, not has_prev)
    if reaper.ImGui_Selectable(ctx, 'Merge with previous segment##ctx_mp_' .. seg.id, false) then
      mode_module.merge_segment(state, seg.id, 'prev')
    end
    reaper.ImGui_EndDisabled(ctx)
    reaper.ImGui_BeginDisabled(ctx, not has_next)
    if reaper.ImGui_Selectable(ctx, 'Merge with next segment##ctx_mn_' .. seg.id, false) then
      mode_module.merge_segment(state, seg.id, 'next')
    end
    reaper.ImGui_EndDisabled(ctx)

    reaper.ImGui_Separator(ctx)

    -- Copy translation to clipboard
    local trans = (seg.translations and seg.translations[lang]) or ''
    reaper.ImGui_BeginDisabled(ctx, trans == '')
    if reaper.ImGui_Selectable(ctx, 'Copy translation to clipboard##ctx_cp_' .. seg.id, false) then
      if reaper.CF_SetClipboard then
        reaper.CF_SetClipboard(trans)
        mode_module.set_status(state, 'Translation copied.', theme.COLORS.text_dim)
      else
        mode_module.set_status(state, 'CF_SetClipboard nieobecne (SWS not installed).', theme.COLORS.status_stale)
      end
    end
    reaper.ImGui_EndDisabled(ctx)

    reaper.ImGui_Separator(ctx)

    -- Delete segment (destructive — confirm)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.danger)
    if reaper.ImGui_Selectable(ctx, 'Delete segment (destructive)##ctx_del_' .. seg.id, false) then
      local choice = reaper.MB(
        ('Delete segment %s?\n\n'):format(seg.id)
          .. ('Source: %s\n\n'):format((seg.source_text or ''):sub(1, 80))
          .. 'Removes segment z project + all dub items dla target languages.\n'
          .. 'Cannot undo via Cmd+Z (mode operation).',
        'Delete segment', 1)
      if choice == 1 then
        mode_module.delete_segment(state, seg.id)
      end
    end
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_EndPopup(ctx)
  end
end

----------------------------------------------------------------------------
-- W2 M2 (PHASE-W2 §3, wariant A): popover suwaka tempa per segment.
-- Otwierany klikiem w pill statusu lub przyciskiem Stretch… (GAP/OVERRUN).
-- Zwykły BeginPopup zakotwiczony przy pillu (nie modal — Esc/klik poza
-- zamyka; popup_keep_top zbędny). Wartość w trakcie gestu żyje w
-- ms.fit_slider_vals[seg.id]; commit DOPIERO na IsItemDeactivatedAfterEdit
-- → 1 refit = 1 Undo block per gest (inv #4).
----------------------------------------------------------------------------
local function render_fit_popover(ctx, seg, lang, ms, state, mode_module)
  if not reaper.ImGui_BeginPopup(ctx, 'dub_fit_pop_' .. seg.id) then return end
  local fit      = seg.dub_fit and seg.dub_fit[lang]
  local override = seg.dub_stretch_override and seg.dub_stretch_override[lang]
  local busy     = mode_module.is_segment_busy(state, seg.id)
  local auto_rate = (fit and fit.applied_rate) or 1.0

  ms.fit_slider_vals = ms.fit_slider_vals or {}
  if reaper.ImGui_IsWindowAppearing(ctx) then
    ms.fit_slider_vals[seg.id] = override or auto_rate
  end
  local cur = ms.fit_slider_vals[seg.id] or override or auto_rate

  reaper.ImGui_Text(ctx, 'Speech tempo')
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_Text(ctx, 'lower = faster speech · 1.00x = natural TTS pace · higher = slower')
  if fit then
    local extra = ''
    if (fit.gap_secs or 0) > 0.05 then
      extra = (' · silence after speech %.1fs'):format(fit.gap_secs)
    elseif (fit.overrun_secs or 0) > 0.001 then
      extra = (' · overlaps next line %.1fs'):format(fit.overrun_secs)
    end
    reaper.ImGui_Text(ctx, ('Now: %.2fx (%s)%s'):format(
      fit.applied_rate or 1, override and 'custom' or 'auto', extra))
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)

  if busy then reaper.ImGui_BeginDisabled(ctx) end
  reaper.ImGui_SetNextItemWidth(ctx, 240)
  local rv, v = reaper.ImGui_SliderDouble(ctx, '##fit_slider_' .. seg.id, cur,
    mode_module.STRETCH_OVERRIDE_MIN, mode_module.STRETCH_OVERRIDE_MAX, '%.2fx')
  if rv then ms.fit_slider_vals[seg.id] = v end
  if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
    mode_module.set_stretch_override(state, seg.id,
      ms.fit_slider_vals[seg.id] or cur)
    ms.fit_slider_vals[seg.id] = nil
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if override then
    if reaper.ImGui_SmallButton(ctx, 'Reset##fit_rst_' .. seg.id) then
      mode_module.clear_stretch_override(state, seg.id)
      ms.fit_slider_vals[seg.id] = nil
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, 'Back to automatic tempo (the fit ladder decides again).')
    end
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_Text(ctx, 'auto')
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  if busy then
    reaper.ImGui_EndDisabled(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_Text(ctx, 'Generating… wait for this segment to finish.')
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  reaper.ImGui_EndPopup(ctx)
end

----------------------------------------------------------------------------
-- Floating popup editor dla inline edit (Source / Translation cells).
-- (audit M3-1: extracted z render_segments_table — mechaniczne przeniesienie.)
-- Opens at mouse coords on double-click; wider than table cell so text
-- wraps naturally (ImGui InputTextMultiline doesn't word-wrap natively).
----------------------------------------------------------------------------
local function render_inline_edit_popup(ctx, state, project, mode_module)
  local ms_pop = state.modes and state.modes.dubbing or {}
  if not ms_pop.inline_edit then return end
  local edit = ms_pop.inline_edit
  local popup_id = '##inline_edit_popup'
  -- W3: szerokość/wysokość + pozycja clampowane do work area viewportu —
  -- sztywne 720px przy pozycji mouse-80 uciekało poza ekran przy prawej/
  -- dolnej krawędzi na mniejszych monitorach.
  local pw, ph_min, ph_max = 720, 240, 800
  local vx, vy, vw, vh = theme.viewport_work_rect(ctx)
  if vw then
    pw     = math.min(pw, math.floor(vw * 0.9))
    ph_max = math.min(ph_max, math.floor(vh * 0.9))
  end
  if edit.open_pending then
    if edit.popup_x and edit.popup_y then
      local px, py = edit.popup_x, edit.popup_y
      if vw then
        px = math.max(vx + 8, math.min(px, vx + vw - pw - 8))
        py = math.max(vy + 8, math.min(py, vy + vh - ph_min - 8))
      end
      reaper.ImGui_SetNextWindowPos(ctx, px, py)
    end
    reaper.ImGui_OpenPopup(ctx, popup_id)
    edit.open_pending = nil
  end
  -- Re-assert size every frame to prevent ImGui auto-fit shrinking. Width
  -- locked, height can grow (constraint ph_min..ph_max).
  if reaper.ImGui_SetNextWindowSizeConstraints then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, pw, ph_min, pw, ph_max)
  else
    reaper.ImGui_SetNextWindowSize(ctx, pw, ph_min)
  end
  if reaper.ImGui_BeginPopup(ctx, popup_id) then
    local label = (edit.field == 'source')
                  and ('Edit source — ' .. (edit.seg_id or ''))
                  or  ('Edit translation (' .. (edit.lang or '?'):upper() .. ') — ' .. (edit.seg_id or ''))
    theme.push_heading(ctx)
    reaper.ImGui_Text(ctx, label)
    theme.pop_heading(ctx)
    reaper.ImGui_Spacing(ctx)

    if edit.just_entered then
      reaper.ImGui_SetKeyboardFocusHere(ctx, 0)
      edit.just_entered = nil
    end
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local rv_e, new_v = reaper.ImGui_InputTextMultiline(ctx,
      '##inline_edit_buf', edit.buffer, -1, 180)
    if rv_e then edit.buffer = new_v end

    -- Esc cancels (popup closes)
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      ms_pop.inline_edit = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    -- Ctrl/Cmd+Enter commits
    local mod_super = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Super())
    local mod_ctrl  = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
    if (mod_super or mod_ctrl) and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) then
      commit_inline_edit(state, ms_pop, project, mode_module)
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_Spacing(ctx)
    if theme.button_primary(ctx, 'Save') then
      commit_inline_edit(state, ms_pop, project, mode_module)
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    if reaper.ImGui_Button(ctx, 'Cancel') then
      ms_pop.inline_edit = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_Text(ctx, '(Esc cancels · Ctrl/Cmd+Enter saves · click outside discards)')
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_EndPopup(ctx)
  else
    -- Popup closed externally (click outside) — discard pending edit
    ms_pop.inline_edit = nil
  end
end

-- Persistent panel-local UI state (NIE w state.modes.dubbing — to UI buffers,
-- nie data model).
local s = {
  -- Start Dubbing modal buffers
  start_modal_initialized = false,
  start_source_kind       = 'mixed_single',   -- 'mixed_single' | 'multi_track'
  start_target_langs      = {},               -- array of selected lang codes
  start_lang_input_buf    = '',               -- "Add language" input
  start_style_preset      = 'drama_modern',
  start_tts_model         = '',               -- '' = use config default
  start_voice_isolator    = false,
  -- W2 M3 cz.2: Match cast modal buffers (snapshot propozycji + zaznaczenia)
  match_cast_pending_open = false,
  match_cast_rows         = nil,
  match_cast_sel          = {},
}

-- Common target language presets (user can also type custom ISO 639-1 code).
local COMMON_LANGS = {
  { code = 'en', label = 'English (en)' },
  { code = 'pl', label = 'Polish (pl)' },
  { code = 'es', label = 'Spanish (es)' },
  { code = 'de', label = 'German (de)' },
  { code = 'fr', label = 'French (fr)' },
  { code = 'it', label = 'Italian (it)' },
  { code = 'pt', label = 'Portuguese (pt)' },
  { code = 'nl', label = 'Dutch (nl)' },
  { code = 'sv', label = 'Swedish (sv)' },
  { code = 'no', label = 'Norwegian (no)' },
  { code = 'da', label = 'Danish (da)' },
  { code = 'fi', label = 'Finnish (fi)' },
  { code = 'cs', label = 'Czech (cs)' },
  { code = 'uk', label = 'Ukrainian (uk)' },
  { code = 'ru', label = 'Russian (ru)' },
  { code = 'tr', label = 'Turkish (tr)' },
  { code = 'ar', label = 'Arabic (ar)' },
  { code = 'hi', label = 'Hindi (hi)' },
  { code = 'ja', label = 'Japanese (ja)' },
  { code = 'ko', label = 'Korean (ko)' },
  { code = 'zh', label = 'Chinese (zh)' },
}

local function lang_label(code)
  for _, l in ipairs(COMMON_LANGS) do
    if l.code == code then return l.label end
  end
  return code  -- custom code, show as-is
end

local function tts_model_label(model_id)
  if model_id == 'eleven_multilingual_v2' then return 'Multilingual v2' end
  if model_id == 'eleven_v3'              then return 'Eleven v3' end
  -- W2 M1: oficjalnie deprecated (migrate → flash_v2_5, funkcjonalnie
  -- równoważny); enum zostaje dla projektów już na turbo.
  if model_id == 'eleven_turbo_v2_5'      then return 'Turbo v2.5 (deprecated — use Flash)' end
  if model_id == 'eleven_flash_v2_5'      then return 'Flash v2.5' end
  return model_id or '?'
end

----------------------------------------------------------------------------
-- Idle view (no active project)
----------------------------------------------------------------------------
local function render_idle(ctx, state, mode_module)
  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local pad_top = math.max(40, math.floor((avail_h or 200) / 6))
  reaper.ImGui_Dummy(ctx, 1, pad_top)

  local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx)) or 600
  local card_w = math.min(560, avail_w - 40)
  local left_pad = math.max(20, math.floor((avail_w - card_w) / 2))

  reaper.ImGui_Dummy(ctx, left_pad, 1)
  reaper.ImGui_SameLine(ctx, 0, 0)

  -- Card child container
  if reaper.ImGui_BeginChild(ctx, '##dub_idle_card', card_w, 240, 0,
      reaper.ImGui_WindowFlags_NoScrollbar()) then
    reaper.ImGui_Dummy(ctx, 1, 24)
    reaper.ImGui_Indent(ctx, 24)
    theme.push_heading(ctx)
    reaper.ImGui_Text(ctx, 'Dubbing — REAPER-native dubbing studio')
    theme.pop_heading(ctx)
    reaper.ImGui_Dummy(ctx, 1, 4)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_TextWrapped(ctx,
      'Translate + voice-clone + speak source audio in target languages. '
      .. 'All segments live as REAPER items on per-speaker tracks — frame-accurate, '
      .. 'native undo, native render.')
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Dummy(ctx, 1, 16)

    local has_llm = config.effective_llm_provider() ~= nil
    if not has_llm then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
      reaper.ImGui_TextWrapped(ctx,
        'No LLM provider configured. Open Settings -> Dubbing tab and add at least '
        .. 'one API key (Anthropic / OpenAI / Gemini / DeepSeek) before starting.')
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_Dummy(ctx, 1, 8)
    end

    reaper.ImGui_BeginDisabled(ctx, not has_llm)
    if theme.button_primary(ctx, 'Start dubbing project') then
      local ms = mode_module.init_state(state)
      ms.start_modal_pending_open = true
    end
    reaper.ImGui_EndDisabled(ctx)

    reaper.ImGui_Unindent(ctx, 24)
    reaper.ImGui_EndChild(ctx)
  end
end

----------------------------------------------------------------------------
-- Header bar: target language tabs + TTS model dropdown
----------------------------------------------------------------------------
local function render_project_header(ctx, state, project, mode_module)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Target:')

  for _, lang in ipairs(project.target_languages) do
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    local active = lang == project.active_target_language
    if active then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), theme.COLORS.primary)
    end
    if reaper.ImGui_SmallButton(ctx, '[' .. lang:upper() .. ']##lang_' .. lang) then
      mode_module.set_active_target_lang(state, lang)
    end
    if active then reaper.ImGui_PopStyleColor(ctx, 1) end
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if reaper.ImGui_SmallButton(ctx, '+ Add##add_lang') then
    reaper.ImGui_OpenPopup(ctx, 'add_target_lang')
  end
  if reaper.ImGui_BeginPopup(ctx, 'add_target_lang') then
    reaper.ImGui_Text(ctx, 'Add target language:')
    reaper.ImGui_Spacing(ctx)
    for _, l in ipairs(COMMON_LANGS) do
      local already = false
      for _, existing in ipairs(project.target_languages) do
        if existing == l.code then already = true; break end
      end
      reaper.ImGui_BeginDisabled(ctx, already)
      if reaper.ImGui_Selectable(ctx, l.label, false) then
        local ok_add, _, inherit = dub_project.add_target_language(project, l.code)
        if ok_add then
          mode_module.mark_dirty(state)
          -- W2 M3 cz.2: ciche dziedziczenie castu + status (user decision).
          if inherit then
            mode_module.set_status(state,
              ('Voices inherited from %s for %d speaker(s) — adjust per speaker if needed.')
                :format((inherit.inherited_from or '?'):upper(), inherit.count),
              theme.COLORS.status_done)
          end
        end
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_EndDisabled(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- TTS model dropdown + Edit + Close: right-aligned cluster.
  -- Wszystkie 3 elementy razem ~325px (dropdown 200 + Edit 45 + Close 50 + 2x spacing ~14).
  -- Push right via SameLine offset gdy avail_w pozwala.
  reaper.ImGui_SameLine(ctx)
  local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx)) or 200
  local model_w = 200
  local right_cluster_w = model_w + 130   -- 130 = Edit + Close + spacings + margin
  if avail_w > right_cluster_w + 16 then
    reaper.ImGui_SameLine(ctx, 0, math.max(8, avail_w - right_cluster_w))
  end
  reaper.ImGui_SetNextItemWidth(ctx, model_w)
  if reaper.ImGui_BeginCombo(ctx, '##dub_tts_model_header',
      'TTS: ' .. tts_model_label(project.tts_model)) then
    for _, m in ipairs({ 'eleven_multilingual_v2', 'eleven_v3', 'eleven_turbo_v2_5', 'eleven_flash_v2_5' }) do
      if reaper.ImGui_Selectable(ctx, tts_model_label(m), project.tts_model == m) then
        if project.tts_model ~= m then
          project.tts_model = m
          -- TTS model affects audio only — translations remain valid.
          mode_module.propagate_stale(state, 'all_langs', 'dub_only')
          mode_module.set_status(state,
            ('TTS model changed → existing dubs marked stale. Click Generate dub to re-render.'),
            theme.COLORS.status_stale)
        end
        mode_module.mark_dirty(state)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if reaper.ImGui_SmallButton(ctx, 'Edit##edit_project') then
    s.edit_modal_pending_open = true
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Edit project settings (style preset, voice isolator, delete project).')
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if reaper.ImGui_SmallButton(ctx, 'Close##close_project') then
    local choice = reaper.MB(
      'Close current Dubbing project?\n\n'
        .. 'Project state is preserved on disk; you can re-open later via Start dubbing '
        .. '(M2 will add project selector). REAPER tracks/items remain unchanged.',
      'Close Dubbing project', 1)
    if choice == 1 then
      -- M4-3: klony IVC utworzone przez projekt → pytanie Delete/Keep
      -- PO potwierdzeniu zamknięcia (Cancel tutaj = projekt zostaje otwarty,
      -- nic nie skasowane). Default Delete per decyzja 2026-07-02.
      local proceed = prompt_clone_cleanup(state, mode_module)
      if proceed then mode_module.close_project(state) end
    end
  end
end

----------------------------------------------------------------------------
-- Translation context section — delegated to modules/gui/dubbing_context.lua
-- (5 editable dropdowns + free-text + glossary launcher + stale propagation).
----------------------------------------------------------------------------
local function render_context_section(ctx, state, project, mode_module)
  dubbing_context.render(ctx, state, project, mode_module)
end

----------------------------------------------------------------------------
-- Cast sidebar (left of segments)
-- M1 Part 2: real voice cloning via "Clone from selection" path (other 3 paths
-- deferred do M3 polish per spec §14).
----------------------------------------------------------------------------
local function render_cast_sidebar(ctx, state, project, mode_module, w, h)
  local ms = state.modes and state.modes.dubbing or {}
  local collapsed = ms.cast_sidebar_collapsed == true

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x1C1C1CB0)
  if reaper.ImGui_BeginChild(ctx, '##dub_cast_sidebar', w, h, 0, 0) then
    if collapsed then
      -- PM9: collapsed strip — chevron expand + vertical 'CAST' letters.
      reaper.ImGui_Dummy(ctx, 1, theme.SPACING.sm)
      reaper.ImGui_Indent(ctx, 6)
      if reaper.ImGui_SmallButton(ctx, '>##cast_expand') then
        ms.cast_sidebar_collapsed = false
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, 'Expand CAST sidebar')
      end
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
      reaper.ImGui_Text(ctx, 'C')
      reaper.ImGui_Text(ctx, 'A')
      reaper.ImGui_Text(ctx, 'S')
      reaper.ImGui_Text(ctx, 'T')
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_Unindent(ctx, 6)
      reaper.ImGui_EndChild(ctx)
      reaper.ImGui_PopStyleColor(ctx, 1)
      return
    end

    -- Expanded view (default).
    reaper.ImGui_Dummy(ctx, 1, theme.SPACING.sm)
    reaper.ImGui_Indent(ctx, theme.SPACING.md)
    -- Header: 'CAST' + < collapse chevron right-aligned
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, 'CAST')
    reaper.ImGui_SameLine(ctx)
    local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx)) or 100
    reaper.ImGui_SameLine(ctx, 0, math.max(8, avail_w - 28))
    if reaper.ImGui_SmallButton(ctx, '<##cast_collapse') then
      ms.cast_sidebar_collapsed = true
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, 'Collapse CAST sidebar (free up space dla segments table)')
    end
    reaper.ImGui_Spacing(ctx)

    -- W2 M3 cz.2: Match cast — rejestr postaci projektu zna głosy pasujące
    -- do mówców (match po nazwie; postaci z TEGO materiału mają priorytet).
    -- Registry proponuje, nigdy nie nadpisuje cicho → modal z podglądem.
    local match_rows = mode_module.match_cast_rows
                   and mode_module.match_cast_rows(state)
    if match_rows and #match_rows > 0 then
      if theme.button_neutral(ctx,
           ('Match cast (%d)##dub_match_cast'):format(#match_rows), -1, 0) then
        s.match_cast_rows = match_rows
        s.match_cast_sel  = {}
        for _, r in ipairs(match_rows) do
          -- Default: bez konfliktu ON; konflikt (jest już INNY głos) OFF.
          s.match_cast_sel[r.speaker_id] = not r.conflict
        end
        s.match_cast_pending_open = true
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          'The project cast registry knows voices for some of these speakers\n(matched by name; characters from this source material first).\nOpens a preview — nothing is applied silently.')
      end
      reaper.ImGui_Spacing(ctx)
    end

    local lang = project.active_target_language

    if #project.speakers == 0 then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
      reaper.ImGui_TextWrapped(ctx, 'No speakers yet.')
      reaper.ImGui_TextWrapped(ctx, 'Start a project and let the STT pipeline populate speakers from source audio.')
      reaper.ImGui_PopStyleColor(ctx, 1)
    else
      local ms = state.modes and state.modes.dubbing or {}
      for _, spk in ipairs(project.speakers) do
        reaper.ImGui_PushID(ctx, 'spk_' .. spk.id)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_Text(ctx, '* ' .. (spk.label or spk.id))

        local cur_voice    = spk.voices and spk.voices[lang] or nil
        local cur_name     = spk.voice_names and spk.voice_names[lang] or 'voice'
        local clone_active = ms.clone_handles and ms.clone_handles[spk.id] ~= nil
        local similar_active = ms.similar_handles and ms.similar_handles[spk.id] ~= nil

        if cur_voice and cur_voice ~= '' then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_done)
          reaper.ImGui_Text(ctx, ('  %s: OK'):format(lang:upper()))
          reaper.ImGui_PopStyleColor(ctx, 1)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
          reaper.ImGui_Text(ctx, '  ' .. cur_name)
          reaper.ImGui_PopStyleColor(ctx, 1)
        elseif clone_active then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_running)
          reaper.ImGui_Text(ctx, '  Cloning...')
          reaper.ImGui_PopStyleColor(ctx, 1)
        elseif similar_active then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_running)
          reaper.ImGui_Text(ctx, '  Searching similar...')
          reaper.ImGui_PopStyleColor(ctx, 1)
        else
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
          reaper.ImGui_Text(ctx, ('  %s: (no voice)'):format(lang:upper()))
          reaper.ImGui_PopStyleColor(ctx, 1)
        end

        -- Voice picker / clone / similar — 3 paths.
        -- When voice already set: collapsed under "Change voice v" popup
        --   (avoids cluttering sidebar w many speakers).
        -- When no voice: all 3 buttons visible inline (user needs to pick).
        local has_voice = cur_voice and cur_voice ~= ''

        local function path_pick_voice()
          voice_picker.open({
            state            = state,
            current_voice_id = cur_voice,
            allow_clear      = true,
            on_pick = function(voice_id, voice_name)
              local prev_voice_id = spk.voices and spk.voices[lang]
              if voice_id then
                spk.voices[lang]      = voice_id
                spk.voice_names[lang] = voice_name or 'voice'
              else
                spk.voices[lang]      = nil
                spk.voice_names[lang] = nil
              end
              -- Voice changed → invalidate existing dubs dla tego speakera (dub_only)
              if prev_voice_id and prev_voice_id ~= voice_id then
                local n = mode_module.propagate_speaker_stale(state, spk.id, lang, 'dub_only') or 0
                if n > 0 then
                  mode_module.set_status(state,
                    ('Voice set for %s · %d existing dub(s) marked stale.'):format(spk.label or spk.id, n),
                    theme.COLORS.status_stale)
                else
                  mode_module.set_status(state, ('Voice set for %s'):format(spk.label or spk.id), theme.COLORS.status_done)
                end
              else
                mode_module.set_status(state, ('Voice set for %s'):format(spk.label or spk.id), theme.COLORS.status_done)
              end
              mode_module.mark_dirty(state)
            end,
          })
        end

        local function path_clone()
          -- M4-1 (audit 2026-07): Flow A mixed_single z gotowymi segmentami →
          -- sampel IVC budowany z segmentów TEGO speakera. HOTFIX 2026-07-11
          -- (user-caught: 2 klony wytrenowane na CISZY): segmenty żyją w
          -- czasie PROJEKTU (project_offset dodany przy build — patrz
          -- modes/dubbing chunks_input), a concat_regions oczekuje czasu
          -- PLIKU źródłowego — konwersja + twardy guard na okno źródła
          -- (żaden region poza oknem = NIE trenujemy na ciszy).
          if project.source_kind == 'mixed_single' then
            local src_item = mode_module.resolve_source_item(state)
            local regions = dub_project.speaker_sample_regions(project, spk.id,
              { max_secs = audio_concat.MAX_DURATION_SECS })
            if src_item and #regions > 0 then
              local d_pos  = reaper.GetMediaItemInfo_Value(src_item, 'D_POSITION') or 0
              local take   = reaper.GetActiveTake(src_item)
              local d_offs = take and reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
              local i_len  = reaper.GetMediaItemInfo_Value(src_item, 'D_LENGTH') or 0
              local shift  = d_offs - d_pos          -- P (projekt) → S (plik): S = P + shift
              local src_lo, src_hi = d_offs, d_offs + i_len
              local converted, total = {}, 0
              for _, r in ipairs(regions) do
                local s0 = math.max(src_lo, r.start + shift)
                local e0 = math.min(src_hi, r['end'] + shift)
                if e0 - s0 > 0.25 then
                  converted[#converted + 1] = { start = s0, ['end'] = e0 }
                  total = total + (e0 - s0)
                end
              end
              -- Guard: <5 s realnej mowy w oknie źródła = coś nie gra z osiami
              -- czasu / segmentami → JAWNY fallback, nigdy trening na ciszy.
              if #converted > 0 and total >= 5.0 then
                local sample_path, perr = audio_concat.concat_regions(src_item, converted, {})
                if sample_path then
                  mode_module.set_status(state,
                    ('Clone sample: %.0fs of %s\'s speech from %d region(s) — training…')
                      :format(total, spk.label or spk.id, #converted), theme.COLORS.text_dim)
                  mode_module.request_clone_for_speaker(state, spk.id, sample_path)
                  return
                end
                mode_module.set_status(state,
                  ('Speaker sample render failed (%s) — falling back to selected item.')
                    :format(tostring(perr)), theme.COLORS.status_stale)
              else
                mode_module.set_status(state,
                  'Speaker segments do not overlap the source item audio — select the item and use the picker instead.',
                  theme.COLORS.status_stale)
              end
            end
          end

          local item = reaper.GetSelectedMediaItem(0, 0)
          if not item then
            mode_module.set_status(state, 'Select audio item in REAPER to use as clone sample.', theme.COLORS.status_stale)
            return
          end

          -- NS-G: check diarize cache → multi-speaker → open speaker_picker.
          -- Falls back to legacy first-item flow gdy cache miss lub single
          -- speaker. Known limitation: dubbing project's initial diarize was
          -- run on chunked source WAVs (different cache key); user może
          -- potrzebować pre-run Repair STT (z diarize) na item żeby populate
          -- cache w geometry-stable namespace.
          local cache_key = compute_item_cache_key(item)
          local diarize_transcript
          if cache_key then
            diarize_transcript = stt.check_diarize_cache_for_item(item, cache_key)
          end

          if diarize_transcript and count_unique_speakers_in(diarize_transcript) >= 2 then
            -- Build Scribe local_id → user-facing label map z project speakers
            -- (per NS-G fix #1: pokazuj "Host"/"Mati" zamiast "speaker_0/1").
            local label_map = {}
            local suggested_scribe_id
            for _, ps in ipairs(project.speakers or {}) do
              for _, lid in ipairs(ps.local_ids or {}) do
                label_map[lid] = ps.label or ps.id
                -- Pre-select speaker that maps do current cast row (spk)
                if ps.id == spk.id and not suggested_scribe_id then
                  suggested_scribe_id = lid
                end
              end
            end
            speaker_picker.open({
              diarize_transcript    = diarize_transcript,
              source_item           = item,
              speaker_label_map     = label_map,
              suggested_speaker_id  = suggested_scribe_id,
              on_train = function(scribe_speaker_id, regions)
                local sample_path, perr = audio_concat.concat_regions(item, regions, {})
                if not sample_path then
                  mode_module.set_status(state,
                    'Concat failed: ' .. tostring(perr), theme.COLORS.status_error)
                  return
                end
                mode_module.request_clone_for_speaker(state, spk.id, sample_path)
              end,
              on_cancel = function()
                mode_module.set_status(state, 'Clone cancelled.', theme.COLORS.text_dim)
              end,
            })
            return
          end

          -- Legacy single-speaker / no-cache path
          local audio_path, perr = require('modules.audio_render').prepare_audio_for_api(item)
          if audio_path then
            mode_module.request_clone_for_speaker(state, spk.id, audio_path)
            -- M4-1: na zmiksowanym źródle ta ścieżka bierze CAŁY item —
            -- ostrzeż zamiast milczeć (sampel zawiera wszystkich mówców).
            if project.source_kind == 'mixed_single' then
              mode_module.set_status(state,
                'Warning: clone sample is the whole selected item — it may contain ALL speakers.',
                theme.COLORS.status_stale)
            end
          else
            mode_module.set_status(state, ('Cannot prepare audio: %s'):format(perr or '?'), theme.COLORS.status_error)
          end
        end

        local function path_similar()
          local item = reaper.GetSelectedMediaItem(0, 0)
          if item then
            local audio_path, perr = require('modules.audio_render').prepare_audio_for_api(item)
            if audio_path then
              mode_module.request_similar_for_speaker(state, spk.id, audio_path)
            else
              mode_module.set_status(state, ('Cannot prepare audio: %s'):format(perr or '?'), theme.COLORS.status_error)
            end
          else
            mode_module.set_status(state, 'Select audio sample in REAPER to find similar voices.', theme.COLORS.status_stale)
          end
        end

        local function path_design()
          -- M4.1: Voice Design — text-to-voice z promptu.
          -- Default sample text: first segment's source text if available.
          local default_sample
          for _, seg in ipairs(project.segments or {}) do
            if seg.speaker_id == spk.id and seg.source_text and #seg.source_text >= 20 then
              default_sample = seg.source_text:sub(1, 800)   -- cap dla API
              break
            end
          end
          dubbing_voice_design.open({
            speaker_id    = spk.id,
            speaker_label = spk.label or spk.id,
            default_name  = (spk.label or spk.id) .. '_designed_' .. lang,
            default_sample_text = default_sample,
            on_voice_created = function(voice_id, voice_name)
              local prev_voice_id = spk.voices and spk.voices[lang]
              spk.voices[lang]      = voice_id
              spk.voice_names[lang] = voice_name or 'designed'
              -- Voice changed → invalidate existing dubs dla tego speakera
              if prev_voice_id and prev_voice_id ~= voice_id then
                local n = mode_module.propagate_speaker_stale(state, spk.id, lang, 'dub_only') or 0
                if n > 0 then
                  mode_module.set_status(state,
                    ('Voice designed for %s · %d existing dub(s) marked stale.'):format(spk.label or spk.id, n),
                    theme.COLORS.status_stale)
                else
                  mode_module.set_status(state, ('Voice designed and assigned to %s'):format(spk.label or spk.id), theme.COLORS.status_done)
                end
              else
                mode_module.set_status(state, ('Voice designed and assigned to %s'):format(spk.label or spk.id), theme.COLORS.status_done)
              end
              mode_module.mark_dirty(state)
            end,
          })
        end

        if has_voice then
          -- Compact: single button opens popup z 3 path options + Clear voice
          if reaper.ImGui_SmallButton(ctx, 'Change voice v##chv_' .. spk.id) then
            reaper.ImGui_OpenPopup(ctx, 'voice_actions_' .. spk.id)
          end
          if reaper.ImGui_BeginPopup(ctx, 'voice_actions_' .. spk.id) then
            if reaper.ImGui_Selectable(ctx, 'Pick voice from library...', false) then
              path_pick_voice()
              reaper.ImGui_CloseCurrentPopup(ctx)
            end
            if reaper.ImGui_Selectable(ctx, 'Re-clone from REAPER item', false) then
              path_clone()
              reaper.ImGui_CloseCurrentPopup(ctx)
            end
            if reaper.ImGui_Selectable(ctx, 'Find similar from REAPER item', false) then
              path_similar()
              reaper.ImGui_CloseCurrentPopup(ctx)
            end
            if reaper.ImGui_Selectable(ctx, 'Design voice from prompt...', false) then
              path_design()
              reaper.ImGui_CloseCurrentPopup(ctx)
            end
            reaper.ImGui_Separator(ctx)
            if reaper.ImGui_Selectable(ctx, 'Voice settings (stability / similarity / speed)...', false) then
              -- M4+: per-speaker voice settings dla active lang
              local cur = (spk.voice_settings_per_lang and spk.voice_settings_per_lang[lang]) or nil
              dubbing_voice_settings.open({
                title    = 'Voice settings — ' .. (spk.label or spk.id),
                subtitle = ('%s · %s'):format(cur_name, lang:upper()),
                current_settings = cur,
                has_override = false,
                allow_clear  = false,
                on_apply = function(new_settings)
                  if not spk.voice_settings_per_lang then spk.voice_settings_per_lang = {} end
                  spk.voice_settings_per_lang[lang] = new_settings
                  mode_module.mark_dirty(state)
                  -- kind='dub_only' — voice settings nie inwalidują translation text.
                  mode_module.propagate_stale(state, lang, 'dub_only')
                  mode_module.set_status(state,
                    ('Voice settings updated for %s. Click Generate dub to re-render affected segments.'):format(spk.label or spk.id),
                    theme.COLORS.status_stale)
                end,
              })
              reaper.ImGui_CloseCurrentPopup(ctx)
            end
            reaper.ImGui_Separator(ctx)
            if reaper.ImGui_Selectable(ctx, 'Clear voice (remove)', false) then
              local prev_voice_id = spk.voices and spk.voices[lang]
              spk.voices[lang]      = nil
              spk.voice_names[lang] = nil
              -- Mark existing dubs stale tak że status w segments nie kłamie
              -- (DUBBED green bez voice = misleading; user musi przypisać nowy).
              if prev_voice_id then
                mode_module.propagate_speaker_stale(state, spk.id, lang, 'dub_only')
              end
              mode_module.mark_dirty(state)
              mode_module.set_status(state,
                ('Voice cleared for %s · assign a new voice before Generate dub.'):format(spk.label or spk.id),
                theme.COLORS.status_stale)
              reaper.ImGui_CloseCurrentPopup(ctx)
            end
            reaper.ImGui_EndPopup(ctx)
          end
        else
          -- Expanded: all 3 buttons stacked (speaker needs initial voice).
          if reaper.ImGui_SmallButton(ctx, 'Pick voice...##pick_' .. spk.id) then
            path_pick_voice()
          end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx,
              'Browse your voice library + favorites + Voice Library. Search / filter / preview.')
          end
          if reaper.ImGui_SmallButton(ctx, 'Clone from item##clone_' .. spk.id) then
            path_clone()
          end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx,
              'IVC: clone from the REAPER-selected audio sample (30s-2min of clean voice).\n'
                .. 'Creates a new ElevenLabs voice tied to this project.')
          end
          if reaper.ImGui_SmallButton(ctx, 'Find similar from item##sim_' .. spk.id) then
            path_similar()
          end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx,
              'Find similar voices via ElevenLabs /v1/similar-voices.\n'
                .. 'Top 10 candidates from public library matched to REAPER-selected sample.')
          end
          if reaper.ImGui_SmallButton(ctx, 'Design voice from prompt##design_' .. spk.id) then
            path_design()
          end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx,
              'Voice Design: write plain-English description (tone / age / accent /\n'
                .. 'pace) + sample text -> ElevenLabs generates N preview voices -> pick one.\n'
                .. 'Creates permanent voice w your library.')
          end
        end

        reaper.ImGui_PopID(ctx)
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Spacing(ctx)
      end
    end

    reaper.ImGui_Unindent(ctx, theme.SPACING.md)
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
end

----------------------------------------------------------------------------
-- Segments table (right of cast)
----------------------------------------------------------------------------
local function render_segments_table(ctx, state, project, mode_module, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x1C1C1CB0)
  if reaper.ImGui_BeginChild(ctx, '##dub_segments_table', w, h, 0, 0) then
    reaper.ImGui_Dummy(ctx, 1, theme.SPACING.sm)
    reaper.ImGui_Indent(ctx, theme.SPACING.md)
    local lang = project.active_target_language or '?'
    reaper.ImGui_Text(ctx, ('Segments — showing %s translations'):format(lang:upper()))
    reaper.ImGui_Spacing(ctx)

    if #project.segments == 0 then
      local ms = state.modes and state.modes.dubbing or {}
      local phase = ms.phase or 'idle'

      -- Sticky error banner — survives status_msg overwrite, persists until retry.
      if ms.last_run_error and ms.last_run_error ~= '' then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_error)
        reaper.ImGui_TextWrapped(ctx, 'Pipeline error: ' .. ms.last_run_error)
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_Spacing(ctx)
      end

      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
      if phase == 'chunking' or phase == 'isolating' then
        reaper.ImGui_TextWrapped(ctx, 'Preparing source audio...')
      elseif phase == 'transcribing' then
        if project.source_kind == 'multi_track' then
          reaper.ImGui_TextWrapped(ctx, 'Transcribing per-track audio (Flow B, no diarize)...')
        else
          reaper.ImGui_TextWrapped(ctx, 'Transcribing chunks via Scribe v2 (diarized)...')
        end
      elseif phase == 'matching_speakers' then
        reaper.ImGui_TextWrapped(ctx, 'Speaker matching modal open — assign detected voices to characters.')
      elseif phase == 'casting_voices' then
        reaper.ImGui_TextWrapped(ctx, 'Pipeline done. Assign voices to speakers in CAST sidebar to enable Translate / Generate.')
      else
        -- idle or ready z empty segments — pipeline didn't run yet or failed
        if project.source_kind == 'mixed_single' then
          reaper.ImGui_TextWrapped(ctx,
            'No segments yet. Make sure source item is selected in REAPER, then click Re-run pipeline below. '
              .. 'STT pipeline populates segments from source audio.')
        else
          reaper.ImGui_TextWrapped(ctx,
            'No segments yet. Make sure source tracks are selected in REAPER, then click Re-run pipeline below.')
        end
      end
      reaper.ImGui_PopStyleColor(ctx, 1)

      -- Re-run pipeline CTA — visible w idle/ready empty state.
      if phase == 'idle' or phase == 'ready' then
        reaper.ImGui_Spacing(ctx)
        if theme.button_primary(ctx, 'Re-run pipeline') then
          local ok, rerr = mode_module.retry_pipeline(state)
          if not ok then mode_module.set_status(state, rerr or 'Retry failed', theme.COLORS.status_error) end
        end
        if reaper.ImGui_IsItemHovered(ctx) then
          reaper.ImGui_SetTooltip(ctx,
            'Re-validates source + spawns STT pipeline from scratch.\n'
              .. 'Use when the first Start failed (e.g., no item selected)\n'
              .. 'or after loading an old project with no segments yet.')
        end
      end
    else
      local ms = state.modes and state.modes.dubbing or {}

      -- W3 (tabela): chipy filtra statusów z licznikami — szybkie polowanie
      -- na problemy (FAILED/stale/pending) w długich projektach bez
      -- przewijania. Klik = pokaż tylko ten status; ponowny klik lub [All]
      -- = wszystko. Chip renderowany tylko dla statusów obecnych w projekcie.
      do
        local counts, total = {}, #project.segments
        for seg_i, seg in ipairs(project.segments) do
          local _, _, bucket = segment_status(seg, seg_i, lang, state, mode_module)
          counts[bucket] = (counts[bucket] or 0) + 1
        end
        -- Filtr wskazujący pusty bucket (np. wszystko już naprawione) —
        -- auto-reset zamiast pustej tabeli.
        if ms.segment_filter and not counts[ms.segment_filter] then
          ms.segment_filter = nil
        end
        local function filter_chip(bucket_label, count, display)
          local active = (ms.segment_filter == bucket_label)
          if active then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
              (theme.MODE_ACCENTS.dubbing & ~0xFF) | 0x60)
          end
          if reaper.ImGui_SmallButton(ctx, ('%s %d##flt_%s')
              :format(display or bucket_label, count, bucket_label)) then
            ms.segment_filter = active and nil or bucket_label
          end
          if active then reaper.ImGui_PopStyleColor(ctx, 1) end
          reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
        end
        local all_active = (ms.segment_filter == nil)
        if all_active then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),
            (theme.MODE_ACCENTS.dubbing & ~0xFF) | 0x60)
        end
        if reaper.ImGui_SmallButton(ctx, ('All %d##flt_all'):format(total)) then
          ms.segment_filter = nil
        end
        if all_active then reaper.ImGui_PopStyleColor(ctx, 1) end
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
        local CHIP_ORDER = { 'FAILED', 'stale', 'pending', 'WAITING',
                             'GEN...', 'translated', 'DUBBED', 'excluded' }
        for _, b in ipairs(CHIP_ORDER) do
          if counts[b] then filter_chip(b, counts[b]) end
        end
        reaper.ImGui_NewLine(ctx)
        reaper.ImGui_Spacing(ctx)
      end

      -- User-resizable columns (drag column borders to adjust width).
      local flags = reaper.ImGui_TableFlags_RowBg()
                  | reaper.ImGui_TableFlags_BordersInnerH()
                  | reaper.ImGui_TableFlags_BordersInnerV()
                  | reaper.ImGui_TableFlags_Resizable()
      if reaper.ImGui_BeginTable(ctx, 'dub_seg_tbl', 7, flags) then
        reaper.ImGui_TableSetupColumn(ctx, '#',           reaper.ImGui_TableColumnFlags_WidthFixed(),  60)
        reaper.ImGui_TableSetupColumn(ctx, 'Speaker',     reaper.ImGui_TableColumnFlags_WidthFixed(),  90)
        reaper.ImGui_TableSetupColumn(ctx, 'Time',        reaper.ImGui_TableColumnFlags_WidthFixed(),  80)
        reaper.ImGui_TableSetupColumn(ctx, 'Source',      reaper.ImGui_TableColumnFlags_WidthStretch())
        reaper.ImGui_TableSetupColumn(ctx, 'Translation', reaper.ImGui_TableColumnFlags_WidthStretch())
        reaper.ImGui_TableSetupColumn(ctx, 'Status',      reaper.ImGui_TableColumnFlags_WidthFixed(),  120)
        reaper.ImGui_TableSetupColumn(ctx, ' ',           reaper.ImGui_TableColumnFlags_WidthFixed(),  88)
        reaper.ImGui_TableHeadersRow(ctx)
        local sel_set = ms.selected_segment_ids or {}
        -- Cmd (macOS) / Ctrl (Win) toggles add/remove; plain click replaces;
        -- Polish #2 (PM5): Shift+click = range select od anchor (last clicked).
        -- ReaImGui keypress modifiers: check key state via ImGui_IsKeyDown na Modkey.
        local kmod_super = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Super())
        local kmod_ctrl  = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
        local kmod_shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
        local additive_click = kmod_super or kmod_ctrl
        local range_click    = kmod_shift and (ms.last_clicked_seg_id ~= nil)
        -- Source / Translation columns are 0-indexed 3 / 4. Detected via
        -- TableGetHoveredColumn — used to dispatch double-click action:
        --   col 3 → inline edit source
        --   col 4 → inline edit translation
        --   other cols (#, Speaker, Time, Status) → open inspector
        for seg_i, seg in ipairs(project.segments) do
          -- W3 (tabela): status raz na wiersz (wspólne źródło z chipami
          -- filtra); filtr pomija wiersz przez goto (wzorzec continue_chip
          -- z repair_panel — label na końcu bloku pętli jest legalny).
          local st_label, st_color, st_bucket, trans_st, dub_st =
            segment_status(seg, seg_i, lang, state, mode_module)
          if ms.segment_filter and ms.segment_filter ~= st_bucket then
            goto continue_seg
          end
          reaper.ImGui_TableNextRow(ctx)
          if sel_set[seg.id] then
            reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg0(), 0x3470B0AA)
          elseif seg.id == ms.playhead_segment_id then
            -- W3 Pakiet B+: segment pod playheadem (klik na timeline / playback)
            -- — akcent trybu z niską alfą, nie myli się z selekcją (niebieska).
            reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg0(),
              (theme.MODE_ACCENTS.dubbing & ~0xFF) | 0x38)
          elseif seg.dub_excluded then
            -- Subtle dim bg dla excluded interjections — visually marked jako out-of-dub
            reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg0(), 0x4A3A20AA)
          end
          reaper.ImGui_TableNextColumn(ctx)
          local hov_col = reaper.ImGui_TableGetHoveredColumn(ctx)
          if reaper.ImGui_Selectable(ctx, seg.id, false,
              reaper.ImGui_SelectableFlags_SpanAllColumns()
              | reaper.ImGui_SelectableFlags_AllowOverlap()
              | reaper.ImGui_SelectableFlags_AllowDoubleClick()) then
            ms.panel_selection_just_set = true
            -- Double-click: column-dispatched action
            if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
              -- Auto-commit any pending edit before starting new one
              if ms.inline_edit and ms.inline_edit.seg_id ~= seg.id then
                commit_inline_edit(state, ms, project, mode_module)
              end
              if hov_col == 3 or hov_col == 4 then
                local mx, my = reaper.ImGui_GetMousePos(ctx)
                local raw_text = (hov_col == 3) and (seg.source_text or '')
                                                 or ((seg.translations and seg.translations[lang]) or '')
                ms.inline_edit = {
                  seg_id       = seg.id,
                  field        = (hov_col == 3) and 'source' or 'translation',
                  lang         = lang,
                  -- Soft-wrap raw text to approximate visual word-wrap (~70 chars/line)
                  -- since ImGui InputTextMultiline doesn't word-wrap natively.
                  buffer       = soft_wrap_text(raw_text, 70),
                  just_entered = true,
                  open_pending = true,
                  popup_x      = mx - 80,
                  popup_y      = my - 30,
                }
              else
                dubbing_inspector.open(seg.id)
                ms.inspector_pending_seg_id = seg.id
              end
            elseif range_click then
              -- Polish #2 (PM5): Shift+klik = range select od ms.last_clicked_seg_id
              -- do current. Find indices w segments[], iterate min..max → add do sel_set.
              -- Plain Shift+klik EXTENDS existing selection (nie zeruje) — Cmd+Shift+klik
              -- behavior nie distinguished (super takes precedence przez additive_click test
              -- ordering above gdyby zaszedł konflikt; tu kolejność: range FIRST).
              local idx_anchor, idx_current
              for i, sg in ipairs(project.segments) do
                if sg.id == ms.last_clicked_seg_id then idx_anchor = i end
                if sg.id == seg.id then idx_current = i end
                if idx_anchor and idx_current then break end
              end
              if idx_anchor and idx_current then
                local lo, hi = math.min(idx_anchor, idx_current), math.max(idx_anchor, idx_current)
                -- Replace selection (nie additive) — standard range-select semantics.
                ms.selected_segment_ids = {}
                sel_set = ms.selected_segment_ids
                -- Mirror to REAPER: unselect all + select range items.
                reaper.Main_OnCommand(40289, 0)   -- Unselect all items
                local guid_set = {}
                for i = lo, hi do
                  local sg = project.segments[i]
                  sel_set[sg.id] = true
                  local g = sg.item_guids and sg.item_guids[lang]
                  if g and g ~= '' then guid_set[g] = true end
                end
                if next(guid_set) then
                  local count = reaper.CountMediaItems(0)
                  for i = 0, count - 1 do
                    local it = reaper.GetMediaItem(0, i)
                    local _, g = reaper.GetSetMediaItemInfo_String(it, 'GUID', '', false)
                    if guid_set[g] then reaper.SetMediaItemSelected(it, true) end
                  end
                  reaper.UpdateArrange()
                end
                ms.selected_segment_id = seg.id
                -- Anchor stays — kolejne Shift+klik moves end-point, anchor preserved.
              end
            elseif additive_click then
              -- Toggle add/remove without clearing others
              if sel_set[seg.id] then
                sel_set[seg.id] = nil
              else
                sel_set[seg.id] = true
              end
              -- Update primary = this seg (whichever was clicked last)
              ms.selected_segment_id = seg.id
              ms.last_clicked_seg_id = seg.id   -- anchor dla future Shift+klik
              -- Mirror to REAPER: extend selection
              local item_guid = seg.item_guids and seg.item_guids[lang]
              if item_guid and item_guid ~= '' then
                local count = reaper.CountMediaItems(0)
                for i = 0, count - 1 do
                  local it = reaper.GetMediaItem(0, i)
                  local _, g = reaper.GetSetMediaItemInfo_String(it, 'GUID', '', false)
                  if g == item_guid then
                    reaper.SetMediaItemSelected(it, sel_set[seg.id] == true)
                    break
                  end
                end
                reaper.UpdateArrange()
              end
            else
              -- Plain click: replace selection
              ms.selected_segment_ids = { [seg.id] = true }
              sel_set = ms.selected_segment_ids
              ms.selected_segment_id = seg.id
              ms.last_clicked_seg_id = seg.id   -- anchor dla Polish #2 Shift+klik range
              local item_guid = seg.item_guids and seg.item_guids[lang]
              if item_guid and item_guid ~= '' then
                reaper.Main_OnCommand(40289, 0)   -- Unselect all items
                local count = reaper.CountMediaItems(0)
                for i = 0, count - 1 do
                  local it = reaper.GetMediaItem(0, i)
                  local _, g = reaper.GetSetMediaItemInfo_String(it, 'GUID', '', false)
                  if g == item_guid then
                    reaper.SetMediaItemSelected(it, true)
                    break
                  end
                end
                reaper.UpdateArrange()
              end
            end
          end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, 'Click=select · Double-click on Source or Translation cell = edit inline · Double-click elsewhere = inspector · Menu: … button or right-click · Cmd/Ctrl+click = multi-select.')
          end
          -- W3 Pakiet B+: one-shot scroll do segmentu pod playheadem (flaga
          -- z sync_playhead_segment przy ZMIANIE segmentu — ręczny scroll
          -- usera między zmianami nie jest ruszany).
          if ms.playhead_scroll_pending and seg.id == ms.playhead_segment_id then
            reaper.ImGui_SetScrollHereY(ctx, 0.35)
            ms.playhead_scroll_pending = nil
          end
          -- Right-click context menu (per-row actions) — extracted (M3-1)
          render_segment_context_menu(ctx, seg, project, lang, ms, state, mode_module)

          reaper.ImGui_TableNextColumn(ctx)
          local spk = require('modules.dubbing_project').find_speaker(project, seg.speaker_id)
          reaper.ImGui_Text(ctx, spk and (spk.label or spk.id) or (seg.speaker_id or '?'))
          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_Text(ctx, ('%.1fs'):format(seg.t_start or 0))

          -- Source column: full source text wrapped + word count below.
          -- Edit via double-click → opens floating popup editor (rendered after table).
          reaper.ImGui_TableNextColumn(ctx)
          local src_txt = seg.source_text or ''
          local src_wc  = word_count(src_txt)
          reaper.ImGui_TextWrapped(ctx, src_txt)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
          reaper.ImGui_Text(ctx, ('%d words'):format(src_wc))
          reaper.ImGui_PopStyleColor(ctx, 1)

          -- Translation column: wrapped translation + word count vs source delta.
          reaper.ImGui_TableNextColumn(ctx)
          local trans = (seg.translations and seg.translations[lang]) or ''
          if trans == '' then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
            reaper.ImGui_Text(ctx, '—')
            reaper.ImGui_PopStyleColor(ctx, 1)
          else
            reaper.ImGui_TextWrapped(ctx, trans)
            local trn_wc = word_count(trans)
            local delta  = trn_wc - src_wc
            local sign   = (delta > 0) and '+' or ''
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
            if delta == 0 then
              reaper.ImGui_Text(ctx, ('%d words (same as source)'):format(trn_wc))
            else
              reaper.ImGui_Text(ctx, ('%d words (%s%d vs source)'):format(trn_wc, sign, delta))
            end
            reaper.ImGui_PopStyleColor(ctx, 1)
          end
          reaper.ImGui_TableNextColumn(ctx)
          -- Status policzony raz na górze pętli (segment_status — wspólne
          -- źródło z chipami filtra).
          -- W2 M2: pill span-fitted segmentu jest KLIKALNY (SmallButton
          -- konsumuje klik — Selectable wiersza/multi-select nietknięte)
          -- → popover suwaka. Per-word/natural/inne stany = zwykły Text.
          local seg_fit = seg.dub_fit and seg.dub_fit[lang]
          local pill_clickable = dub_st == 'generated' and seg_fit
            and seg_fit.strategy ~= 'per_word' and seg_fit.strategy ~= 'natural'
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), st_color)
          if pill_clickable then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00000000)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xFFFFFF18)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xFFFFFF28)
            if reaper.ImGui_SmallButton(ctx, st_label .. '##pill_' .. seg.id) then
              reaper.ImGui_OpenPopup(ctx, 'dub_fit_pop_' .. seg.id)
            end
            reaper.ImGui_PopStyleColor(ctx, 3)
          else
            reaper.ImGui_Text(ctx, st_label)
          end
          reaper.ImGui_PopStyleColor(ctx, 1)
          if st_label == 'WAITING' and reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx,
              'Waiting for earlier segments to finish translating —\n'
              .. 'translations are done in order so each one can use\n'
              .. 'the previous lines as context. No action needed.')
          elseif dub_st == 'generated' and seg.dub_fit and seg.dub_fit[lang]
                 and reaper.ImGui_IsItemHovered(ctx) then
            -- W2 M1: szczegóły dopasowania tempa (PHASE-W2 §2 — jawność).
            local f = seg.dub_fit[lang]
            local span = math.max(0, (seg.t_end or 0) - (seg.t_start or 0))
            local lines = {
              ('Speech tempo: %.2fx of natural TTS pace (1.00x = untouched).')
                :format(f.applied_rate or 1),
              ('Generated audio: %.2fs (speech %.2fs) in a %.2fs slot.')
                :format(f.natural_len or 0, f.speech_len or 0, span),
            }
            if f.strategy == 'gap' then
              lines[#lines + 1] = ('Silence after speech: %.1fs — speech stays natural instead of being slowed down.')
                :format(f.gap_secs or 0)
              lines[#lines + 1] = 'Use "Expand translation" for a longer line, or accept the pause.'
            elseif f.strategy == 'overrun' then
              lines[#lines + 1] = ('Runs %.1fs into the next line (edges faded) — speech stays natural instead of being squeezed.')
                :format(f.overrun_secs or 0)
              lines[#lines + 1] = 'Use "Shorten translation" for a tighter line, or accept the overlap.'
            elseif (f.slack_used or 0) > 0.05 then
              lines[#lines + 1] = ('Borrows %.1fs of free space before the next line.')
                :format(f.slack_used)
            end
            if f.smoothed then
              lines[#lines + 1] = 'Tempo evened out with the neighboring line (anti-jump).'
            end
            if f.strategy == 'per_word' then
              lines[#lines + 1] = 'Per-word fit: words keep natural pace, pauses absorb the difference.'
            end
            -- W2 M2: override + affordance suwaka.
            if seg.dub_stretch_override and seg.dub_stretch_override[lang] then
              lines[#lines + 1] = 'Tempo set manually (slider) — automatic fit is off for this line.'
            end
            if pill_clickable then
              lines[#lines + 1] = 'Click the status to adjust tempo with a slider.'
            end
            reaper.ImGui_SetTooltip(ctx, table.concat(lines, '\n'))
          elseif st_label == 'FAILED' and reaper.ImGui_IsItemHovered(ctx) then
            -- W3 quick win + Pakiet B+: trwała przyczyna zamiast znikającego
            -- status line — translation_error LUB dub_error zależnie od etapu.
            if dub_st == 'failed' then
              local why = seg.dub_error and seg.dub_error[lang]
              reaper.ImGui_SetTooltip(ctx,
                ('Dub generation failed: %s\n\nPress "Generate dub" to retry this segment.')
                  :format(why or 'unknown error'))
            else
              local why = seg.translation_error and seg.translation_error[lang]
              reaper.ImGui_SetTooltip(ctx,
                ('Translation failed: %s\n\nPress "Translate all" to retry this segment.')
                  :format(why or 'unknown error'))
            end
          end

          -- W3 (user request): dirty → jeden klik przy samym statusie.
          -- Kolejność etapów: najpierw tłumaczenie (Re-translate), po jego
          -- sukcesie status przejdzie w dub-stale i przycisk sam zmieni się
          -- na Re-gen dub. Zero automatu — każdy krok to jawny klik.
          -- Ukryty gdy segment ma aktywny handle (w toku) lub excluded.
          local row_busy = (ms.translate_handles and ms.translate_handles[seg.id])
            or (ms.tts_handles and ms.tts_handles[seg.id])
            or (ms.align_handles and ms.align_handles[seg.id])
          -- T2 (UX-POLISH): ▶ odsłuch tłumaczenia PRZED wstawieniem — ten
          -- sam request/cache co Generate (odsłuchany segment nie renderuje
          -- się drugi raz). Widoczny dla każdego przetłumaczonego segmentu.
          if not seg.dub_excluded and not row_busy
             and ((seg.translations and seg.translations[lang]) or '') ~= '' then
            local previewing = mode_module.is_segment_previewing
                           and mode_module.is_segment_previewing(state, seg.id)
            local pv_label = previewing and '\xe2\x96\xa0##pv_' .. seg.id
                                         or '\xe2\x96\xb6##pv_' .. seg.id
            if reaper.ImGui_SmallButton(ctx, pv_label) then
              mode_module.request_segment_preview(state, seg.id)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
              reaper.ImGui_SetTooltip(ctx, previewing
                and 'Stop preview'
                or  'Preview the translated line (voice + settings as Generate).\nGenerate afterwards reuses this render — no double billing.\nRe-gen dub still forces a fresh interpretation.')
            end
            -- UWAGA (user-caught misalignment): ŻADNEGO wiszącego SameLine
            -- tutaj — gdy żaden quick-action nie renderuje się po ▶, stan
            -- SameLine przeciekał do NASTĘPNEJ komórki (Actions) i
            -- rozstrzeliwał przyciski −/× po przekątnej. ▶ stoi na własnej
            -- linii; quick-actions renderują się pod nim.
          end
          if not seg.dub_excluded and not row_busy then
            if trans_st == 'stale' or trans_st == 'failed' then
              if reaper.ImGui_SmallButton(ctx, 'Re-translate##rt_' .. seg.id) then
                mode_module.retranslate_segment(state, seg.id)
              end
              if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx,
                  'Re-run translation for this segment only.\nThe dub will then show as stale — one more click regenerates it.')
              end
            elseif dub_st == 'failed' then
              if reaper.ImGui_SmallButton(ctx, 'Retry dub##rd_' .. seg.id) then
                mode_module.retry_segment_dub(state, seg.id)
              end
              if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, 'Retry dub generation for this segment only.')
              end
            elseif dub_st == 'stale' and trans_st == 'translated'
                   and ((seg.translations and seg.translations[lang]) or '') ~= '' then
              if reaper.ImGui_SmallButton(ctx, 'Re-gen dub##rg_' .. seg.id) then
                mode_module.request_regen_segment(state, seg.id, 1)
              end
              if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx,
                  'Re-generate dub audio for this segment (adds a fresh take).')
              end
            elseif dub_st == 'generated' and seg.dub_fit and seg.dub_fit[lang] then
              -- W2 M1: 1-klik przy statusie dla GAP (warn) / OVERRUN —
              -- timing hint do director's note + retranslate (1 LLM call,
              -- potem dub stale → Re-gen dub; zero automatu, każdy krok jawny).
              local f = seg.dub_fit[lang]
              if f.strategy == 'gap' and f.gap_warn then
                if reaper.ImGui_SmallButton(ctx, 'Expand translation##ex_' .. seg.id) then
                  mode_module.request_fit_retranslate(state, seg.id, 'expand')
                end
                if reaper.ImGui_IsItemHovered(ctx) then
                  reaper.ImGui_SetTooltip(ctx,
                    'Ask the translator for a slightly longer line to fill the silence.\n'
                    .. 'Adds a timing note (editable in the inspector) + re-translates this segment.')
                end
              elseif f.strategy == 'overrun' then
                if reaper.ImGui_SmallButton(ctx, 'Shorten translation##sh_' .. seg.id) then
                  mode_module.request_fit_retranslate(state, seg.id, 'shorten')
                end
                if reaper.ImGui_IsItemHovered(ctx) then
                  reaper.ImGui_SetTooltip(ctx,
                    'Ask the translator for a tighter line that fits the slot.\n'
                    .. 'Adds a timing note (editable in the inspector) + re-translates this segment.')
                end
              end
              -- W2 M2: [Stretch anyway] z §2.2/§2.3 — świadome wyjście poza
              -- strefę zieloną uszami usera (darmowe, zero LLM/TTS).
              if (f.strategy == 'gap' and f.gap_warn) or f.strategy == 'overrun' then
                if reaper.ImGui_SmallButton(ctx, 'Stretch\xE2\x80\xA6##st_' .. seg.id) then
                  reaper.ImGui_OpenPopup(ctx, 'dub_fit_pop_' .. seg.id)
                end
                if reaper.ImGui_IsItemHovered(ctx) then
                  reaper.ImGui_SetTooltip(ctx,
                    'Manually stretch the speech to fill or fit the slot (slider).\n'
                    .. 'Free — no API call; your ears decide how far to push it.')
                end
              end
            end
          end

          -- W2 M2: popover suwaka (wspólny dla pilla i Stretch… — to samo id
          -- w scope wiersza). Render po wszystkich OpenPopup tej komórki.
          render_fit_popover(ctx, seg, lang, ms, state, mode_module)

          -- Actions column: [+] include button (gdy excluded) + [X] delete button (always).
          reaper.ImGui_TableNextColumn(ctx)
          if seg.dub_excluded then
            -- Green "+" → include w dub pipeline
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x40A040FF)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x50C050FF)
            if reaper.ImGui_SmallButton(ctx, '+##incl_' .. seg.id) then
              mode_module.set_segment_excluded(state, seg.id, false)
            end
            reaper.ImGui_PopStyleColor(ctx, 2)
            if reaper.ImGui_IsItemHovered(ctx) then
              reaper.ImGui_SetTooltip(ctx, 'Include this segment in dub pipeline (will be translated + generated on next run).')
            end
          else
            -- Yellow "−" → exclude from dub (mark as skip)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x806020FF)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xA08040FF)
            if reaper.ImGui_SmallButton(ctx, '\xE2\x80\x93##excl_' .. seg.id) then
              mode_module.set_segment_excluded(state, seg.id, true)
            end
            reaper.ImGui_PopStyleColor(ctx, 2)
            if reaper.ImGui_IsItemHovered(ctx) then
              reaper.ImGui_SetTooltip(ctx, 'Exclude this segment from dub pipeline (won\'t be translated or generated).')
            end
          end
          reaper.ImGui_SameLine(ctx, 0, 4)
          -- Red "X" → delete segment forever (destructive, confirm)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x803030FF)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xA04040FF)
          if reaper.ImGui_SmallButton(ctx, 'x##del_' .. seg.id) then
            local choice = reaper.MB(
              ('Delete segment %s permanently?\n\n'):format(seg.id)
                .. ('Source: %s\n\n'):format((seg.source_text or ''):sub(1, 80))
                .. 'Removes segment from project + all dub items dla target languages.\n'
                .. 'Cannot undo via Cmd+Z (mode operation).',
              'Delete segment', 1)
            if choice == 1 then
              mode_module.delete_segment(state, seg.id)
            end
          end
          reaper.ImGui_PopStyleColor(ctx, 2)
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, 'Delete this segment permanently (asks for confirmation).')
          end
          -- W3 Pakiet B: widoczny ⋯ otwiera TEN SAM popup co right-click na
          -- wierszu (id 'seg_ctx_<id>' współdzielone z render_segment_context_menu
          -- — wspólny ID scope wiersza tabeli, zero duplikacji menu).
          reaper.ImGui_SameLine(ctx, 0, 4)
          -- '…' (U+2026) zamiast '⋯' (U+22EF) — Inter nie ma U+22EF → '?' (2026-06-11)
          if reaper.ImGui_SmallButton(ctx, '…##menu_' .. seg.id) then
            reaper.ImGui_OpenPopup(ctx, 'seg_ctx_' .. seg.id)
          end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, 'Segment menu: re-translate · re-generate · reassign speaker · merge · more')
          end
          ::continue_seg::
        end
        reaper.ImGui_EndTable(ctx)
      end

      -- Floating popup editor for inline edit — extracted (M3-1)
      render_inline_edit_popup(ctx, state, project, mode_module)
    end

    reaper.ImGui_Unindent(ctx, theme.SPACING.md)
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
end

----------------------------------------------------------------------------
-- Status ticker (bottom of content area, above action band)
-- M1 Part 2: live per-lang counts + cost breakdown + spinner gdy any handle active.
----------------------------------------------------------------------------
local SPINNER_GLYPHS = { '|', '/', '-', '\\' }

local function render_status_line(ctx, state, project)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  local ms = state.modes and state.modes.dubbing or {}
  -- Per-lang counts: translated / generated of total
  local parts = {}
  for _, lang in ipairs(project.target_languages) do
    local translated, generated, total = 0, 0, #project.segments
    for _, seg in ipairs(project.segments) do
      if seg.translation_status and seg.translation_status[lang] == 'translated' then
        translated = translated + 1
      end
      if seg.dub_status and seg.dub_status[lang] == 'generated' then
        generated = generated + 1
      end
    end
    parts[#parts + 1] = string.format('%s T%d/D%d/%d', lang:upper(), translated, generated, total)
  end
  -- Activity spinner + longest-elapsed handle (helps spot stuck workers)
  local active_count = 0
  local max_elapsed = 0
  local now = reaper.time_precise()
  local function tally_handles(map)
    for _, h in pairs(map or {}) do
      active_count = active_count + 1
      if h.started_at then
        local el = now - h.started_at
        if el > max_elapsed then max_elapsed = el end
      end
    end
  end
  tally_handles(ms.translate_handles)
  tally_handles(ms.tts_handles)
  tally_handles(ms.align_handles)
  tally_handles(ms.clone_handles)
  tally_handles(ms.chunk_handles)
  -- Regen pump uses regen_state[seg_id].current_handle (not w main tts_handles)
  for _, rs in pairs(ms.regen_state or {}) do
    if rs.current_handle then
      active_count = active_count + 1
      if rs.current_handle.started_at then
        local el = now - rs.current_handle.started_at
        if el > max_elapsed then max_elapsed = el end
      end
    end
  end
  local spin = ''
  if active_count > 0 then
    local idx = (math.floor(now * 6) % 4) + 1
    if max_elapsed >= 30 then
      spin = (' %s %d running (longest %ds)'):format(SPINNER_GLYPHS[idx], active_count, math.floor(max_elapsed))
    else
      spin = (' %s %d running'):format(SPINNER_GLYPHS[idx], active_count)
    end
  end
  -- Cost breakdown
  local ct = project.cost_tracker or {}
  reaper.ImGui_Text(ctx, string.format(
    '%d speakers - %d segs - %s%s',
    #project.speakers, #project.segments,
    table.concat(parts, '  '), spin))
  reaper.ImGui_Text(ctx, string.format(
    'STT %.1f min - LLM %d/%d tok - TTS %d ch - $%.2f total',
    ct.stt_minutes_used or 0,
    ct.llm_tokens_used_input or 0, ct.llm_tokens_used_output or 0,
    ct.tts_chars_used or 0,
    ct.estimated_total_usd or 0))
  -- M2.4 cache visibility — only show when any cache activity recorded
  local cache_hits = (ct.translate_cache_hits or 0) + (ct.tts_cache_hits or 0)
  local fresh      = ct.translate_fresh or 0
  if cache_hits > 0 or fresh > 0 then
    reaper.ImGui_Text(ctx, string.format(
      'Translation memory: %d cache hit(s) / %d fresh - TTS cache: %d hit(s) (no extra cost)',
      ct.translate_cache_hits or 0, fresh, ct.tts_cache_hits or 0))
  end
  -- Pipeline phase indicator
  local phase = ms.phase or 'idle'
  if phase ~= 'idle' and phase ~= 'ready' then
    reaper.ImGui_Text(ctx, ('Phase: %s'):format(phase))
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
end

----------------------------------------------------------------------------
-- Action band (bottom — Translate / Generate / Glossary)
----------------------------------------------------------------------------
local function render_action_band(ctx, state, project, mode_module)
  local lang = project.active_target_language or '?'
  local has_segs = #project.segments > 0
  local ms = mode_module.init_state(state)
  local translate_active = ms.translate_pending or false
  local generate_active = ms.generate_pending or false

  -- Polish #3 (PM5): pre-count stale translations żeby pokazać badge + udostępnić
  -- right-click "Force re-translate ALL" (mirror pattern Generate dub force-regen).
  local n_stale_translations = 0
  for _, seg in ipairs(project.segments) do
    if seg.translation_status and seg.translation_status[lang] == 'stale' then
      n_stale_translations = n_stale_translations + 1
    end
  end

  -- W2 M1 polish (user 2026-06-11): Generate dub wymaga choć JEDNEGO
  -- przetłumaczonego segmentu — bez tego przycisk disabled z tooltipem
  -- (walidacja request_generate_dub zostaje jako backstop po kliku;
  -- warunek = mirror trans_ready z pompy generate).
  local n_dub_ready = 0
  for _, seg in ipairs(project.segments) do
    if not seg.dub_excluded then
      local st = seg.translation_status and seg.translation_status[lang]
      if (st == 'translated' or st == 'stale')
         and ((seg.translations and seg.translations[lang]) or '') ~= '' then
        n_dub_ready = n_dub_ready + 1
      end
    end
  end

  -- Translate all / Cancel translate (toggle)
  if translate_active then
    if theme.button_neutral(ctx, ('Cancel translate (%s)'):format(lang:upper())) then
      mode_module.cancel_translate(state)
    end
  else
    reaper.ImGui_BeginDisabled(ctx, not has_segs)
    -- Polish #3: gdy są stale translations → label pokazuje N żeby user wiedział
    -- że glossary/context edit zostało zarejestrowane i czeka na refresh.
    local trans_label = (n_stale_translations > 0)
      and ('Translate all (%s) · %d stale'):format(lang:upper(), n_stale_translations)
      or  ('Translate all (%s)'):format(lang:upper())
    if theme.button_neutral(ctx, trans_label) then
      local ok, terr = mode_module.request_translate_all(state)
      if not ok then mode_module.set_status(state, terr or 'Translate request failed', theme.COLORS.status_error) end
    end
    reaper.ImGui_EndDisabled(ctx)
    if reaper.ImGui_IsItemHovered(ctx) then
      local tip = 'Batch translates all pending/stale segments via active LLM provider.\n'
               .. 'Retry-on-429 z exp backoff (1s/2s/4s).'
      if n_stale_translations > 0 then
        tip = tip
          .. ('\n\n%d segment(s) marked STALE (context/glossary edit detected) — will re-translate with current context.')
              :format(n_stale_translations)
      end
      tip = tip .. '\n\nRight-click = "Force re-translate ALL" (flip every translated → stale).'
      reaper.ImGui_SetTooltip(ctx, tip)
    end
    -- Polish #3: right-click context menu — force re-translate even gdy 0 stale
    -- (useful po zmianie LLM provider lub gdy user chce fresh translations).
    if reaper.ImGui_BeginPopupContextItem(ctx, 'translate_all_ctx') then
      if reaper.ImGui_Selectable(ctx, 'Force re-translate ALL segments', false) then
        local choice = reaper.MB(
          'Force re-translate ALL segments?\n\n'
            .. 'Marks every "translated" segment as stale and regenerates the translation\n'
            .. 'fresh via active LLM provider. Dub status preserved (no TTS cost\n'
            .. 'unless you click Generate dub afterwards).\n\n'
            .. 'Use when: you changed LLM provider / model / want alternative translations.',
          'Force re-translate ALL', 1)
        if choice == 1 then
          local ok, ferr = mode_module.force_retranslate_all(state)
          if not ok then
            mode_module.set_status(state, ferr or 'Force re-translate failed', theme.COLORS.status_error)
          end
        end
      end
      reaper.ImGui_EndPopup(ctx)
    end
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)

  -- Generate dub / Cancel generate (toggle)
  if generate_active then
    if theme.button_neutral(ctx, ('Cancel dub (%s)'):format(lang:upper())) then
      mode_module.cancel_generate(state)
    end
  else
    reaper.ImGui_BeginDisabled(ctx, not has_segs or n_dub_ready == 0)
    if theme.button_primary(ctx, ('Generate dub (%s)'):format(lang:upper())) then
      -- M2.5 cost tier alert: confirm dialog gdy estimated run cost przekracza threshold.
      local est = mode_module.estimate_pending_generate_cost(state)
      local threshold = config.get_dubbing_cost_alert_threshold_usd()
      local proceed = true
      if threshold > 0 and est.est_usd >= threshold then
        local msg = string.format(
          'This Generate-dub run is estimated at $%.2f (%d pending segment(s), %d TTS chars).\n\n'
            .. 'Your alert threshold is $%.2f (Settings -> Dubbing tab).\n\n'
            .. 'Proceed anyway?',
          est.est_usd, est.n_pending, est.est_chars, threshold)
        proceed = reaper.MB(msg, 'Cost alert', 1) == 1
      end
      if proceed then
        local ok, derr = mode_module.request_generate_dub(state)
        if not ok then mode_module.set_status(state, derr or 'Generate request failed', theme.COLORS.status_error) end
      else
        mode_module.set_status(state, 'Generate dub cancelled by cost-alert confirm.', theme.COLORS.text_dim)
      end
    end
    reaper.ImGui_EndDisabled(ctx)
    -- Tooltip także na disabled (AllowWhenDisabled — wzorzec W3 s2):
    -- wyjaśnia DLACZEGO przycisk nieaktywny zamiast milczeć.
    local hover_flags = reaper.ImGui_HoveredFlags_AllowWhenDisabled
      and reaper.ImGui_HoveredFlags_AllowWhenDisabled() or 0
    if reaper.ImGui_IsItemHovered(ctx, hover_flags) then
      if n_dub_ready == 0 then
        reaper.ImGui_SetTooltip(ctx,
          'No translated segments yet — run "Translate all" first.\n'
          .. 'This button enables once at least one segment has a translation.')
      else
        reaper.ImGui_SetTooltip(ctx,
          'Per-segment TTS via active voice → forced alignment (if Settings auto-run) → '
          .. 'splice onto [Dub LANG: speaker] track. Items placed at seg.t_start, speech onset aligned.\n\n'
          .. 'Generates only pending/stale segments. Right-click = "Force re-generate ALL".')
      end
    end
    -- M4+ Force re-gen all context menu (right-click na Generate dub button)
    if reaper.ImGui_BeginPopupContextItem(ctx, 'gen_dub_ctx') then
      if reaper.ImGui_Selectable(ctx, 'Force re-generate ALL segments', false) then
        local choice = reaper.MB(
          'Force re-generate ALL dubbed segments?\n\n'
            .. 'Marks every "DUBBED" segment as stale and regenerates audio fresh.\n'
            .. 'Translation text preserved (no LLM cost). TTS + forced align caches\n'
            .. 'may hit — cost depends on cache state.\n\n'
            .. 'Use when: you changed voice settings / voice / Per-word toggle.',
          'Force re-generate ALL', 1)
        if choice == 1 then
          local ok, ferr = mode_module.force_regen_all_dubs(state)
          if not ok then
            mode_module.set_status(state, ferr or 'Force re-gen failed', theme.COLORS.status_error)
          end
        end
      end
      reaper.ImGui_EndPopup(ctx)
    end

    -- Pre-click cost badge (always visible when pending segments exist)
    local est = mode_module.estimate_pending_generate_cost(state)
    local threshold = config.get_dubbing_cost_alert_threshold_usd()
    if est.n_pending > 0 and threshold > 0 then
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
      local pct = est.est_usd / threshold
      local color
      if pct < 0.5      then color = theme.COLORS.status_done       -- green
      elseif pct < 1.0  then color = theme.COLORS.status_stale       -- amber
      else                   color = theme.COLORS.danger       -- red
      end
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, string.format('est $%.2f', est.est_usd))
      reaper.ImGui_PopStyleColor(ctx, 1)
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, string.format(
          'Estimated cost dla pending Generate-dub run.\n'
            .. '%d segment(s) - %d TTS char(s) - threshold $%.2f.\n'
            .. 'Green <50%% / amber 50-100%% / red >100%%. Configure threshold w Settings -> Dubbing.',
          est.n_pending, est.est_chars, threshold))
      end
    end
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)

  -- Force re-generate ALL — visible button (też dostępne przez right-click na Generate dub)
  local any_generated = false
  for _, seg in ipairs(project.segments) do
    if seg.dub_status and seg.dub_status[lang] == 'generated' then
      any_generated = true; break
    end
  end
  reaper.ImGui_BeginDisabled(ctx, not any_generated or generate_active)
  if theme.button_neutral(ctx, 'Re-gen all') then
    local choice = reaper.MB(
      'Force re-generate ALL dubbed segments?\n\n'
        .. 'Marks every "DUBBED" segment as stale and regenerates audio fresh.\n'
        .. 'Translation text preserved (no LLM cost). TTS + forced align caches\n'
        .. 'may hit — cost depends on cache state.\n\n'
        .. 'Use when: you changed voice settings / voice / Per-word toggle.',
      'Force re-generate ALL', 1)
    if choice == 1 then
      local ok, ferr = mode_module.force_regen_all_dubs(state)
      if not ok then
        mode_module.set_status(state, ferr or 'Force re-gen failed', theme.COLORS.status_error)
      end
    end
  end
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Force re-generate ALL dubbed segments (ignores status).\n'
        .. 'Translations preserved — only audio side regenerated.\n'
        .. 'Use when you changed voice settings / per-word toggle / voice.')
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)

  -- Glossary button
  if theme.button_neutral(ctx, 'Glossary...') then
    ms.glossary_modal_pending_open = true
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Characters / terms / do-not-translate words. Saving marks translations stale.')
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if ms.status_msg and ms.status_msg ~= '' then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), ms.status_color or theme.COLORS.text_dim)
    reaper.ImGui_Text(ctx, ms.status_msg)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  -- W3 quick win: "what next" hint — jedna dyskretna linijka pod przyciskami.
  -- Audyt W3: po fazie ready user nie wiedział, że kolejność = Translate all →
  -- Generate dub. Renderowane tylko gdy nic nie działa (aktywne pumpy mają
  -- swój status wyżej).
  if not translate_active and not generate_active then
    local hint
    local phase = ms.phase or 'idle'
    if phase == 'casting_voices' then
      hint = 'Next: assign a voice to each speaker (Cast panel) — Translate all can run meanwhile.'
    elseif phase == 'ready' and has_segs then
      local n_total, n_tr, n_dub = 0, 0, 0
      for _, seg in ipairs(project.segments) do
        if not seg.dub_excluded then
          n_total = n_total + 1
          if seg.translation_status and seg.translation_status[lang] == 'translated' then
            n_tr = n_tr + 1
          end
          if seg.dub_status and seg.dub_status[lang] == 'generated' then
            n_dub = n_dub + 1
          end
        end
      end
      if n_total > 0 and n_tr < n_total then
        hint = 'Next: Translate all → then Generate dub.'
      elseif n_total > 0 and n_dub < n_total then
        hint = 'Translations ready — next: Generate dub.'
      elseif n_total > 0 and n_stale_translations == 0 then
        hint = 'All segments dubbed — audition the [Dub] tracks in REAPER.'
      end
    end
    if hint then
      theme.push_caption(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
      reaper.ImGui_Text(ctx, hint)
      reaper.ImGui_PopStyleColor(ctx, 1)
      theme.pop_caption(ctx)
    end
  end
end

----------------------------------------------------------------------------
-- Edit project settings modal (post-creation tweakable fields).
-- Source item/tracks NIE edytowalne (frozen at start time — change = nowy projekt).
-- target_languages + tts_model są edytowalne w header (NIE w tym modalu).
----------------------------------------------------------------------------
local function render_edit_modal(ctx, state, project, mode_module)
  theme.center_next_modal(ctx, 540, 0)
  theme.popup_keep_top(ctx, 'Project settings')
  local visible = reaper.ImGui_BeginPopupModal(ctx, 'Project settings', true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end

  -- Read-only info section
  reaper.ImGui_SeparatorText(ctx, 'Project info (read-only)')
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_Text(ctx, 'GUID:        ' .. (project.project_guid or '?'))
  reaper.ImGui_Text(ctx, 'Source kind: ' .. (project.source_kind or '?'))
  if project.source_kind == 'mixed_single' then
    reaper.ImGui_Text(ctx, 'Source item: ' .. (project.source_item_guid or '(none)'))
  else
    reaper.ImGui_Text(ctx, ('Source tracks: %d'):format(#(project.source_track_guids or {})))
  end
  reaper.ImGui_Text(ctx, 'Source lang: ' .. (project.source_language or 'auto'))
  reaper.ImGui_Text(ctx, ('Created:    %s'):format(os.date('%Y-%m-%d %H:%M', project.created_at_unix or 0)))
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- Editable fields
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Editable')

  -- Style preset
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Style preset:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 240)
  local edit_style_label = (dub_project.STYLE_PRESETS[project.style_preset]
    and dub_project.STYLE_PRESETS[project.style_preset].label)
    -- T10: własny styl ('saved:<Name>') → czytelna nazwa zamiast surowego klucza
    or (type(project.style_preset) == 'string'
        and project.style_preset:match('^saved:(.+)$'))
    or project.style_preset or '?'
  if reaper.ImGui_BeginCombo(ctx, '##edit_style', edit_style_label) then
    for _, key in ipairs(dub_project.STYLE_PRESET_ORDER) do
      if reaper.ImGui_Selectable(ctx, dub_project.STYLE_PRESETS[key].label, project.style_preset == key) then
        project.style_preset = key
        local preset_ctx = dub_project.STYLE_PRESETS[key]
        if preset_ctx then
          project.context.tone       = preset_ctx.tone
          project.context.era        = preset_ctx.era
          project.context.audience   = preset_ctx.audience
          project.context.media_type = preset_ctx.media_type
          project.context.honorific  = preset_ctx.honorific
          -- Brief → free_text tylko gdy obecny tekst nie jest user-authored
          -- (konserwatywnie, bez confirm w nested modalu — pełny confirm-flow
          -- żyje w Translation context section).
          if preset_ctx.brief and dub_project.is_stock_style_text(project.context.free_text) then
            project.context.free_text = preset_ctx.brief
          end
        end
        mode_module.mark_dirty(state)
      end
    end
    -- T10c: własne style usera — apply = pełny snapshot kontekstu (to
    -- jawny zapis usera, nadpisuje też free_text; mirror apply_saved_style
    -- z sekcji Context).
    local saved_names = config.list_custom_style_names('dubbing')
    reaper.ImGui_Separator(ctx)
    if #saved_names == 0 then
      reaper.ImGui_TextDisabled(ctx,
        'No custom styles yet - save one from Translation context.')
    end
    if #saved_names > 0 then
      reaper.ImGui_TextDisabled(ctx, 'Custom styles')
      for _, name in ipairs(saved_names) do
        local key = 'saved:' .. name
        if reaper.ImGui_Selectable(ctx, name .. '##edit_cst_' .. name,
             project.style_preset == key) then
          local st = config.get_custom_styles('dubbing')[name]
          if st then
            project.style_preset = key
            for _, f in ipairs({ 'tone', 'era', 'audience', 'media_type', 'honorific' }) do
              if type(st[f]) == 'string' and st[f] ~= '' then
                project.context[f] = st[f]
              end
            end
            if type(st.free_text) == 'string' then
              project.context.free_text = st.free_text
            end
            mode_module.mark_dirty(state)
          end
        end
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  -- Voice Isolator
  local rv_vi, new_vi = reaper.ImGui_Checkbox(ctx,
    'Voice Isolator pre-clean source audio (opt-in)', project.voice_isolator_enabled == true)
  if rv_vi then
    project.voice_isolator_enabled = new_vi
    mode_module.mark_dirty(state)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'When ON, source audio is pre-processed via /v1/audio-isolation before STT.\n'
      .. 'Improves diarization accuracy on noisy/music-heavy source. Extra credits cost.')
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'Note: target languages and TTS model are editable directly in the header bar '
    .. '(language tabs + TTS dropdown). Source item/tracks are locked once project starts '
    .. '— close + start new project to change source.')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Delete project (destructive)
  if theme.button_danger(ctx, 'Delete project') then
    -- M4-3: najpierw sprzątanie klonów (Delete/Keep/Cancel), potem confirm.
    local proceed = prompt_clone_cleanup(state, mode_module)
    if proceed then
      local choice = reaper.MB(
        ('Delete Dubbing project "%s"?\n\n'):format(project.project_guid or '?')
          .. 'This removes the filesystem JSON state. REAPER tracks/items are NOT deleted '
          .. '— you must manually delete [Dub: speaker] tracks if they were created.\n\n'
          .. 'This action cannot be undone.',
        'Delete Dubbing project', 1)
      if choice == 1 then
        dub_state.delete(project.project_guid)
        mode_module.close_project(state)
        mode_module.set_status(state, 'Project deleted', theme.COLORS.text_dim)
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
    end
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if theme.button_neutral(ctx, 'Close') then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

----------------------------------------------------------------------------
-- Project view (when project loaded)
----------------------------------------------------------------------------
-- Polish #4: élastique banner — gdy per-word splice enabled, REAPER musi mieć
-- ustawiony élastique 3 Pro w Preferences → Audio → "Default time stretch mode
-- for new items". Inne algorithms (default "REAPER stretch") dają audible
-- artifacts dla mowy. Banner widoczny tylko gdy feature enabled.
local function render_elastique_banner(ctx)
  if not config.get_dubbing_per_word_splice() then return end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
  reaper.ImGui_TextWrapped(ctx,
    'Per-word lip-sync enabled — set REAPER Preferences → Audio → "Default time stretch mode for new items" to: élastique 3 Pro (Soloist Monophonic). Otherwise stretched audio will have metallic artifacts.')
  reaper.ImGui_PopStyleColor(ctx, 1)
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Affects ALL stretched media items in REAPER (global pref).\n'
      .. 'Recommended modes for speech: élastique 3 Pro Soloist Monophonic\n'
      .. '(cleanest) or élastique 3 Pro Tonal. "REAPER stretch" / "Simple\n'
      .. 'windowed" produce robotic-sounding output.\n\n'
      .. 'To disable banner: Settings → Dubbing → uncheck "Per-word lip-sync".')
  end
  reaper.ImGui_Spacing(ctx)
end

local function render_project(ctx, state, project, mode_module)
  render_project_header(ctx, state, project, mode_module)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  render_elastique_banner(ctx)

  render_context_section(ctx, state, project, mode_module)
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)

  -- Cast sidebar + segments table horizontal split.
  -- Reserve dla status line (~24px) + action band buttons (~32px) + 2x Spacing (~16px)
  -- = ~72px. Plus margines bezpieczeństwa na różne ImGui scaling settings = 96px.
  local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx)) or 800
  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local body_h = math.max(180, (avail_h or 400) - 96)

  -- Sidebar must fit longest button label "Find similar from item" (~150px)
  -- plus child padding (16px L+R). Min 200px ensures readable buttons.
  -- PM9: collapsible — gdy ms.cast_sidebar_collapsed=true → wąski 40px strip
  -- z chevron toggle (po skonfigurowaniu castu zabiera niepotrzebnie miejsca).
  local ms = state.modes and state.modes.dubbing or {}
  local cast_collapsed = ms.cast_sidebar_collapsed == true
  local sidebar_w
  if cast_collapsed then
    sidebar_w = 40
  else
    sidebar_w = math.max(200, math.min(240, math.floor(avail_w * 0.28)))
  end
  render_cast_sidebar(ctx, state, project, mode_module, sidebar_w, body_h)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  render_segments_table(ctx, state, project, mode_module, avail_w - sidebar_w - 12, body_h)

  reaper.ImGui_Spacing(ctx)
  render_status_line(ctx, state, project)
  reaper.ImGui_Spacing(ctx)
  render_action_band(ctx, state, project, mode_module)
end

----------------------------------------------------------------------------
-- Start Dubbing modal
----------------------------------------------------------------------------
local function init_start_modal_buffers(project_defaults)
  if s.start_modal_initialized then return end
  s.start_modal_initialized = true
  s.start_source_kind   = 'mixed_single'
  s.start_target_langs  = {}
  s.start_lang_input_buf = ''
  s.start_style_preset  = config.get_dubbing_default_style_preset()
  s.start_tts_model     = config.get_dubbing_default_tts_model()
  s.start_voice_isolator = config.get_dubbing_voice_isolator_preclean()
  -- Pre-fill z default target languages w config (if any)
  for _, l in ipairs(config.get_dubbing_default_target_languages()) do
    s.start_target_langs[#s.start_target_langs + 1] = l
  end
end

local function render_start_modal(ctx, state, mode_module)
  -- W2 M1 fix (user-caught): auto-height (580, 0) wystawał poza ekran i
  -- ucinał przyciski (znany backlog W3 s3 "auto-height bez clampu pozycji").
  -- Fixed size dostaje z center_next_modal clamp rozmiaru ≤92% work area
  -- ORAZ pozycji; treść w scroll-childzie, footer przypięty na dole.
  theme.center_next_modal(ctx, 580, 660)
  theme.popup_keep_top(ctx, 'Start Dubbing Project')
  local visible = reaper.ImGui_BeginPopupModal(ctx, 'Start Dubbing Project', true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then
    -- Popup not currently open (closed by X / Esc / CloseCurrentPopup last frame).
    -- ReaImGui contract: EndPopup TYLKO gdy BeginPopupModal zwróciło true — return now.
    return
  end
  init_start_modal_buffers()

  -- Live source detection (every frame for accurate enable/disable) — liczone
  -- PRZED treścią, bo banner + przyciski żyją w przypiętym footerze.
  local source_item, source_item_guid
  local source_track_guids = {}
  if s.start_source_kind == 'mixed_single' then
    source_item = reaper.GetSelectedMediaItem(0, 0)
    if source_item then
      local _, g = reaper.GetSetMediaItemInfo_String(source_item, 'GUID', '', false)
      source_item_guid = g
    end
  else
    local cnt = reaper.CountSelectedTracks(0)
    for i = 0, cnt - 1 do
      local tr = reaper.GetSelectedTrack(0, i)
      local _, g = reaper.GetSetMediaTrackInfo_String(tr, 'GUID', '', false)
      source_track_guids[#source_track_guids + 1] = g
    end
  end
  -- Inline validation (shows BEFORE clicking Start so user knows what's missing).
  local source_missing
  if s.start_source_kind == 'mixed_single' then
    if not source_item_guid then
      source_missing = 'No item selected in REAPER. Click on the source audio item in the arrange view before clicking Start.'
    end
  else
    if #source_track_guids == 0 then
      source_missing = 'No tracks selected in REAPER. Click track headers (Ctrl/Cmd-click for multi) before clicking Start.'
    end
  end

  -- Content scroll-child; rezerwa na footer (separator + przyciski,
  -- + banner gdy widoczny — dynamiczna, banner zawsze na ekranie).
  local footer_reserve = -(44 + (source_missing and 52 or 0))
  if reaper.ImGui_BeginChild(ctx, 'start_body', 0, footer_reserve) then

  -- Source kind radio (stacked — w jednej linii druga etykieta clippowała
  -- się na prawej krawędzi przy 580px)
  reaper.ImGui_SeparatorText(ctx, 'Source')
  if reaper.ImGui_RadioButton(ctx, 'Single mixed file (REAPER selected item)',
      s.start_source_kind == 'mixed_single') then
    s.start_source_kind = 'mixed_single'
  end
  if reaper.ImGui_RadioButton(ctx, 'Multi-track session (selected tracks)',
      s.start_source_kind == 'multi_track') then
    s.start_source_kind = 'multi_track'
  end

  -- Target languages multi-select
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Target languages (at least 1)')
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'Per project N languages supported od M1. Click to toggle. Custom ISO 639-1 codes via input below.')
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- Common langs as toggle pills
  for i, l in ipairs(COMMON_LANGS) do
    if i > 1 and (i - 1) % 5 ~= 0 then
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    end
    local selected = false
    local selected_idx = nil
    for j, existing in ipairs(s.start_target_langs) do
      if existing == l.code then selected = true; selected_idx = j; break end
    end
    if selected then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), theme.COLORS.primary)
    end
    if reaper.ImGui_SmallButton(ctx, l.label .. '##stl_' .. l.code) then
      if selected then
        table.remove(s.start_target_langs, selected_idx)
      else
        s.start_target_langs[#s.start_target_langs + 1] = l.code
      end
    end
    if selected then reaper.ImGui_PopStyleColor(ctx, 1) end
  end

  -- Custom lang input
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Custom ISO 639-1 code:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_SetNextItemWidth(ctx, 80)
  local rv_c, new_c = reaper.ImGui_InputText(ctx, '##stl_custom', s.start_lang_input_buf)
  if rv_c then s.start_lang_input_buf = new_c end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  -- M4-8 (audit 2026-07): kod trafia do nazwy katalogu cache tłumaczeń —
  -- tylko małe litery/cyfry/myślnik, start literą, koniec bez myślnika,
  -- 2-5 znaków (ISO 639-1 + subtag typu pt-br). Znaki typu '/' czy ':'
  -- rozwaliłyby ścieżkę.
  local cand = s.start_lang_input_buf:lower()
  local code_valid = #cand >= 2 and #cand <= 5
    and cand:match('^%l[%l%d%-]*[%l%d]$') ~= nil
  reaper.ImGui_BeginDisabled(ctx, not code_valid)
  if reaper.ImGui_SmallButton(ctx, 'Add##stl_add') then
    local code = cand
    local already = false
    for _, existing in ipairs(s.start_target_langs) do
      if existing == code then already = true; break end
    end
    if not already then s.start_target_langs[#s.start_target_langs + 1] = code end
    s.start_lang_input_buf = ''
  end
  reaper.ImGui_EndDisabled(ctx)
  if s.start_lang_input_buf ~= '' and not code_valid then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
    reaper.ImGui_Text(ctx, 'lowercase letters/digits/hyphen, 2-5 chars')
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  -- Show selected (chips)
  if #s.start_target_langs > 0 then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, 'Selected:')
    for i, code in ipairs(s.start_target_langs) do
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), theme.COLORS.bg_subtle or 0x333333FF)
      if reaper.ImGui_SmallButton(ctx, code:upper() .. ' x##stl_chip_' .. i) then
        table.remove(s.start_target_langs, i)
      end
      reaper.ImGui_PopStyleColor(ctx, 1)
    end
  end

  -- TTS model + style preset + voice isolator
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Options')

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'TTS model:   ')
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 280)
  if reaper.ImGui_BeginCombo(ctx, '##stl_tts', tts_model_label(s.start_tts_model)) then
    for _, m in ipairs({ 'eleven_multilingual_v2', 'eleven_v3', 'eleven_turbo_v2_5', 'eleven_flash_v2_5' }) do
      if reaper.ImGui_Selectable(ctx, tts_model_label(m), s.start_tts_model == m) then
        s.start_tts_model = m
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Style preset:')
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 200)
  local start_style_label = (dub_project.STYLE_PRESETS[s.start_style_preset]
    and dub_project.STYLE_PRESETS[s.start_style_preset].label)
    -- T10c: własny styl ('saved:<Name>') → czytelna nazwa
    or (type(s.start_style_preset) == 'string'
        and s.start_style_preset:match('^saved:(.+)$'))
    or s.start_style_preset
  if reaper.ImGui_BeginCombo(ctx, '##stl_style', start_style_label) then
    for _, key in ipairs(dub_project.STYLE_PRESET_ORDER) do
      if reaper.ImGui_Selectable(ctx, dub_project.STYLE_PRESETS[key].label, s.start_style_preset == key) then
        s.start_style_preset = key
      end
    end
    -- T10c (user-caught): własne style usera dostępne już przy STARCIE
    -- projektu (dubbing_project.new_project rozwiązuje 'saved:<Name>' —
    -- projekt rodzi się z pełnym snapshotem kontekstu, nie stock+ręczna
    -- podmiana).
    local saved_names = config.list_custom_style_names('dubbing')
    reaper.ImGui_Separator(ctx)
    if #saved_names > 0 then
      reaper.ImGui_TextDisabled(ctx, 'Custom styles')
      for _, name in ipairs(saved_names) do
        local key = 'saved:' .. name
        if reaper.ImGui_Selectable(ctx, name .. '##stl_cst_' .. name,
             s.start_style_preset == key) then
          s.start_style_preset = key
        end
      end
    else
      -- T10c: discoverability — user musi wiedzieć, GDZIE powstaje
      -- pierwszy własny styl (Translation context w otwartym projekcie).
      reaper.ImGui_TextDisabled(ctx,
        'No custom styles yet - save one from\nTranslation context in an open project.')
    end
    reaper.ImGui_EndCombo(ctx)
  end

  local rv_vi, new_vi = reaper.ImGui_Checkbox(ctx, 'Pre-clean source via Voice Isolator (opt-in)',
    s.start_voice_isolator)
  if rv_vi then s.start_voice_isolator = new_vi end

    reaper.ImGui_EndChild(ctx)
  end

  -- Pinned footer: separator + validation banner + action buttons
  reaper.ImGui_Separator(ctx)
  if source_missing then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
    reaper.ImGui_TextWrapped(ctx, source_missing)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  reaper.ImGui_Spacing(ctx)

  if theme.button_neutral(ctx, 'Cancel') then
    reaper.ImGui_CloseCurrentPopup(ctx)
    s.start_modal_initialized = false   -- reset dla next open
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)

  local can_start = #s.start_target_langs > 0 and not source_missing
  reaper.ImGui_BeginDisabled(ctx, not can_start)
  if theme.button_primary(ctx, 'Start project') then
    local opts = {
      source_kind            = s.start_source_kind,
      target_languages       = s.start_target_langs,
      tts_model              = s.start_tts_model,
      style_preset           = s.start_style_preset,
      voice_isolator_enabled = s.start_voice_isolator,
    }
    if s.start_source_kind == 'mixed_single' then
      opts.source_item_guid = source_item_guid
    else
      opts.source_track_guids = source_track_guids
    end

    local project, err = mode_module.start_project(state, opts)
    if project then
      mode_module.set_status(state, ('Project started — %d languages'):format(#opts.target_languages), theme.COLORS.status_done)
      reaper.ImGui_CloseCurrentPopup(ctx)
      s.start_modal_initialized = false
    else
      mode_module.set_status(state, 'Start failed: ' .. (err or '?'), theme.COLORS.status_error)
    end
  end
  reaper.ImGui_EndDisabled(ctx)
  if not can_start and reaper.ImGui_IsItemHovered(ctx) then
    if #s.start_target_langs == 0 then
      reaper.ImGui_SetTooltip(ctx, 'Pick at least 1 target language to enable Start.')
    elseif source_missing then
      reaper.ImGui_SetTooltip(ctx, source_missing)
    end
  end

  reaper.ImGui_EndPopup(ctx)
end

----------------------------------------------------------------------------
-- W2 M3 cz.2: Match cast modal — podgląd per mówca + wybór Keep/Use
-- (macierz kolizji z planu §4: checkbox = Use registry, odznaczony = Keep).
-- Apply stosuje TYLKO zaznaczone wiersze (mode_module.apply_match_cast;
-- zmiana głosu → stale dubów mówcy, mirror clone-done).
----------------------------------------------------------------------------
local function render_match_cast_modal(ctx, state, mode_module)
  theme.center_next_modal(ctx, 620, 0)
  theme.popup_keep_top(ctx, 'Match cast')
  local visible = reaper.ImGui_BeginPopupModal(ctx, 'Match cast', true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end

  local rows = s.match_cast_rows or {}
  reaper.ImGui_TextWrapped(ctx,
    "Voices from the project cast registry matched to this project's speakers by name. Check a row to use the registry voice; unchecked rows keep their current assignment.")
  reaper.ImGui_Spacing(ctx)

  if reaper.ImGui_BeginTable(ctx, '##match_cast_tbl', 4,
       reaper.ImGui_TableFlags_RowBg() | reaper.ImGui_TableFlags_BordersInnerH()) then
    reaper.ImGui_TableSetupColumn(ctx, 'Use',
      reaper.ImGui_TableColumnFlags_WidthFixed(), 36)
    reaper.ImGui_TableSetupColumn(ctx, 'Speaker')
    reaper.ImGui_TableSetupColumn(ctx, 'Current voice')
    reaper.ImGui_TableSetupColumn(ctx, 'Registry voice')
    reaper.ImGui_TableHeadersRow(ctx)
    for _, r in ipairs(rows) do
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableNextColumn(ctx)
      local rv, nv = reaper.ImGui_Checkbox(ctx, '##use_' .. r.speaker_id,
        s.match_cast_sel[r.speaker_id] == true)
      if rv then s.match_cast_sel[r.speaker_id] = nv end
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, r.speaker_label or '?')
      reaper.ImGui_TableNextColumn(ctx)
      if r.cur_voice_id and r.cur_voice_id ~= '' then
        reaper.ImGui_Text(ctx, r.cur_voice_name or r.cur_voice_id)
        if r.conflict then
          reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
          reaper.ImGui_TextColored(ctx, theme.COLORS.status_stale, '(differs)')
        end
      else
        reaper.ImGui_TextDisabled(ctx, '(none)')
      end
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_Text(ctx, r.voice_name or r.voice_id or '?')
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, ('From character "%s"%s'):format(
          r.from_char or '?',
          r.from_linked and ' (linked to this source material)' or ''))
      end
    end
    reaper.ImGui_EndTable(ctx)
  end

  reaper.ImGui_Spacing(ctx)
  local n_sel = 0
  for _, r in ipairs(rows) do
    if s.match_cast_sel[r.speaker_id] then n_sel = n_sel + 1 end
  end
  reaper.ImGui_BeginDisabled(ctx, n_sel == 0)
  if theme.button_primary(ctx, ('Apply %d voice(s)##match_apply'):format(n_sel)) then
    local selected = {}
    for _, r in ipairs(rows) do
      if s.match_cast_sel[r.speaker_id] then selected[#selected + 1] = r end
    end
    mode_module.apply_match_cast(state, selected)
    s.match_cast_rows = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if theme.button_neutral(ctx, 'Cancel##match_cancel', 0, 0) then
    s.match_cast_rows = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

----------------------------------------------------------------------------
-- Public surface
----------------------------------------------------------------------------
function M.render(ctx, state, deps, mode_module)
  local ms = state.modes.dubbing
  if not ms or not ms.project then
    render_idle(ctx, state, mode_module)
  else
    render_project(ctx, state, ms.project, mode_module)
  end
end

function M.render_modals(ctx, state, deps, mode_module)
  local ms = state.modes.dubbing
  if not ms then return end
  -- One-shot OpenPopup pattern (mirror NS-2c settings_dialog).
  if ms.start_modal_pending_open then
    reaper.ImGui_OpenPopup(ctx, 'Start Dubbing Project')
    ms.start_modal_pending_open = false
    s.start_modal_initialized   = false
  end
  if s.edit_modal_pending_open then
    reaper.ImGui_OpenPopup(ctx, 'Project settings')
    s.edit_modal_pending_open = false
  end
  -- W2 M3 cz.2: Match cast (snapshot propozycji w s.match_cast_rows)
  if s.match_cast_pending_open then
    reaper.ImGui_OpenPopup(ctx, 'Match cast')
    s.match_cast_pending_open = false
  end
  render_start_modal(ctx, state, mode_module)
  if ms.project then
    render_edit_modal(ctx, state, ms.project, mode_module)
    render_match_cast_modal(ctx, state, mode_module)
  end
end

return M
