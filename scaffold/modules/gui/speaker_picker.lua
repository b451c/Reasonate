-- modules/gui/speaker_picker.lua
-- NS-G (2026-05-14) — modal pickera mówcy + regionów dla IVC clone training.
--
-- Use case: multi-speaker source (podcast, wywiad, film dialog) — wtyczka
-- ma diarized transkrypt (Scribe diarize=true zwraca speaker_id per word),
-- ale dotychczas IVC trening brał "pierwszy item z tracku" jako sample →
-- klon mieszanych głosów = bezużyteczny.
--
-- Rozwiązanie: po user click Clone IVC, jeżeli diarize wykrywa ≥2 speakers,
-- otwórz ten modal. User wybiera ONE speakera (radio) + zaznacza regions
-- (checkboxy) do treningu. Plugin renderuje via audio_concat → spawn IVC.
--
-- Dispatched globalnie z reasonate.lua (mode-agnostic, używany przez Repair
-- i Dubbing flow). Modal-style state preserved across frames; close emits
-- callback.
--
-- Spec: docs/handover/PHASE-NS-G.md

local theme        = require 'modules.theme'
local util         = require 'modules.util'
local audio_concat = require 'modules.audio_concat'
local preview      = require 'modules.preview'

local M = {}

----------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------
local GAP_THRESHOLD_S      = 0.5     -- words within 0.5s = same region
local MIN_REGION_DURATION  = 0.4     -- skip very short regions (< 0.4s, single word artifacts)
local MIN_IVC_DURATION     = 10      -- below = red error, disabled
local SHORT_IVC_DURATION   = 30      -- 10-30s = amber "short"
local LONG_IVC_DURATION    = 180     -- 30-180s = green sweet spot
                                      -- 180-240s = amber "approaching limit"
local MAX_UPLOAD_DURATION  = 240     -- IVC API 11MB limit @ 22kHz mono 16-bit
                                      -- >240s = red disabled (would HTTP 400)

----------------------------------------------------------------------------
-- Internal state
----------------------------------------------------------------------------
local _state = {
  open                = false,
  pending_open        = false,
  pending_close       = false,
  opts                = nil,
  speakers            = nil,        -- list of speaker tables (computed)
  selected_speaker_id = nil,
  region_checked      = nil,        -- {speaker_id -> {region_idx -> bool}}
  preview_path        = nil,
  preview_err         = nil,
  error               = nil,
  train_in_progress   = false,      -- set true gdy on_train callback wywołany
}

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

-- Strip whitespace + truncate dla sample text display
local function truncate(s, max_chars)
  s = tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
  if #s <= max_chars then return s end
  return s:sub(1, max_chars - 1) .. '…'
end

-- Format mm:ss
local function fmt_mmss(seconds)
  local s = math.max(0, math.floor(seconds + 0.5))
  return string.format('%02d:%02d', math.floor(s / 60), s % 60)
end

-- Format duration (Xs / X.Xs / Xm Xs)
local function fmt_duration(seconds)
  if seconds < 1 then return string.format('%.1fs', seconds) end
  if seconds < 60 then return string.format('%.1fs', seconds) end
  local m = math.floor(seconds / 60)
  local s = seconds - m * 60
  return string.format('%dm %02ds', m, math.floor(s + 0.5))
end

----------------------------------------------------------------------------
-- compute_speakers(diarize_transcript) → list of speakers
--
-- Speaker structure:
--   { id            = 'speaker_0',
--     region_count  = int,
--     total_duration= float secs (sum regions),
--     sample_text   = string (first 60 chars combined),
--     regions       = list of regions sorted by duration desc
--   }
--
-- Region structure:
--   { idx        = int (1-based, stable),
--     start      = float secs,
--     end        = float secs,
--     duration   = float secs,
--     text       = string (concatenated word texts)
--   }
--
-- Speakers sorted by total_duration desc.
----------------------------------------------------------------------------
local function compute_speakers(diarize_transcript)
  if not diarize_transcript or type(diarize_transcript.words) ~= 'table' then
    return {}
  end
  local words = diarize_transcript.words

  -- Pass 1: group by speaker_id + build regions (consecutive same-speaker,
  -- gap < GAP_THRESHOLD_S)
  local speakers_map = {}    -- speaker_id -> { regions = [] }
  local cur_speaker = nil
  local cur_region  = nil
  local region_counter = 0

  for _, w in ipairs(words) do
    local spk = w.speaker_id or w.speaker or 'unknown'
    local w_start = tonumber(w.start) or 0
    local w_end   = tonumber(w['end']) or w_start
    local w_text  = w.text or w.word or ''
    -- Skip whitespace-only tokens (Scribe emit space tokens)
    if w_text:match('%S') then
      -- Note: gsub returns (string, count). Use intermediate local żeby
      -- multiple returns nie przeciekały do { ... } constructora ani jako
      -- 3-ciego arg do table.insert (count would be parsed jako position →
      -- "bad argument #2 to 'insert' (number expected, got string)").
      local w_clean = w_text:gsub('^%s+', ''):gsub('%s+$', '')
      if cur_speaker ~= spk
        or not cur_region
        or (w_start - (cur_region['end'] or 0)) > GAP_THRESHOLD_S
      then
        -- Flush previous region
        if cur_region and cur_speaker then
          if not speakers_map[cur_speaker] then
            speakers_map[cur_speaker] = { regions = {} }
          end
          if (cur_region['end'] - cur_region.start) >= MIN_REGION_DURATION then
            cur_region.duration = cur_region['end'] - cur_region.start
            cur_region.text     = table.concat(cur_region._words, ' ')
            cur_region._words   = nil
            region_counter      = region_counter + 1
            cur_region.idx      = region_counter
            cur_region.start_mmss = fmt_mmss(cur_region.start)
            table.insert(speakers_map[cur_speaker].regions, cur_region)
          end
        end
        -- Start new region
        cur_speaker = spk
        cur_region = {
          start   = w_start,
          ['end'] = w_end,
          _words  = { w_clean },
        }
      else
        -- Extend current region
        cur_region['end'] = w_end
        table.insert(cur_region._words, w_clean)
      end
    end
  end
  -- Flush last region
  if cur_region and cur_speaker then
    if not speakers_map[cur_speaker] then
      speakers_map[cur_speaker] = { regions = {} }
    end
    if (cur_region['end'] - cur_region.start) >= MIN_REGION_DURATION then
      cur_region.duration = cur_region['end'] - cur_region.start
      cur_region.text     = table.concat(cur_region._words, ' ')
      cur_region._words   = nil
      region_counter      = region_counter + 1
      cur_region.idx      = region_counter
      cur_region.start_mmss = fmt_mmss(cur_region.start)
      table.insert(speakers_map[cur_speaker].regions, cur_region)
    end
  end

  -- Pass 2: convert map → list with totals + sample text
  local out = {}
  for spk_id, data in pairs(speakers_map) do
    local total = 0
    for _, r in ipairs(data.regions) do total = total + r.duration end
    -- Sort regions by duration desc
    table.sort(data.regions, function(a, b) return a.duration > b.duration end)
    local sample_text = ''
    for _, r in ipairs(data.regions) do
      if r.text and r.text ~= '' then
        sample_text = r.text
        break
      end
    end
    table.insert(out, {
      id             = spk_id,
      region_count   = #data.regions,
      total_duration = total,
      sample_text    = truncate(sample_text, 80),
      regions        = data.regions,
    })
  end
  -- Sort speakers by total_duration desc
  table.sort(out, function(a, b) return a.total_duration > b.total_duration end)

  return out
end

----------------------------------------------------------------------------
-- validate_for_ivc(duration) → { status, message, color }
--
-- status ∈ { 'error', 'warn_short', 'good', 'warn_long' }
-- color: status pill RGBA
----------------------------------------------------------------------------
local function validate_for_ivc(duration)
  if duration < MIN_IVC_DURATION then
    return {
      status  = 'error',
      message = ('Too short — need ≥%ds for usable IVC'):format(MIN_IVC_DURATION),
      color   = theme.COLORS.status_error,
    }
  elseif duration < SHORT_IVC_DURATION then
    return {
      status  = 'warn_short',
      message = 'Short sample — may sound mechanical',
      color   = theme.COLORS.status_stale,
    }
  elseif duration <= LONG_IVC_DURATION then
    return {
      status  = 'good',
      message = 'Good sample length',
      color   = theme.COLORS.status_done,
    }
  elseif duration <= MAX_UPLOAD_DURATION then
    return {
      status  = 'warn_long',
      message = ('Approaching upload limit (max %ds @ 22kHz mono)'):format(MAX_UPLOAD_DURATION),
      color   = theme.COLORS.status_stale,
    }
  else
    return {
      status  = 'error',
      message = ('Too long — IVC upload limit %ds (11MB). Unselect some regions.')
        :format(MAX_UPLOAD_DURATION),
      color   = theme.COLORS.status_error,
    }
  end
end

----------------------------------------------------------------------------
-- Collect checked regions dla selected speaker → list (preserves modal order
-- of checkbox flags but uses region.start dla chronological output ordering
-- which makes audible concat more natural).
----------------------------------------------------------------------------
local function collect_selected_regions()
  if not _state.selected_speaker_id then return {} end
  local checked_map = (_state.region_checked or {})[_state.selected_speaker_id] or {}
  local speaker
  for _, spk in ipairs(_state.speakers or {}) do
    if spk.id == _state.selected_speaker_id then speaker = spk; break end
  end
  if not speaker then return {} end
  local out = {}
  for _, r in ipairs(speaker.regions or {}) do
    if checked_map[r.idx] then
      table.insert(out, { start = r.start, ['end'] = r['end'], idx = r.idx, text = r.text })
    end
  end
  -- Sort chronologically dla concat output
  table.sort(out, function(a, b) return a.start < b.start end)
  return out
end

----------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------

-- opts: {
--   diarize_transcript,            (required) — table {words=[{text,start,end,speaker_id}]}
--   source_item,                   (required) — REAPER MediaItem dla audio_concat
--   on_train(speaker_id, regions), (required) — callback po user click Train
--   on_cancel(),                   (optional) — callback po user click Cancel/X
--   suggested_speaker_id,          (optional) — pre-select tego speakera
--   speaker_label_map,             (optional) — { scribe_local_id → user-facing label }
--                                     e.g., { speaker_0 = 'Host', speaker_1 = 'Mati' }
--                                     used dla Dubbing context (project speakers named)
-- }
function M.open(opts)
  opts = opts or {}
  _state.opts                = opts
  _state.speakers            = compute_speakers(opts.diarize_transcript)
  _state.region_checked      = {}
  _state.selected_speaker_id = opts.suggested_speaker_id
  _state.preview_path        = nil
  _state.preview_err         = nil
  _state.error               = nil
  _state.train_in_progress   = false

  -- Auto-select pierwszy speaker (highest total duration) gdy brak suggested
  if not _state.selected_speaker_id and _state.speakers[1] then
    _state.selected_speaker_id = _state.speakers[1].id
  end

  -- Auto-check largest region jako start point — user może doczekać reszty.
  -- Per spec: lepszy UX niż empty modal. User decyduje czy chce więcej.
  if _state.selected_speaker_id then
    local spk
    for _, s in ipairs(_state.speakers) do
      if s.id == _state.selected_speaker_id then spk = s; break end
    end
    if spk and spk.regions[1] then
      _state.region_checked[spk.id] = { [spk.regions[1].idx] = true }
    end
  end

  _state.pending_open = true
  _state.open         = true
end

function M.is_open() return _state.open end

function M.close(invoke_cancel)
  if invoke_cancel and _state.opts and _state.opts.on_cancel then
    pcall(_state.opts.on_cancel)
  end
  _state.open                = false
  _state.opts                = nil
  _state.speakers            = nil
  _state.selected_speaker_id = nil
  _state.region_checked      = nil
  _state.preview_path        = nil
  _state.preview_err         = nil
  _state.error               = nil
  _state.train_in_progress   = false
end

----------------------------------------------------------------------------
-- Render — call from main frame() w reasonate.lua (globalne dispatch).
----------------------------------------------------------------------------
function M.render(ctx)
  if not _state.open then return end

  local POPUP_ID = 'Speaker picker — IVC clone source##speaker_picker'

  if _state.pending_open then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    _state.pending_open = false
  end

  -- Center popup na main Reasonate window (PM8: replaces viewport-based
  -- centering — follows app window even on second monitor). Constraints
  -- every frame guard przeciw popup auto-fit shrink (KNOWN-ISSUES.md).
  theme.center_next_modal(ctx)
  if reaper.ImGui_SetNextWindowSizeConstraints then
    -- W3: max height clamped do work area (sztywne 900 wychodziło poza
    -- ekran na laptopach).
    local max_h = 900
    local _, _, _, vh = theme.viewport_work_rect(ctx)
    if vh then max_h = math.min(max_h, math.floor(vh * 0.92)) end
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, 640, math.min(480, max_h), 640, max_h)
  else
    reaper.ImGui_SetNextWindowSize(ctx, 640, 720, reaper.ImGui_Cond_Appearing())
  end

  local flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoDocking()
  theme.popup_keep_top(ctx, POPUP_ID)
  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true, flags)
  if not visible then
    if not p_open then M.close(true) end
    return
  end

  -- X closed (p_open=false) → cancel
  if not p_open then
    reaper.ImGui_CloseCurrentPopup(ctx)
    reaper.ImGui_EndPopup(ctx)
    M.close(true)
    return
  end

  -- Section heading: detected speakers
  do
    local pushed = theme.push_heading(ctx, theme.SIZE.body_lg)
    reaper.ImGui_Text(ctx, 'Detected speakers (Scribe diarize):')
    if pushed then theme.pop_heading(ctx) end
  end

  reaper.ImGui_Spacing(ctx)

  -- Empty / single-speaker edge cases
  local speakers = _state.speakers or {}
  if #speakers == 0 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_error)
    reaper.ImGui_TextWrapped(ctx,
      'No speakers detected in this audio. Diarize transcript may be empty or invalid.')
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx); reaper.ImGui_Separator(ctx); reaper.ImGui_Spacing(ctx)
    if theme.button_neutral(ctx, 'Close##sp_close_empty') then
      reaper.ImGui_CloseCurrentPopup(ctx)
      reaper.ImGui_EndPopup(ctx)
      M.close(true)
      return
    end
    reaper.ImGui_EndPopup(ctx)
    return
  end

  -- Speakers radio list — z optional user-facing label map (Dubbing case:
  -- "Host (speaker_0)" zamiast raw "speaker_0").
  local label_map = (_state.opts and _state.opts.speaker_label_map) or {}
  local function user_label_for(spk_id)
    local mapped = label_map[spk_id]
    if mapped and mapped ~= '' then
      return mapped .. '  (' .. spk_id .. ')'
    end
    return spk_id
  end

  for _, spk in ipairs(speakers) do
    local label = string.format('%s    %d regions · %s total  ·  "%s"',
      user_label_for(spk.id),
      spk.region_count,
      fmt_duration(spk.total_duration),
      spk.sample_text or '')
    if reaper.ImGui_RadioButton(ctx, label .. '##sp_radio_' .. spk.id,
      _state.selected_speaker_id == spk.id)
    then
      if _state.selected_speaker_id ~= spk.id then
        _state.selected_speaker_id = spk.id
        -- Initialize checked map dla tego speakera jeśli pierwszy raz wybierany.
        -- Auto-check largest region (parity z M.open behavior).
        if not _state.region_checked[spk.id] and spk.regions[1] then
          _state.region_checked[spk.id] = { [spk.regions[1].idx] = true }
        end
        _state.preview_path = nil  -- regions changed → invalidate preview cache
      end
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Region selection panel
  local selected_speaker
  for _, spk in ipairs(speakers) do
    if spk.id == _state.selected_speaker_id then selected_speaker = spk; break end
  end

  if selected_speaker then
    do
      local pushed = theme.push_heading(ctx, theme.SIZE.body_lg)
      reaper.ImGui_Text(ctx, ('Regions for %s — pick at least %ds total:')
        :format(user_label_for(selected_speaker.id), MIN_IVC_DURATION))
      if pushed then theme.pop_heading(ctx) end
    end
    reaper.ImGui_Spacing(ctx)

    -- Quick actions
    local checked_map = _state.region_checked[selected_speaker.id] or {}
    _state.region_checked[selected_speaker.id] = checked_map

    if reaper.ImGui_SmallButton(ctx, 'Select all##sp_sel_all') then
      for _, r in ipairs(selected_speaker.regions) do checked_map[r.idx] = true end
      _state.preview_path = nil
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Unselect all##sp_sel_none') then
      for k in pairs(checked_map) do checked_map[k] = nil end
      _state.preview_path = nil
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, ('Auto-pick longest ≈%ds##sp_sel_auto'):format(SHORT_IVC_DURATION + 30)) then
      -- Greedy: select regions sorted by duration desc until total >= 60s
      for k in pairs(checked_map) do checked_map[k] = nil end
      local target = SHORT_IVC_DURATION + 30   -- ~60s default
      local total = 0
      for _, r in ipairs(selected_speaker.regions) do
        if total >= target then break end
        checked_map[r.idx] = true
        total = total + r.duration
      end
      _state.preview_path = nil
    end

    reaper.ImGui_Spacing(ctx)

    -- Scrollable regions list. Per region: ▶ play + ✓ checkbox + time + wrapped
    -- text. Wrap pozwala user zobaczyć pełen tekst regionu bez obcięcia (poprzednia
    -- wersja truncate'ała do 80 chars → user feedback: tekst poza oknem).
    local list_h = math.max(220, math.min(520, #selected_speaker.regions * 56 + 16))
    if reaper.ImGui_BeginChild(ctx, '##sp_regions_scroll', 0, list_h, 0, 0) then
      local child_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
      for ri, r in ipairs(selected_speaker.regions) do
        reaper.ImGui_PushID(ctx, 'sp_reg_' .. r.idx)
        reaper.ImGui_BeginGroup(ctx)

        -- ▶/■ play-stop toggle button (per-region single-region preview).
        -- Glyphs ▶ ■ verified safe w Inter font (Geometric Shapes range).
        -- Stable widget ID ('##playstop') — only visible glyph swaps, więc
        -- ImGui internal state nie reset'uje się przy toggle.
        local region_pid = 'sp_region_' .. r.idx
        local is_playing_this = preview and preview.is_playing and preview.is_playing(region_pid)
        local btn_glyph = (is_playing_this and '■' or '▶') .. '##playstop'
        if reaper.ImGui_SmallButton(ctx, btn_glyph) then
          _state.preview_err = nil
          if is_playing_this then
            -- Toggle off → stop
            if preview and preview.stop then preview.stop() end
          else
            local path, perr = audio_concat.concat_regions(
              _state.opts.source_item,
              { { start = r.start, ['end'] = r['end'], idx = r.idx, text = r.text } },
              {})
            if not path then
              _state.preview_err = perr or 'concat failed'
            elseif preview and preview.play_file then
              -- play_file (NIE play_url) bo path jest lokalny WAV.
              -- play_url próbuje pobrać przez curl traktując path jako URL.
              local ok, perr2 = preview.play_file(path, region_pid)
              if not ok then _state.preview_err = perr2 or 'preview failed' end
            else
              _state.preview_err = 'preview API unavailable (need SWS CF_Preview or system default app)'
            end
          end
        end
        reaper.ImGui_SameLine(ctx)

        -- ✓ checkbox (z time + duration jako label dla single-line readability)
        local check_label = string.format('%s  (%s)##chk', r.start_mmss, fmt_duration(r.duration))
        local rv, new_v = reaper.ImGui_Checkbox(ctx, check_label, checked_map[r.idx] == true)
        if rv then
          checked_map[r.idx] = new_v and true or nil
          _state.preview_path = nil
        end

        -- Wrapped text — full region content visible bez truncate
        reaper.ImGui_PushTextWrapPos(ctx, child_w - 8)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
        reaper.ImGui_TextWrapped(ctx, r.text or '')
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_PopTextWrapPos(ctx)

        reaper.ImGui_EndGroup(ctx)
        if ri < #selected_speaker.regions then
          reaper.ImGui_Separator(ctx)
        end
        reaper.ImGui_PopID(ctx)
      end
      reaper.ImGui_EndChild(ctx)
    end

    reaper.ImGui_Spacing(ctx)

    -- Validation banner
    local selected_regions = collect_selected_regions()
    local total_secs = audio_concat.total_duration(selected_regions)
    local val = validate_for_ivc(total_secs)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), val.color)
    reaper.ImGui_Text(ctx, string.format('Selected: %d region%s · %s total  ·  %s',
      #selected_regions,
      #selected_regions == 1 and '' or 's',
      fmt_duration(total_secs),
      val.message))
    reaper.ImGui_PopStyleColor(ctx, 1)

    if _state.error then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_error)
      reaper.ImGui_TextWrapped(ctx, 'Error: ' .. tostring(_state.error))
      reaper.ImGui_PopStyleColor(ctx, 1)
    end
    if _state.preview_err then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
      reaper.ImGui_TextWrapped(ctx, 'Preview: ' .. tostring(_state.preview_err))
      reaper.ImGui_PopStyleColor(ctx, 1)
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_TextWrapped(ctx,
      'Tip: longer + more diverse samples produce better IVC clones. ' ..
      'Recommend 60-300s with mixed prosody (questions, statements, emotion).')
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    -- Action band: Cancel | (right-aligned) Train
    -- Bottom "Preview" button removed — per-region ▶ na każdym rzędzie dostarcza
    -- już odsłuch (single + combined preview redundant). Per user feedback PM4.
    if theme.button_neutral(ctx, 'Cancel##sp_cancel') then
      reaper.ImGui_CloseCurrentPopup(ctx)
      reaper.ImGui_EndPopup(ctx)
      M.close(true)
      return
    end
    reaper.ImGui_SameLine(ctx)

    -- Right-align Train button via dummy spacer
    local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local train_w = 200
    if avail > train_w + 16 then
      reaper.ImGui_Dummy(ctx, avail - train_w - 8, 1)
      reaper.ImGui_SameLine(ctx)
    end

    local can_train = val.status ~= 'error'
      and #selected_regions > 0
      and _state.opts and _state.opts.on_train
    reaper.ImGui_BeginDisabled(ctx, not can_train or _state.train_in_progress)
    if theme.button_primary(ctx, 'Train IVC clone →##sp_train', train_w, 0) then
      _state.train_in_progress = true
      _state.error = nil
      -- Invoke callback. Caller is responsible dla audio_concat + spawn_train.
      -- We close modal po callback finished (may itself spawn async train —
      -- caller manages its own progress / handle elsewhere).
      local ok, err = pcall(_state.opts.on_train,
        _state.selected_speaker_id, selected_regions)
      if not ok then
        _state.error = tostring(err)
        _state.train_in_progress = false
      else
        -- MUSI być EndDisabled przed EndPopup w early-return — pair'uje
        -- BeginDisabled z linii 603. Bez tego ImGui: "Missing EndDisabled()".
        reaper.ImGui_EndDisabled(ctx)
        reaper.ImGui_CloseCurrentPopup(ctx)
        reaper.ImGui_EndPopup(ctx)
        M.close(false)
        return
      end
    end
    reaper.ImGui_EndDisabled(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

return M
