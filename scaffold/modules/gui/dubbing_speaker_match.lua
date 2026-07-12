-- modules/gui/dubbing_speaker_match.lua
-- NS-B M1 Part 2 — speaker matching modal (long mixed source flow).
--
-- Triggered po wszystkich chunks STT diarize done. Każdy chunk ma speakers
-- numerowanych LOCALLY (chunk1 spk_0 != chunk2 spk_0 — Scribe diarize resets
-- numbering per call). User manualnie maps chunk-local speaker → global
-- character.
--
-- Single-chunk shortcut: 1 chunk → speakers już coherent → modal pokazuje
-- tylko name-input pass (no cross-chunk re-mapping), one-click assign all.
--
-- On Confirm:
-- - Build project.speakers[] z user-created characters.
-- - Iterate chunks → words → group consecutive same-speaker words into segments
--   (gap-aware: >500ms between words → new segment).
-- - Adjust chunk-local word.start/end → global source timeline (+= chunk.t_start_in_src).
-- - Populate project.segments[].
-- - Set state.modes.dubbing.phase = 'casting_voices' (next: user picks voice path per speaker).
--
-- UI per spec §9.2 — left col chunks, right col characters, dropdown assigner.

local theme        = require 'modules.theme'
local dub_project  = require 'modules.dubbing_project'
local preview      = require 'modules.preview'   -- M4-4: ▶ per (chunk, speaker)

local M = {}

-- Modal-local UI state (NOT persisted; reset on each open).
local s = {
  initialized            = false,
  -- chunks_summary[chunk_idx] = { idx, t_start_in_src, t_end_in_src, speakers[] }
  --   speakers[i] = { local_id (string), word_count, first_word_at_global (number), sample_text (string) }
  chunks_summary         = {},
  -- characters[i] = { id, label, color_idx }
  characters             = {},
  -- assignments[chunk_idx][local_id] = char_id  (or nil = unassigned)
  assignments            = {},
  -- char_name_buf — input dla "Add character" form
  char_name_buf          = '',
  -- pending_open one-shot
  pending_open           = false,
}

----------------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------------
local function find_char_by_id(id)
  for _, c in ipairs(s.characters) do
    if c.id == id then return c end
  end
  return nil
end

----------------------------------------------------------------------------
-- Build chunks_summary z chunks data (called z reset / open).
-- chunks_input shape: [{idx, t_start_in_src, t_end_in_src, audio_path,
--                       transcript = { words = [{text, start, end, speaker_id}] }}]
----------------------------------------------------------------------------
local function build_chunks_summary(chunks_input)
  local summary = {}
  for _, ch in ipairs(chunks_input or {}) do
    local words = (ch.transcript and ch.transcript.words) or {}
    local per_spk = {}   -- local_id → { word_count, first_word_at_global, sample_words[] }
    -- M4-4: najdłuższy ciągły run słów per speaker (czas CHUNK-LOCAL —
    -- audio_path to WAV chunka) do przycisku ▶ preview. Mapowanie po samym
    -- tekście (12 słów) było zgadywaniem w ciemno.
    local run_spk, run_start, run_end
    local function close_run()
      if not run_spk then return end
      local rec = per_spk[run_spk]
      if rec and (not rec.best_run_end or
          (run_end - run_start) > (rec.best_run_end - rec.best_run_start)) then
        rec.best_run_start, rec.best_run_end = run_start, run_end
      end
      run_spk = nil
    end
    for _, w in ipairs(words) do
      local spk = w.speaker_id or w.speaker or 'spk_unknown'
      spk = tostring(spk)
      local rec = per_spk[spk]
      if not rec then
        rec = {
          local_id = spk,
          word_count = 0,
          first_word_at_global = (w.start or 0) + (ch.t_start_in_src or 0),
          sample_words = {},
        }
        per_spk[spk] = rec
      end
      rec.word_count = rec.word_count + 1
      if #rec.sample_words < 12 then
        rec.sample_words[#rec.sample_words + 1] = w.text or w.word or ''
      end
      local w_start = w.start or 0
      local w_end   = w['end'] or w_start
      if run_spk == spk and (w_start - (run_end or 0)) <= 0.5 then
        run_end = math.max(run_end, w_end)
      else
        close_run()
        run_spk, run_start, run_end = spk, w_start, w_end
      end
    end
    close_run()
    local spks = {}
    for _, r in pairs(per_spk) do
      r.sample_text = table.concat(r.sample_words, ' ')
      spks[#spks + 1] = r
    end
    table.sort(spks, function(a, b) return a.local_id < b.local_id end)
    summary[#summary + 1] = {
      idx              = ch.idx or (#summary + 1),
      t_start_in_src   = ch.t_start_in_src or 0,
      t_end_in_src     = ch.t_end_in_src or 0,
      audio_path       = ch.audio_path,
      speakers         = spks,
    }
  end
  return summary
end

----------------------------------------------------------------------------
-- Auto-suggest assignment: heuristic dla single-chunk case — each local_id
-- gets new character "Speaker N". For multi-chunk: don't auto-assign (user must
-- decide which chunk-local speakers are same person across chunks).
----------------------------------------------------------------------------
local function auto_seed_characters_single_chunk(summary)
  if #summary ~= 1 then return end
  local chunk = summary[1]
  for _, spk in ipairs(chunk.speakers) do
    local char = {
      id    = ('spk_%03d'):format(#s.characters + 1),
      label = ('Speaker %d'):format(#s.characters + 1),
    }
    s.characters[#s.characters + 1] = char
    s.assignments[chunk.idx] = s.assignments[chunk.idx] or {}
    s.assignments[chunk.idx][spk.local_id] = char.id
  end
end

----------------------------------------------------------------------------
-- Public: open(chunks_input)
-- Resets modal state, builds chunks_summary, queues OpenPopup.
----------------------------------------------------------------------------
function M.open(chunks_input)
  s.initialized   = true
  s.chunks_summary = build_chunks_summary(chunks_input)
  s.characters    = {}
  s.assignments   = {}
  s.char_name_buf = ''
  auto_seed_characters_single_chunk(s.chunks_summary)
  s.pending_open  = true
end

----------------------------------------------------------------------------
-- Public: render(ctx, state, mode_module, deps)
-- Returns:
--   action = 'cancel'   user cancelled (modal closed)
--   action = 'confirm'  user confirmed (returns built segments + speakers)
--   action = nil        modal still open / not open
----------------------------------------------------------------------------
function M.render(ctx, state, mode_module, deps)
  -- One-shot OpenPopup
  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, 'Identify speakers')
    s.pending_open = false
  end

  theme.center_next_modal(ctx, 780, 640)
  theme.popup_keep_top(ctx, 'Identify speakers')
  local visible = reaper.ImGui_BeginPopupModal(ctx, 'Identify speakers', true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return nil end

  local n_chunks  = #s.chunks_summary
  local total_spk = 0
  for _, ch in ipairs(s.chunks_summary) do
    total_spk = total_spk + #ch.speakers
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx, ('File split into %d chunk(s). %d voice(s) detected across chunks. '
    .. 'Assign each detected voice to a character — same physical person across chunks should map '
    .. 'to the SAME character.'):format(n_chunks, total_spk))
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Two-column layout: detected voices (left), characters (right)
  local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx)) or 720
  local left_w  = math.floor(avail_w * 0.58)
  local right_w = avail_w - left_w - 12

  -- Left: detected voices per chunk
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x1A1A1AB0)
  if reaper.ImGui_BeginChild(ctx, '##sm_left', left_w, 380, 0, 0) then
    reaper.ImGui_Text(ctx, 'Detected voices')
    reaper.ImGui_Spacing(ctx)
    for _, ch in ipairs(s.chunks_summary) do
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xCCCCCCFF)
      reaper.ImGui_Text(ctx, ('Chunk %d  (%.1f-%.1fs)'):format(
        ch.idx, ch.t_start_in_src, ch.t_end_in_src))
      reaper.ImGui_PopStyleColor(ctx, 1)
      if #ch.speakers == 0 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
        reaper.ImGui_Text(ctx, '  (no speakers detected)')
        reaper.ImGui_PopStyleColor(ctx, 1)
      end
      for _, spk in ipairs(ch.speakers) do
        local assign_map = s.assignments[ch.idx] or {}
        local cur_id = assign_map[spk.local_id]
        local cur_label = '(unassigned)'
        if cur_id then
          local c = find_char_by_id(cur_id)
          if c then cur_label = c.label end
        end
        reaper.ImGui_Indent(ctx, 16)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        -- M4-4: ▶ odtwarza najdłuższy run tego speakera z WAV-a chunka
        -- (cap 5 s) — mapowanie po samym tekście było zgadywaniem w ciemno.
        if spk.best_run_start and ch.audio_path then
          local pv_id = ('spkmatch_%s_%s'):format(tostring(ch.idx), spk.local_id)
          local playing = preview.is_playing(pv_id)
          if reaper.ImGui_SmallButton(ctx,
              (playing and '■' or '▶') .. '##pv_' .. pv_id) then
            if playing then
              preview.stop()
            else
              local pv_end = math.min(spk.best_run_end, spk.best_run_start + 5.0)
              preview.play_file_range(ch.audio_path, spk.best_run_start, pv_end, pv_id)
            end
          end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, 'Play this speaker\'s longest passage from the chunk audio.')
          end
          reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
        end
        reaper.ImGui_Text(ctx, spk.local_id .. '  ')
        reaper.ImGui_SameLine(ctx)
        -- Sample text (truncated)
        local sample = spk.sample_text or ''
        if #sample > 60 then sample = sample:sub(1, 57) .. '...' end
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
        reaper.ImGui_Text(ctx, sample)
        reaper.ImGui_PopStyleColor(ctx, 1)
        -- Assign dropdown
        reaper.ImGui_Indent(ctx, 24)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_Text(ctx, ('%d word(s) → assign to:'):format(spk.word_count))
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
        reaper.ImGui_SetNextItemWidth(ctx, 180)
        local combo_id = '##assign_' .. ch.idx .. '_' .. spk.local_id
        if reaper.ImGui_BeginCombo(ctx, combo_id, cur_label) then
          if reaper.ImGui_Selectable(ctx, '(unassigned)', cur_id == nil) then
            if assign_map then assign_map[spk.local_id] = nil end
            s.assignments[ch.idx] = assign_map
          end
          for _, c in ipairs(s.characters) do
            if reaper.ImGui_Selectable(ctx, c.label, cur_id == c.id) then
              s.assignments[ch.idx] = s.assignments[ch.idx] or {}
              s.assignments[ch.idx][spk.local_id] = c.id
            end
          end
          reaper.ImGui_EndCombo(ctx)
        end
        reaper.ImGui_Unindent(ctx, 24)
        reaper.ImGui_Unindent(ctx, 16)
        reaper.ImGui_Spacing(ctx)
      end
      reaper.ImGui_Spacing(ctx)
    end
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)

  -- Right: characters
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x1A1A1AB0)
  if reaper.ImGui_BeginChild(ctx, '##sm_right', right_w, 380, 0, 0) then
    reaper.ImGui_Text(ctx, 'Your characters')
    reaper.ImGui_Spacing(ctx)
    if #s.characters == 0 then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
      reaper.ImGui_TextWrapped(ctx, 'No characters yet. Add one below to start assigning voices.')
      reaper.ImGui_PopStyleColor(ctx, 1)
    end
    for i, c in ipairs(s.characters) do
      -- Count how many local speakers map to this character
      local mapped = 0
      for _, a in pairs(s.assignments) do
        for _, v in pairs(a) do
          if v == c.id then mapped = mapped + 1 end
        end
      end
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, '* ' .. c.label)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
      reaper.ImGui_Text(ctx, ('   (%d voice(s) mapped)'):format(mapped))
      reaper.ImGui_PopStyleColor(ctx, 1)
      -- Rename inline
      reaper.ImGui_Indent(ctx, 12)
      reaper.ImGui_SetNextItemWidth(ctx, 140)
      local rv, new = reaper.ImGui_InputText(ctx, '##rn_' .. i, c.label)
      if rv then c.label = new ~= '' and new or c.label end
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
      if reaper.ImGui_SmallButton(ctx, 'x##rmchar_' .. i) then
        -- Clear assignments referencing this character
        for _, a in pairs(s.assignments) do
          for k, v in pairs(a) do
            if v == c.id then a[k] = nil end
          end
        end
        table.remove(s.characters, i)
      end
      reaper.ImGui_Unindent(ctx, 12)
      reaper.ImGui_Spacing(ctx)
    end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, 'New character:')
    reaper.ImGui_SetNextItemWidth(ctx, 160)
    local rv_n, new_n = reaper.ImGui_InputText(ctx, '##new_char', s.char_name_buf)
    if rv_n then s.char_name_buf = new_n end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    reaper.ImGui_BeginDisabled(ctx, s.char_name_buf == '')
    if reaper.ImGui_SmallButton(ctx, '+ Add##add_char') then
      s.characters[#s.characters + 1] = {
        id    = ('spk_%03d'):format(#s.characters + 1),
        label = s.char_name_buf,
      }
      s.char_name_buf = ''
    end
    reaper.ImGui_EndDisabled(ctx)
    reaper.ImGui_EndChild(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Validation: count unassigned
  local unassigned = 0
  for _, ch in ipairs(s.chunks_summary) do
    for _, spk in ipairs(ch.speakers) do
      if not (s.assignments[ch.idx] and s.assignments[ch.idx][spk.local_id]) then
        unassigned = unassigned + 1
      end
    end
  end
  if unassigned > 0 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
    reaper.ImGui_Text(ctx, ('%d voice(s) still unassigned — assign all before continuing.'):format(unassigned))
    reaper.ImGui_PopStyleColor(ctx, 1)
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_done)
    reaper.ImGui_Text(ctx, ('All voices assigned to %d character(s).'):format(#s.characters))
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_Spacing(ctx)
  local action = nil
  if theme.button_neutral(ctx, 'Cancel') then
    reaper.ImGui_CloseCurrentPopup(ctx)
    s.initialized = false
    action = 'cancel'
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_BeginDisabled(ctx, unassigned > 0 or #s.characters == 0)
  if theme.button_primary(ctx, 'Continue ->') then
    reaper.ImGui_CloseCurrentPopup(ctx)
    action = 'confirm'
  end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_EndPopup(ctx)
  return action
end

----------------------------------------------------------------------------
-- Public: build_segments_and_speakers(project, chunks_input) — called z
-- mode_module na 'confirm' result. Returns ok, err.
--
-- Process:
-- 1. Reset project.speakers (M1 — first-time population; M2 may extend).
-- 2. For each character in s.characters → add to project.speakers (preserve order).
-- 3. For each chunk → iterate words → group consecutive same-global-speaker
--    words into segments (gap threshold 500ms → new segment).
-- 4. Adjust word.start/end → global source timeline via chunk.t_start_in_src.
-- 5. Add segments to project (in chunk order).
----------------------------------------------------------------------------
function M.build_segments_and_speakers(project, chunks_input)
  if not project then return false, 'nil project' end
  if #s.characters == 0 then return false, 'no characters defined' end

  -- 1+2: speakers
  project.speakers = {}
  -- Map character id (modal-local) → speaker reference (project-level after add).
  local id_to_speaker = {}
  -- NS-G: gather Scribe local_ids per character (across all chunks) →
  -- persist on project speaker dla speaker_picker label mapping.
  local local_ids_per_char = {}    -- char_id → set of local_id strings
  for ch_idx, assign_map in pairs(s.assignments or {}) do
    for local_id, char_id in pairs(assign_map or {}) do
      if char_id and char_id ~= '' then
        local_ids_per_char[char_id] = local_ids_per_char[char_id] or {}
        local_ids_per_char[char_id][local_id] = true
      end
    end
  end
  for _, c in ipairs(s.characters) do
    -- Flatten set → array
    local ids_arr = {}
    for lid in pairs(local_ids_per_char[c.id] or {}) do
      ids_arr[#ids_arr + 1] = lid
    end
    table.sort(ids_arr)
    local spk = dub_project.add_speaker(project, c.label, { local_ids = ids_arr })
    id_to_speaker[c.id] = spk
  end

  -- 3-5: segments (re-using project state — clear segments first)
  project.segments = {}
  local GAP_SECS_NEW_SEGMENT = 0.5

  for _, ch in ipairs(chunks_input or {}) do
    -- M4 position fix: t_start_in_src = chunk's source-file-relative time;
    -- project_offset = source_item.D_POSITION - D_STARTOFFS (playrate=1). Sum =
    -- project-absolute time dla REAPER positioning.
    local offset = (ch.t_start_in_src or 0) + (ch.project_offset or 0)
    local words  = (ch.transcript and ch.transcript.words) or {}
    -- Sort words by start time (defensive — usually already sorted)
    table.sort(words, function(a, b) return (a.start or 0) < (b.start or 0) end)

    local cur_seg = nil    -- accumulator { speaker_id, t_start, t_end, texts={}, words={} }
    local function flush()
      if not cur_seg then return end
      local text = table.concat(cur_seg.texts, ' ')
      if cur_seg.speaker_id and text ~= '' then
        dub_project.add_segment(
          project,
          cur_seg.speaker_id,
          cur_seg.t_start,
          cur_seg.t_end,
          text,
          cur_seg.words     -- M3.6: per-word source timing dla per-word splice
        )
      end
      cur_seg = nil
    end

    for _, w in ipairs(words) do
      local local_spk = tostring(w.speaker_id or w.speaker or 'spk_unknown')
      local char_id = s.assignments[ch.idx] and s.assignments[ch.idx][local_spk]
      local global_speaker = char_id and id_to_speaker[char_id] or nil
      if not global_speaker then
        -- Unassigned word — skip (should not happen post-validation).
      else
        local w_start = (w.start or 0) + offset
        local w_end   = (w['end'] or w.stop or w_start) + offset
        local text    = (w.text or w.word or ''):gsub('^%s+', ''):gsub('%s+$', '')

        if cur_seg
           and cur_seg.speaker_id == global_speaker.id
           and (w_start - cur_seg.t_end) <= GAP_SECS_NEW_SEGMENT then
          -- Extend
          cur_seg.t_end = math.max(cur_seg.t_end, w_end)
          if text ~= '' then
            cur_seg.texts[#cur_seg.texts + 1] = text
            cur_seg.words[#cur_seg.words + 1] = { text = text, start = w_start, ['end'] = w_end }
          end
        else
          flush()
          cur_seg = {
            speaker_id = global_speaker.id,
            t_start    = w_start,
            t_end      = w_end,
            texts      = (text ~= '') and { text } or {},
            words      = (text ~= '') and { { text = text, start = w_start, ['end'] = w_end } } or {},
          }
        end
      end
    end
    flush()
  end

  return true, nil
end

----------------------------------------------------------------------------
-- Public: is_open() — caller checks dla render_modals dispatch logic.
----------------------------------------------------------------------------
function M.is_open()
  return s.initialized
end

return M
