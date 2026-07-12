-- modules/dubbing_splicer.lua
-- NS-B M1 Part 2 — per-segment splice na REAPER timeline (full-segment MVP).
--
-- Per spec §15.2 + M1 milestone:
-- - M1 MVP: full-segment splice using Phase 11 splice.lua silence-aware speech
--   onset alignment. PL translation often differs w word count vs source —
--   per-word splice useful tylko gdy 1:1 word match (Phase 2/M3 polish).
-- - Place generated audio na [Dub <LANG>: <speaker>] track jako folder child
--   pod source track. Per Correction 2: track per speaker per lang (unique tracks).
-- - D_POSITION = seg.t_start (NIE seg.t_start - lead_sil — segments już
--   describe absolute timeline placement, nie inline phrase repair w środku
--   istniejącego itema jak Phase 11).
-- - Full-source layout w item: D_STARTOFFS=0, D_LENGTH = generated_audio_length.
--   User może drag edges dla manual fine-tune (per Phase 11 invariant 5c).
--
-- Niezmienniki:
--   #2 source nigdy modyfikowany audio — splice tworzy NEW item na separate track
--   #3 main thread only — splicer wywołany w consume_signals (defer loop)
--   #4 Undo block — splice_segment opcjonalnie open's Undo gdy in_undo_block=false
--      (caller może batch'ować wiele segments w jednym block)
--
-- Track strategy (per spec §7.3 + Correction 2):
--   Per project: source track (top of folder) → [Dub LANG: speaker] children
--   Track P_EXT: is_dub_track, dub_project_guid, dub_speaker_id, dub_target_lang
--   Item P_EXT: is_dub_output, dub_project_guid, dub_segment_id, dub_speaker_id

local util = require 'modules.util'
local helpers = require 'modules.reaper_helpers'
local colors = require 'modules.colors'
local cfg = require 'modules.config'
local tempo_math = require 'modules.tempo_math'

local M = {}

-- W2 M1 kalibracja tempo-fit (PHASE-W2 §2). M0-3 (audit 2026-07): config-
-- gated — Settings → General → "Diagnostic logging", default OFF; odczyt
-- per splice (event-driven, nie per frame).
local function DUB_FIT_DEBUG() return cfg.get_debug_logging() end

-- Margines bezpieczeństwa przy przelewie do slacku (§2.3a) — item nigdy
-- nie podchodzi bliżej niż 80ms do początku następnego segmentu speakera.
local SLACK_MARGIN_S = 0.08

----------------------------------------------------------------------------
-- W2 M2: pitch shifter dla stretchu mowy — élastique Soloist:Speech
-- (formant-preserving; uniform stretch markery bez niego brzmią "chipmunk
-- formant" przy większych rate). I_PITCHMODE per SDK: high 2 bytes =
-- shifter, low 2 bytes = submode, -1 = project default. Sloty bywają
-- wersjo-zależne → resolve W RUNTIME po nazwie (PHASE-W2 §3); hardcode
-- 0xB0002 (=720898, élastique 3.3.3 Soloist : Speech na REAPER 7.x) TYLKO
-- gdy enum API niedostępne. Enum dostępny ale brak matcha → -1 (project
-- default — nie strzelamy w obcy shifter).
--
-- opts {enum_modes, enum_submodes} = injectable dla testów headless;
-- produkcja woła bez opts (reaper.*) i cache'uje wynik per session.
----------------------------------------------------------------------------
local PITCHMODE_FALLBACK = 0xB0002
local speech_pitchmode_cache = nil

function M.resolve_speech_pitchmode(opts)
  if not opts and speech_pitchmode_cache ~= nil then
    return speech_pitchmode_cache
  end
  local enum_modes    = opts and opts.enum_modes    or reaper.EnumPitchShiftModes
  local enum_submodes = opts and opts.enum_submodes or reaper.EnumPitchShiftSubModes
  local result
  if not enum_modes or not enum_submodes then
    result = PITCHMODE_FALLBACK
  else
    result = -1
    -- Pełny scan + ostatni match wygrywa: lista zawiera élastique 2.2.8
    -- ORAZ 3.3.3 (nowsza dalej w enumie) — break na pierwszym brałby starą.
    local mode = 0
    while true do
      local ok, name = enum_modes(mode)
      if not ok then break end
      -- 'lastique' omija é w nazwie ("élastique 3.3.3 Soloist")
      if name and name:find('lastique') and name:find('Soloist') then
        local sub = 0
        while true do
          local sub_name = enum_submodes(mode, sub)
          if not sub_name then break end
          if sub_name:find('Speech') then
            result = (mode << 16) | sub
            break
          end
          sub = sub + 1
        end
      end
      mode = mode + 1
    end
  end
  if not opts then speech_pitchmode_cache = result end
  return result
end

local function apply_speech_pitchmode(take)
  local pm = M.resolve_speech_pitchmode()
  if pm and pm ~= -1 then
    reaper.SetMediaItemTakeInfo_Value(take, 'I_PITCHMODE', pm)
  end
end

local PEXT_PREFIX = 'P_EXT:Reasonate.'

local function set_track_pext(tr, key, value)
  reaper.GetSetMediaTrackInfo_String(tr, PEXT_PREFIX .. key, tostring(value or ''), true)
end

local function get_track_pext(tr, key)
  local _, v = reaper.GetSetMediaTrackInfo_String(tr, PEXT_PREFIX .. key, '', false)
  return v or ''
end

local function set_item_pext(it, key, value)
  reaper.GetSetMediaItemInfo_String(it, PEXT_PREFIX .. key, tostring(value or ''), true)
end

local function item_guid(it)
  local _, g = reaper.GetSetMediaItemInfo_String(it, 'GUID', '', false)
  return g
end

local function track_guid(tr)
  return reaper.GetTrackGUID(tr)
end

----------------------------------------------------------------------------
-- Resolve source track from project — for mixed_single uses item's track,
-- for multi_track uses pierwszy track jako anchor (M1 simplification — full
-- multi-track folder layout M2 polish).
----------------------------------------------------------------------------
local function resolve_source_track(project)
  if not project then return nil end
  if project.source_kind == 'mixed_single' and project.source_item_guid then
    -- Find item by GUID, get its track
    local count = reaper.CountMediaItems(0)
    for i = 0, count - 1 do
      local it = reaper.GetMediaItem(0, i)
      local _, g = reaper.GetSetMediaItemInfo_String(it, 'GUID', '', false)
      if g == project.source_item_guid then
        return reaper.GetMediaItemTrack(it)
      end
    end
    return nil
  elseif project.source_kind == 'multi_track' and project.source_track_guids
         and project.source_track_guids[1] then
    return helpers.find_track_by_guid(project.source_track_guids[1])
  end
  return nil
end

----------------------------------------------------------------------------
-- Find existing [Dub LANG: speaker] track via P_EXT match (project_guid +
-- speaker_id + target_lang triple). Returns track lub nil.
----------------------------------------------------------------------------
local function find_existing_dub_track(project_guid, speaker_id, target_lang)
  for tr in helpers.iter_tracks() do
    if get_track_pext(tr, 'is_dub_track') == '1' then
      if get_track_pext(tr, 'dub_project_guid') == project_guid
         and get_track_pext(tr, 'dub_speaker_id') == speaker_id
         and get_track_pext(tr, 'dub_target_lang') == target_lang then
        return tr
      end
    end
  end
  return nil
end

----------------------------------------------------------------------------
-- Build label "[Dub LANG: speaker_label]" — mirror dubbing_project.track_label.
-- Re-impl tu (zamiast require dubbing_project) by uniknąć potencjalnego cycle
-- (splicer used z dubbing.lua consume_signals → loaded późno).
----------------------------------------------------------------------------
local function build_track_label(speaker_label, lang)
  return ('[Dub %s: %s]'):format((lang or ''):upper(), speaker_label or '?')
end

----------------------------------------------------------------------------
-- Get or create [Dub LANG: speaker] track. New track inserted as folder child
-- pod source track (mimics NS-2d split flow). Sets P_EXT triple identifier.
--
-- Side-effect na source_track: if not already folder parent, makes it one
-- (I_FOLDERDEPTH=1). Sum-preserving: new child's depth = prev_source_depth - 1
-- so outer folder structure preserved.
--
-- Returns (track, nil) or (nil, err).
----------------------------------------------------------------------------
function M.get_or_create_dub_track(project, speaker, target_lang)
  if not project or not speaker or not target_lang then
    return nil, 'missing project / speaker / target_lang'
  end
  -- Cache by P_EXT lookup
  local existing = find_existing_dub_track(project.project_guid, speaker.id, target_lang)
  if existing then
    return existing, nil
  end

  local source_track = resolve_source_track(project)
  if not source_track then
    return nil, 'cannot resolve source track from project'
  end

  local prev_depth = helpers.get_track_folder_depth(source_track)
  local source_idx = math.floor(reaper.GetMediaTrackInfo_Value(source_track, 'IP_TRACKNUMBER'))

  -- User 2026-07-11: layout 'folder' (default) = dziecko folderu źródła
  -- (fader źródła steruje też dubami); 'flat' = zwykły track pod źródłem,
  -- POZA folderem (niezależna głośność).
  local layout = cfg.get_dubbing_track_layout()

  -- Already in folder? Check sibling [Dub:] tracks dla tego project — append po nich.
  -- M1 simplification: po prostu wsadzamy tuż pod source (lub po existing dub
  -- children gdy są).
  local insert_at = source_idx  -- IP_TRACKNUMBER 1-based, InsertTrackAtIndex 0-based → po source

  -- Flat, a źródło JUŻ jest folderem (np. wcześniejsze duby w trybie folder
  -- albo VR folder layout): wstaw ZA końcem całego poddrzewa — inaczej nowy
  -- track wpadłby do środka folderu mimo trybu flat.
  if layout == 'flat' and prev_depth == 1 then
    local acc = 1
    local i = source_idx           -- 0-based indeks pierwszego tracka PO źródle
    while acc > 0 do
      local tr = reaper.GetTrack(0, i)
      if not tr then break end
      acc = acc + helpers.get_track_folder_depth(tr)
      i = i + 1
    end
    insert_at = i
  end

  -- Scan past existing dub tracks dla tego projektu (insert after them)
  while true do
    local nxt = reaper.GetTrack(0, insert_at)
    if not nxt then break end
    if get_track_pext(nxt, 'is_dub_track') == '1'
       and get_track_pext(nxt, 'dub_project_guid') == project.project_guid then
      insert_at = insert_at + 1
    else
      break
    end
  end

  reaper.InsertTrackAtIndex(insert_at, true)
  local new_tr = reaper.GetTrack(0, insert_at)
  if not new_tr then return nil, 'InsertTrackAtIndex failed' end

  local label = build_track_label(speaker.label, target_lang)
  reaper.GetSetMediaTrackInfo_String(new_tr, 'P_NAME', label, true)

  -- Track color = output (purple, mirror voice replacement [AI])
  local rgb = colors.PALETTE.output and colors.PALETTE.output.rgb or { 128, 64, 192 }
  reaper.SetMediaTrackInfo_Value(new_tr, 'I_CUSTOMCOLOR',
    reaper.ColorToNative(rgb[1], rgb[2], rgb[3]) | 0x1000000)

  -- Folder layout: source becomes parent (if not already), this new child
  -- inherits prev_depth - 1 so outer folder structure preserved (sum-preserve).
  -- Only adjust source jeśli first dub track (other dub children dziedziczą).
  -- Flat (user 2026-07-11): ZERO manipulacji głębokością — track wstawiony
  -- za źródłem (lub za jego poddrzewem) zostaje zwykłym sąsiadem.
  if layout ~= 'flat' then
    if prev_depth ~= 1 then
      helpers.set_track_folder_depth(source_track, 1)
      helpers.set_track_folder_depth(new_tr, prev_depth - 1)
    else
      -- Source już folder parent — new track inherits depth 0 (sibling w środku)
      helpers.set_track_folder_depth(new_tr, 0)
    end
  end

  -- P_EXT identifiers
  set_track_pext(new_tr, 'is_dub_track', '1')
  set_track_pext(new_tr, 'dub_project_guid', project.project_guid)
  set_track_pext(new_tr, 'dub_speaker_id', speaker.id)
  set_track_pext(new_tr, 'dub_speaker_label', speaker.label or '')
  set_track_pext(new_tr, 'dub_target_lang', target_lang)
  if speaker.voices and speaker.voices[target_lang] then
    set_track_pext(new_tr, 'dub_voice_id', speaker.voices[target_lang])
  end

  return new_tr, nil
end

----------------------------------------------------------------------------
-- Find existing dub item dla segment (P_EXT match na project_guid + segment_id
-- + target_lang). Returns item lub nil. Used dla regenerate flow (add take
-- zamiast create new item).
----------------------------------------------------------------------------
local function find_existing_dub_item(project_guid, segment_id, target_lang)
  local item_count = reaper.CountMediaItems(0)
  for i = 0, item_count - 1 do
    local it = reaper.GetMediaItem(0, i)
    local _, marker = reaper.GetSetMediaItemInfo_String(it, PEXT_PREFIX .. 'is_dub_output', '', false)
    if marker == '1' then
      local _, pg = reaper.GetSetMediaItemInfo_String(it, PEXT_PREFIX .. 'dub_project_guid', '', false)
      local _, sg = reaper.GetSetMediaItemInfo_String(it, PEXT_PREFIX .. 'dub_segment_id', '', false)
      local _, tl = reaper.GetSetMediaItemInfo_String(it, PEXT_PREFIX .. 'dub_target_lang', '', false)
      if pg == project_guid and sg == segment_id and tl == target_lang then
        return it
      end
    end
  end
  return nil
end

----------------------------------------------------------------------------
-- Delete ALL existing dub items matching (project_guid, segment_id, target_lang).
-- Used dla cleanup gdy non-regen splice creates fresh item — bez tego
-- previous splice results accumulate (old per-word grid items, duplicates).
----------------------------------------------------------------------------
local function delete_all_existing_dub_items(project_guid, segment_id, target_lang)
  local item_count = reaper.CountMediaItems(0)
  local to_del = {}
  for i = 0, item_count - 1 do
    local it = reaper.GetMediaItem(0, i)
    local _, marker = reaper.GetSetMediaItemInfo_String(it, PEXT_PREFIX .. 'is_dub_output', '', false)
    if marker == '1' then
      local _, pg = reaper.GetSetMediaItemInfo_String(it, PEXT_PREFIX .. 'dub_project_guid', '', false)
      local _, sg = reaper.GetSetMediaItemInfo_String(it, PEXT_PREFIX .. 'dub_segment_id', '', false)
      local _, tl = reaper.GetSetMediaItemInfo_String(it, PEXT_PREFIX .. 'dub_target_lang', '', false)
      if pg == project_guid and sg == segment_id and tl == target_lang then
        to_del[#to_del + 1] = it
      end
    end
  end
  for _, it in ipairs(to_del) do
    local tr = reaper.GetMediaItem_Track(it)
    if tr then reaper.DeleteTrackMediaItem(tr, it) end
  end
  return #to_del
end

----------------------------------------------------------------------------
-- W2 M1 tempo-fit helpers (PHASE-W2 §2) — drabina liczona w tempo_math
-- (pure, headless-tested), tu tylko zbieranie inputów + aplikacja markerów.
----------------------------------------------------------------------------

-- Slack = wolna przestrzeń ZA spanem segmentu do startu NASTĘPNEGO segmentu
-- tego samego speakera (project-based, nie track scan — deterministyczne
-- niezależnie od kolejności splice'ów przy concurrency 3), minus margines.
-- Brak następnego → huge (rate i tak ograniczony 1.0 w drabinie).
local function compute_slack(project, segment)
  local best
  for _, sg in ipairs((project and project.segments) or {}) do
    if sg.id ~= segment.id
       and sg.speaker_id == segment.speaker_id
       and not sg.dub_excluded
       and (sg.t_start or 0) >= (segment.t_end or 0) - 1e-6 then
      if not best or sg.t_start < best then best = sg.t_start end
    end
  end
  if not best then return math.huge end
  return math.max(0, best - (segment.t_end or 0) - SLACK_MARGIN_S)
end

-- Region mowy z alignmentu: PIERWSZE/OSTATNIE non-space słowo (forced_align
-- words[] zawiera tokeny whitespace — KNOWN-ISSUES durable; surowe indeksy
-- NIGDY). Zwraca speech_start, speech_end lub nil gdy alignment bezużyteczny.
local function speech_region_from_alignment(alignment)
  if type(alignment) ~= 'table' or type(alignment.words) ~= 'table' then return nil end
  local first_s, last_e
  for _, w in ipairs(alignment.words) do
    local txt = w.text or w.word or ''
    if txt:match('%S') then
      local s = tonumber(w.start or w.timestamp)
      local e = tonumber(w['end'])
      if s and (not first_s or s < first_s) then first_s = s end
      if e and (not last_e or e > last_e) then last_e = e end
    end
  end
  if first_s and last_e and last_e > first_s then return first_s, last_e end
  return nil
end

local function apply_fit_markers(take, plan)
  if not reaper.SetTakeStretchMarker then return end
  for _, mk in ipairs(plan.markers) do
    reaper.SetTakeStretchMarker(take, -1, mk[1], mk[2])
  end
end

-- seg.dub_fit pisany w KAŻDEJ ścieżce splice (plan §2.4 — konsument pilla
-- i anti-skoku; dub_applied_ratio był per-word-only i nigdy nie czytany).
local function write_fit_to_segment(segment, target_lang, fit)
  segment.dub_fit = segment.dub_fit or {}
  segment.dub_fit[target_lang] = fit
end

local function fit_from_plan(plan, smoothed)
  return {
    natural_len  = plan.natural_len,
    speech_len   = plan.speech_len,
    fit_ratio    = plan.fit_ratio,
    applied_rate = plan.applied_rate,
    strategy     = plan.strategy,
    smoothed     = smoothed and true or false,
    gap_secs     = plan.gap_secs,
    gap_warn     = plan.gap_warn,
    overrun_secs = plan.overrun_secs,
    slack_used   = plan.slack_used,
  }
end

local function dbg_fit(segment, lang, plan)
  if not DUB_FIT_DEBUG() then return end
  reaper.ShowConsoleMsg(('[Dub fit] %s/%s: ratio=%.3f rate=%.3f strategy=%s gap=%.2fs overrun=%.2fs slack_used=%.2fs item=%.2fs\n')
    :format(tostring(segment.id or '?'), tostring(lang),
      plan.fit_ratio or 0, plan.applied_rate or 0, plan.strategy or '?',
      plan.gap_secs or 0, plan.overrun_secs or 0,
      (plan.slack_used == math.huge) and 0 or (plan.slack_used or 0),
      plan.item_len or 0))
end

----------------------------------------------------------------------------
-- Public: splice_segment(project, segment, speaker, target_lang, audio_path, opts)
--
-- Places generated audio on [Dub LANG: speaker] track at segment timeline pos.
-- W2 M1: force_span path używa tempo-fit ladder (markery kotwiczone na
-- REGIONIE MOWY, granice rate z config, gap za mową / slack / overrun —
-- PHASE-W2 §2) zamiast ślepego uniform stretchu 0→0/span→audio_len.
--
-- opts:
--   in_undo_block = false   (caller batch'uje wiele segments → otwórz raz)
--   alignment     = nil     (forced_align result words[] — region mowy dla
--                            tempo-fit; brak → PCM lead scan fallback)
--   regen         = false   (true = AddTake do existing item zamiast new item)
--   rate_override = nil     (wymuszony rate — anti-skok §2.4 / suwak M2)
--   smoothed      = false   (true gdy splice wynika z anti-skok smoothingu)
--
-- Returns: { ok=true, item, track, audio_len, dub_pos, dub_len, fit, ... }
--          lub { ok=false, err=... }.
----------------------------------------------------------------------------
function M.splice_segment(project, segment, speaker, target_lang, audio_path, opts)
  opts = opts or {}
  if not project or not segment or not speaker or not target_lang then
    return { ok = false, err = 'missing project/segment/speaker/lang' }
  end
  if not audio_path or audio_path == '' or not util.file_exists(audio_path) then
    return { ok = false, err = 'missing audio file: ' .. tostring(audio_path) }
  end

  local track, terr = M.get_or_create_dub_track(project, speaker, target_lang)
  if not track then return { ok = false, err = terr or 'no track' } end

  -- Load generated audio into PCM_Source
  local phrase_src = reaper.PCM_Source_CreateFromFile(audio_path)
  if not phrase_src then
    return { ok = false, err = 'PCM_Source_CreateFromFile failed: ' .. audio_path }
  end
  local audio_len = reaper.GetMediaSourceLength(phrase_src) or 0
  if audio_len <= 0 then
    if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
    return { ok = false, err = 'audio file zero length' }
  end

  -- Trigger peaks (background) — UI sees waveform ~1-2s later
  if reaper.PCM_Source_BuildPeaks then
    reaper.PCM_Source_BuildPeaks(phrase_src, 0)
  end

  -- Force-segment-span mode: item length = source segment span, audio uniformly
  -- time-stretched via stretch markers. Guarantees no overlap między adjacent
  -- items na same [Dub LANG: speaker] track.
  local force_span = cfg.get_dubbing_force_segment_span()
  local source_span = math.max(0.05, (segment.t_end or 0) - (segment.t_start or 0))

  -- W2 M2: trwały user override tempa (suwak) — wygrywa nad anti-skokiem
  -- (opts.rate_override) i drabiną; Reset w UI czyści pole → drabina wraca.
  local user_rate = segment.dub_stretch_override
                and segment.dub_stretch_override[target_lang]

  -- Short-segment guard: krótkie wtrącenia ("tak", "no", "ok", "potwierdzam") nie
  -- powinny być aggressively stretched — robi z nich robotic blob. Bypass force_span
  -- for short segments → native TTS length, accept brief overlap z sąsiednim itemem.
  local short_seg_bypass = false
  if force_span and source_span < cfg.get_dubbing_short_segment_threshold_s() then
    force_span = false
    short_seg_bypass = true
  end

  -- W2 M1: region mowy z alignmentu (preferowany — dokładny) → tempo-fit
  -- ladder kotwiczy markery na MOWIE, nie na pełnym audio z ciszami.
  local speech_start, speech_end = speech_region_from_alignment(opts.alignment)

  -- Detect leading silence dla speech onset alignment. Potrzebny gdy:
  -- (a) native mode — pozycjonowanie D_POSITION = t_start - lead_sil;
  -- (b) force_span BEZ alignmentu — lead_sil = fallback speech_start.
  local lead_sil = 0
  if not force_span or not speech_start then
    local nch = reaper.GetMediaSourceNumChannels and reaper.GetMediaSourceNumChannels(phrase_src) or 1
    if nch <= 0 then nch = 1 end
    local SEARCH_SECS = math.min(0.5, audio_len)
    local PEAK_RATE   = 1000
    local n = math.floor(SEARCH_SECS * PEAK_RATE)
    if n > 0 and reaper.PCM_Source_GetPeaks then
      local buf = reaper.new_array(n * nch * 2)
      buf.clear()
      local rv = reaper.PCM_Source_GetPeaks(phrase_src, PEAK_RATE, 0, nch, n, 0, buf)
      if rv and rv > 0 then
        local THRESHOLD = 0.012
        local max_off = 0
        local min_off = n * nch
        lead_sil = SEARCH_SECS  -- assume full silence found
        for i = 0, n - 1 do
          local hit = false
          for c = 0, nch - 1 do
            local mx = math.abs(buf[1 + max_off + i * nch + c] or 0)
            local mn = math.abs(buf[1 + min_off + i * nch + c] or 0)
            if mx > THRESHOLD or mn > THRESHOLD then hit = true; break end
          end
          if hit then
            lead_sil = i / PEAK_RATE
            break
          end
        end
      else
        lead_sil = 0.06  -- fallback heuristic
      end
    end
    lead_sil = math.max(0, math.min(lead_sil, audio_len * 0.5))
  end

  -- W2 M1: plan dopasowania (force_span only). Fallback regionu mowy bez
  -- alignmentu: onset z PCM scan, koniec = audio_len (trail nieznany).
  local fit_plan
  if force_span then
    if not speech_start then
      speech_start, speech_end = lead_sil, audio_len
    end
    local r_min, r_max = cfg.get_dubbing_fit_bounds()
    fit_plan = tempo_math.dub_fit_plan{
      span          = source_span,
      audio_len     = audio_len,
      speech_start  = speech_start,
      speech_end    = speech_end,
      r_min         = r_min,
      r_max         = r_max,
      slack         = compute_slack(project, segment),
      rate_override = user_rate or opts.rate_override,
    }
    -- Defensive: nil nie powinien się zdarzyć (guards wyżej odrzucają zerowe
    -- span/audio) — legacy uniform fallback zamiast crash.
    if not fit_plan then
      fit_plan = {
        strategy = 'fit', fit_ratio = source_span / audio_len,
        applied_rate = source_span / audio_len, item_len = source_span,
        markers = { { 0, 0 }, { source_span, audio_len } },
        gap_secs = 0, gap_warn = false, overrun_secs = 0, slack_used = 0,
        speech_len = audio_len, natural_len = audio_len, lead_take = 0,
      }
    end
  end

  -- Regen path: find existing item, add take
  local existing_item = opts.regen and find_existing_dub_item(project.project_guid, segment.id, target_lang) or nil

  local opened_block = false
  if not opts.in_undo_block then
    reaper.PreventUIRefresh(1)
    reaper.Undo_BeginBlock()
    opened_block = true
  end

  -- Non-regen: delete WSZYSTKIE matching items (cleanup prior per-word grid /
  -- duplicate splice results). Prevents accumulating ghost items po toggle change.
  if not existing_item then
    delete_all_existing_dub_items(project.project_guid, segment.id, target_lang)
  end

  local item, take
  local item_len_final  -- actual final item length (force_span vs native)
  if existing_item then
    -- AddTake (variants flow / regen)
    take = reaper.AddTakeToMediaItem(existing_item)
    reaper.SetMediaItemTake_Source(take, phrase_src)
    reaper.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', 0)
    reaper.SetMediaItemTakeInfo_Value(take, 'D_PLAYRATE', 1.0)
    reaper.SetActiveTake(take)
    if force_span then
      reaper.SetMediaItemTakeInfo_Value(take, 'B_PPITCH', 1)
      apply_speech_pitchmode(take)
      -- W2 M1: pozycja + długość z planu drabiny (gap → item krótszy niż
      -- span; slack → dłuższy). Re-assert D_POSITION = t_start (poprzedni
      -- splice mógł być native mode z onset shiftem — markery zakładają
      -- start itemu na t_start).
      reaper.SetMediaItemInfo_Value(existing_item, 'D_POSITION', segment.t_start or 0)
      reaper.SetMediaItemInfo_Value(existing_item, 'D_LENGTH', fit_plan.item_len)
      item_len_final = fit_plan.item_len
      -- Markery z drabiny — ReaScript SetTakeStretchMarker(take, idx, pos,
      -- srcposIn) per SDK: pos = TAKE timeline, srcposIn = SOURCE media (s).
      apply_fit_markers(take, fit_plan)
    else
      -- Native length mode: extend item if new take's audio is longer
      local cur_len = reaper.GetMediaItemInfo_Value(existing_item, 'D_LENGTH') or 0
      if audio_len > cur_len then
        reaper.SetMediaItemInfo_Value(existing_item, 'D_LENGTH', audio_len)
        item_len_final = audio_len
      else
        item_len_final = cur_len
      end
    end
    item = existing_item
  else
    -- Fresh item creation
    item = reaper.AddMediaItemToTrack(track)
    if not item then
      if opened_block then
        reaper.Undo_EndBlock('Reasonate: dub splice (failed)', -1)
        reaper.PreventUIRefresh(-1)
      end
      if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
      return { ok = false, err = 'AddMediaItemToTrack failed' }
    end
    take = reaper.AddTakeToMediaItem(item)
    reaper.SetMediaItemTake_Source(take, phrase_src)
    reaper.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', 0)
    reaper.SetMediaItemTakeInfo_Value(take, 'D_PLAYRATE',  1.0)
    if force_span then
      -- W2 M1: D_POSITION = seg.t_start exact, D_LENGTH z planu drabiny.
      -- Markery kotwiczone na regionie mowy (lead cisza ściśnięta ≤20ms,
      -- onset ~na t_start), rate w granicach config — pitch preserved
      -- (B_PPITCH=1). Gap → item kończy się z mową (+naturalny trail);
      -- slack/overrun → item dłuższy niż span (jawny status).
      reaper.SetMediaItemTakeInfo_Value(take, 'B_PPITCH', 1)
      apply_speech_pitchmode(take)
      reaper.SetMediaItemInfo_Value(item, 'D_POSITION', segment.t_start or 0)
      reaper.SetMediaItemInfo_Value(item, 'D_LENGTH',   fit_plan.item_len)
      item_len_final = fit_plan.item_len
      -- Stretch markers: (pos=take_time, srcposIn=source_time) per SDK convention.
      apply_fit_markers(take, fit_plan)
      -- 20ms boundary fade — masks any click między adjacent dub items
      local fade_len = math.min(0.020, item_len_final * 0.05)
      if fade_len > 0 then
        reaper.SetMediaItemInfo_Value(item, 'D_FADEINLEN',  fade_len)
        reaper.SetMediaItemInfo_Value(item, 'D_FADEOUTLEN', fade_len)
      end
    else
      -- Native length mode (legacy): D_POSITION = seg.t_start - lead_sil ;
      -- full-source layout D_LENGTH = audio_len. Speech onset alignment via
      -- silence detection. Adjacent items same speaker can overlap if TTS
      -- longer than source span.
      local dub_pos = math.max(0, (segment.t_start or 0) - lead_sil)
      reaper.SetMediaItemInfo_Value(item, 'D_POSITION', dub_pos)
      reaper.SetMediaItemInfo_Value(item, 'D_LENGTH',   audio_len)
      item_len_final = audio_len
    end
  end

  -- Take name (audition cycle readability)
  local name = ('Dub %s: %s'):format(target_lang:upper(), (segment.translations and segment.translations[target_lang]) or '?'):sub(1, 60)
  reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', name, true)

  -- P_EXT na item (per spec §7.4)
  set_item_pext(item, 'is_dub_output',      '1')
  set_item_pext(item, 'dub_project_guid',   project.project_guid)
  set_item_pext(item, 'dub_segment_id',     segment.id)
  set_item_pext(item, 'dub_speaker_id',     speaker.id)
  set_item_pext(item, 'dub_target_lang',    target_lang)
  set_item_pext(item, 'dub_source_text',    segment.source_text or '')
  set_item_pext(item, 'dub_translated_text',(segment.translations and segment.translations[target_lang]) or '')
  set_item_pext(item, 'dub_voice_id',       speaker.voices and speaker.voices[target_lang] or '')
  set_item_pext(item, 'dub_is_stale',       '0')
  set_item_pext(item, 'dub_generated_at',   tostring(os.time()))

  -- W2 M1: seg.dub_fit + P_EXT telemetry — pisane w KAŻDEJ ścieżce splice.
  local fit
  if fit_plan then
    fit = fit_from_plan(fit_plan, opts.smoothed)
    dbg_fit(segment, target_lang, fit_plan)
  else
    -- Native length path (force_span OFF lub short bypass): bez stretchu.
    local sp_len = math.max(0.05, audio_len - lead_sil)
    fit = {
      natural_len  = audio_len,
      speech_len   = sp_len,
      fit_ratio    = source_span / sp_len,
      applied_rate = 1.0,
      strategy     = 'natural',
      smoothed     = false,
      gap_secs     = 0,
      gap_warn     = false,
      overrun_secs = 0,
      slack_used   = 0,
    }
  end
  write_fit_to_segment(segment, target_lang, fit)
  set_item_pext(item, 'dub_fit_strategy', fit.strategy)
  set_item_pext(item, 'dub_fit_rate', ('%.4f'):format(fit.applied_rate))
  -- W2 M2: trwałość overridu na itemie (mirror repair_stretch_playrate);
  -- '' = auto (drabina). Aplikuje się tylko w force_span (native nie stretchuje).
  set_item_pext(item, 'dub_user_stretch',
    (force_span and user_rate) and ('%.4f'):format(user_rate) or '')

  -- I_CUSTOMCOLOR green (fresh dub) — mirror Phase 11 color convention.
  local g_rgb = colors.PALETTE.converted and colors.PALETTE.converted.rgb or { 80, 200, 80 }
  reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR',
    reaper.ColorToNative(g_rgb[1], g_rgb[2], g_rgb[3]) | 0x1000000)

  -- Force visual refresh
  reaper.UpdateItemInProject(item)
  reaper.UpdateArrange()

  if opened_block then
    reaper.Undo_EndBlock('Reasonate: dub splice segment', -1)
    reaper.PreventUIRefresh(-1)
    -- Build peaks dla visible items (background-async)
    reaper.Main_OnCommand(40047, 0)
  end

  -- Return item GUID + track GUID for project state update
  local out_item_guid = item_guid(item)
  local out_track_guid = track_guid(track)
  return {
    ok          = true,
    item        = item,
    track       = track,
    item_guid   = out_item_guid,
    track_guid  = out_track_guid,
    audio_len   = audio_len,
    dub_pos     = reaper.GetMediaItemInfo_Value(item, 'D_POSITION'),
    dub_len     = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH'),
    lead_silence_secs = lead_sil,
    force_span  = force_span,
    short_seg_bypass  = short_seg_bypass,
    source_span = source_span,
    fit         = fit,
  }
end

----------------------------------------------------------------------------
-- W2 M1: public wrapper slacku (konsument: anti-skok w modes/dubbing —
-- feasibility cap smoothingu liczy się z PEŁNEGO dostępnego slacku).
----------------------------------------------------------------------------
function M.compute_slack_for_segment(project, segment)
  return compute_slack(project, segment)
end

----------------------------------------------------------------------------
-- W2 M1 (+M2 reuse): refit_segment_item — przelicz dopasowanie NA ISTNIEJĄCYM
-- itemie segmentu: active take, ZERO API, zero nowych take'ów. Markery
-- kasowane i liczone od zera przy D_PLAYRATE=1.0 (pozycje markerów żyją
-- w take-time skalowanym playrate — NIGDY "playrate na istniejące markery").
-- Konsumenci: anti-skok §2.4 (rate_override ze smoothingu), suwak M2.
--
-- opts: rate_override / smoothed / alignment / in_undo_block (mirror
-- splice_segment). Bez alignmentu całe audio = mowa (refit to operacja
-- in-place; PCM scan pominięty świadomie — caller przekazuje alignment
-- gdy istnieje, a bez niego oryginalny splice też kotwiczył od lead_sil
-- tylko przy fresh splice).
----------------------------------------------------------------------------
function M.refit_segment_item(project, segment, target_lang, opts)
  opts = opts or {}
  if not project or not segment or not target_lang then
    return { ok = false, err = 'missing project/segment/lang' }
  end
  local item = find_existing_dub_item(project.project_guid, segment.id, target_lang)
  if not item then return { ok = false, err = 'dub item not found' } end
  local take = reaper.GetActiveTake(item)
  if not take then return { ok = false, err = 'no active take' } end
  local src = reaper.GetMediaItemTake_Source(take)
  local audio_len = src and reaper.GetMediaSourceLength(src) or 0
  if audio_len <= 0 then return { ok = false, err = 'zero-length source' } end

  local source_span = math.max(0.05, (segment.t_end or 0) - (segment.t_start or 0))
  local speech_start, speech_end = speech_region_from_alignment(opts.alignment)
  if not speech_start then
    speech_start, speech_end = 0, audio_len
  end
  -- W2 M2: user override (suwak) > opts.rate_override (anti-skok — i tak
  -- gated dla overridowanych segmentów) > drabina.
  local user_rate = segment.dub_stretch_override
                and segment.dub_stretch_override[target_lang]
  local r_min, r_max = cfg.get_dubbing_fit_bounds()
  local plan = tempo_math.dub_fit_plan{
    span          = source_span,
    audio_len     = audio_len,
    speech_start  = speech_start,
    speech_end    = speech_end,
    r_min         = r_min,
    r_max         = r_max,
    slack         = compute_slack(project, segment),
    rate_override = user_rate or opts.rate_override,
  }
  if not plan then return { ok = false, err = 'fit plan failed' } end

  local opened_block = false
  if not opts.in_undo_block then
    reaper.Undo_BeginBlock()
    opened_block = true
  end
  reaper.SetMediaItemTakeInfo_Value(take, 'D_PLAYRATE', 1.0)
  reaper.SetMediaItemTakeInfo_Value(take, 'B_PPITCH', 1)
  apply_speech_pitchmode(take)
  if reaper.GetTakeNumStretchMarkers and reaper.DeleteTakeStretchMarkers then
    local n = reaper.GetTakeNumStretchMarkers(take)
    if n and n > 0 then reaper.DeleteTakeStretchMarkers(take, 0, n) end
  end
  reaper.SetMediaItemInfo_Value(item, 'D_POSITION', segment.t_start or 0)
  reaper.SetMediaItemInfo_Value(item, 'D_LENGTH', plan.item_len)
  apply_fit_markers(take, plan)

  local fit = fit_from_plan(plan, opts.smoothed)
  write_fit_to_segment(segment, target_lang, fit)
  set_item_pext(item, 'dub_fit_strategy', fit.strategy)
  set_item_pext(item, 'dub_fit_rate', ('%.4f'):format(fit.applied_rate))
  set_item_pext(item, 'dub_user_stretch',
    user_rate and ('%.4f'):format(user_rate) or '')
  dbg_fit(segment, target_lang, plan)
  reaper.UpdateItemInProject(item)

  if opened_block then
    reaper.Undo_EndBlock('Reasonate: dub re-fit ' .. tostring(segment.id or ''), -1)
  end
  return { ok = true, item = item, fit = fit }
end

----------------------------------------------------------------------------
-- M3.6 Public: splice_segment_per_word(project, segment, speaker, lang, audio_path, alignment, opts)
--   alignment.words = TTS-side per-word timestamps [{text, start, end, loss}].
--   segment.source_words = source-side per-word timestamps [{text, start, end}].
--
-- Behavior: gdy word counts match w 20% tolerance, create N items per segment,
-- each D_POSITION = source_word.start, D_LENGTH = tts_word.end - tts_word.start,
-- D_STARTOFFS = tts_word.start. Result: per-word lip-sync alignment.
--
-- Fallback: returns ok=false z reason='word_count_mismatch' lub 'missing_data'
-- → caller should fall back do splice_segment (full-segment).
--
-- Items: separate small REAPER items, NO take batching (each item independent).
-- All items on same [Dub LANG: speaker] folder track.
-- P_EXT mirror full-segment: same dub_segment_id na każdy item (helps stale
-- propagation find all per-word items dla segment).
----------------------------------------------------------------------------
-- M4.5: per-language word count tolerance table.
-- Reasoning: Polish/Czech are highly inflected (compound roots) — counts może
-- match w 25%. German has compound nouns longer than English (less words).
-- Japanese/Mandarin highly compressed (fewer words per equivalent meaning).
-- Default 25% (conservative — bumped z 20% per live test feedback).
local PER_LANG_TOLERANCE = {
  en = 0.20,  -- baseline
  pl = 0.30,  -- Polish: case inflections + lack of articles
  cs = 0.30,  -- Czech similar
  ru = 0.30,  -- Russian similar
  uk = 0.30,
  de = 0.30,  -- German compound nouns
  ja = 0.50,  -- Japanese highly compressed
  zh = 0.50,  -- Mandarin similar
  ko = 0.40,
  fi = 0.30,  -- Finnish agglutinative
  hu = 0.30,
}
local DEFAULT_TOLERANCE = 0.25

local function tolerance_for_lang(lang)
  return PER_LANG_TOLERANCE[lang] or DEFAULT_TOLERANCE
end

function M.splice_segment_per_word(project, segment, speaker, target_lang, audio_path, alignment, opts)
  opts = opts or {}
  if not project or not segment or not speaker or not target_lang then
    return { ok = false, err = 'missing project/segment/speaker/lang' }
  end
  if not audio_path or audio_path == '' or not util.file_exists(audio_path) then
    return { ok = false, err = 'missing audio file' }
  end
  if not alignment or type(alignment.words) ~= 'table' then
    return { ok = false, err = 'missing_data: alignment.words' }
  end
  local source_words = segment.source_words
  if type(source_words) ~= 'table' or #source_words == 0 then
    return { ok = false, err = 'missing_data: segment.source_words' }
  end

  local n_src = #source_words
  local n_tts = #alignment.words
  if n_src == 0 or n_tts == 0 then
    return { ok = false, err = 'word_count_zero' }
  end
  -- Short-segment guard: krótkie wtrącenia (≤ threshold) → fallback do full-segment,
  -- które samo ma własny short_seg_bypass → finalnie native TTS length (no stretch).
  local seg_span = (segment.t_end or 0) - (segment.t_start or 0)
  if seg_span < cfg.get_dubbing_short_segment_threshold_s() then
    return { ok = false, err = ('short_segment: %.2fs < threshold'):format(seg_span) }
  end
  -- M4.5: per-lang tolerance lookup
  local tol = tolerance_for_lang(target_lang)
  local diff_ratio = math.abs(n_src - n_tts) / math.max(n_src, n_tts)
  if diff_ratio > tol then
    return { ok = false, err = ('word_count_mismatch: src=%d tts=%d (>%.0f%% lang %s)'):format(n_src, n_tts, tol * 100, target_lang) }
  end

  if not reaper.SetTakeStretchMarker then
    return { ok = false, err = 'SetTakeStretchMarker API unavailable (REAPER < 5.95)' }
  end

  local track, terr = M.get_or_create_dub_track(project, speaker, target_lang)
  if not track then return { ok = false, err = terr or 'no track' } end

  local opened_block = false
  if not opts.in_undo_block then
    reaper.PreventUIRefresh(1)
    reaper.Undo_BeginBlock()
    opened_block = true
  end

  -- Cleanup prior splice items (handles both old full-segment AND old buggy
  -- per-word grid items from pre-M4 rewrite).
  if not opts.regen then
    delete_all_existing_dub_items(project.project_guid, segment.id, target_lang)
  end

  -- Single item z full TTS audio. Stretch markers map per-word source→TTS pairing.
  local phrase_src = reaper.PCM_Source_CreateFromFile(audio_path)
  if not phrase_src then
    if opened_block then
      reaper.Undo_EndBlock('Reasonate: per-word splice (failed)', -1)
      reaper.PreventUIRefresh(-1)
    end
    return { ok = false, err = 'PCM_Source_CreateFromFile failed' }
  end
  local audio_len = reaper.GetMediaSourceLength(phrase_src) or 0

  -- Item span EXACTLY = source segment span. Start/end alignement priorytet —
  -- audio time-stretched żeby fit, niezależnie od stretch ratio (no clamp).
  -- Per user: "zeby poczatek i koniec oryginalu byl spojny z poczatkiem
  -- i koncem itemu tlumaczenia".
  local item_pos = segment.t_start or source_words[1].start or 0
  local item_end = segment.t_end   or source_words[#source_words]['end'] or (item_pos + audio_len)
  local item_len = math.max(0.05, item_end - item_pos)

  -- Trigger peakfile build (background) — waveform display refresh
  if reaper.PCM_Source_BuildPeaks then
    reaper.PCM_Source_BuildPeaks(phrase_src, 0)
  end

  local item = reaper.AddMediaItemToTrack(track)
  if not item then
    if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(phrase_src) end
    if opened_block then
      reaper.Undo_EndBlock('Reasonate: per-word splice (failed)', -1)
      reaper.PreventUIRefresh(-1)
    end
    return { ok = false, err = 'AddMediaItemToTrack failed' }
  end
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, phrase_src)
  reaper.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', 0)
  reaper.SetMediaItemTakeInfo_Value(take, 'D_PLAYRATE',  1.0)
  -- B_PPITCH=1 = preserve pitch when stretching (essential dla mowy).
  -- W2 M2: algorytm jawnie per-take — élastique Soloist:Speech
  -- (formant-preserving; resolve runtime, brak → project default).
  reaper.SetMediaItemTakeInfo_Value(take, 'B_PPITCH', 1)
  apply_speech_pitchmode(take)
  reaper.SetMediaItemInfo_Value(item, 'D_POSITION', item_pos)
  reaper.SetMediaItemInfo_Value(item, 'D_LENGTH',   item_len)

  -- Volume fade ~20ms in/out — masks any boundary click między adjacent items
  -- na timeline. Independent z stretch — pure volume envelope.
  local FADE_LEN = math.min(0.020, item_len * 0.05)
  if FADE_LEN > 0 then
    reaper.SetMediaItemInfo_Value(item, 'D_FADEINLEN',  FADE_LEN)
    reaper.SetMediaItemInfo_Value(item, 'D_FADEOUTLEN', FADE_LEN)
  end

  -- Elastic pause redistribution: słowa dostają uniform clamped rate (±12% od
  -- natural), pauzy absorbują pozostały budget. Eliminuje skrajne per-word
  -- stretches (jedno słowo bardzo wolne / drugie bardzo szybkie) — mowa
  -- zachowuje natural tempo, ciszy nikt nie usłyszy.
  --
  -- ReaScript SetTakeStretchMarker(take, idx, pos, srcposIn) per SDK:
  --   pos      (arg2) = position on TAKE timeline (relative to item start)
  --   srcposIn (arg3) = position in SOURCE media (audio file seconds)
  -- Wcześniejszy komentarz w kodzie (pre-fix 2026-05-12) sugerował odwrotną
  -- konwencję — była ona BŁĘDNA i powodowała audio truncation (REAPER
  -- interpretował (audio_len, item_len) jako pos beyond item bounds, audio
  -- crapped przed końcem słowa). Live test confirmed SDK convention is correct.

  local WORD_CLAMP_LO = 0.88
  local WORD_CLAMP_HI = 1.12
  local MIN_PAUSE_TAKE = 0.005   -- 5ms minimum w take time dla każdej pauzy

  -- Extract TTS word spans + pauses
  local tts_starts, tts_ends, tts_word_durs = {}, {}, {}
  local sum_word_dur = 0
  for i = 1, n_tts do
    local w = alignment.words[i]
    local s = w.start or w.timestamp or 0
    local e = w['end'] or (s + 0.05)
    if e < s then e = s end
    tts_starts[i] = s
    tts_ends[i]   = e
    tts_word_durs[i] = e - s
    sum_word_dur = sum_word_dur + tts_word_durs[i]
  end

  -- TTS gaps: lead silence, inter-word pauses, tail silence
  local tts_lead = math.max(0, tts_starts[1])
  local tts_tail = math.max(0, audio_len - tts_ends[n_tts])
  local tts_pauses = {}
  local sum_pause_dur = tts_lead + tts_tail
  for i = 1, n_tts - 1 do
    local p = tts_starts[i+1] - tts_ends[i]
    if p < 0 then p = 0 end
    tts_pauses[i] = p
    sum_pause_dur = sum_pause_dur + p
  end

  -- Mean rate: ile musi się rozciągnąć cały segment (item_len / audio_len)
  local mean_rate = (audio_len > 0) and (item_len / audio_len) or 1.0

  -- Word rate: clamp mean do [0.88, 1.12]. Wszystkie słowa dostają TEN SAM rate
  -- (uniform między sobą, ale dalej od ekstremów per-word).
  local word_rate = math.max(WORD_CLAMP_LO, math.min(WORD_CLAMP_HI, mean_rate))
  local sum_target_word = sum_word_dur * word_rate
  local pause_budget = item_len - sum_target_word

  -- Edge case: gdy clamp do bound nie wystarczy (mean_rate poza [0.88,1.12]
  -- i pauzy musiałyby być ujemne lub minimum). Relax clamp — pauzy zostają
  -- na 5ms each, słowa absorbują resztę. Audible tempo change ale rzadkie.
  local count_pauses = (tts_lead > 0 and 1 or 0) + (tts_tail > 0 and 1 or 0)
  for i = 1, n_tts - 1 do
    if tts_pauses[i] > 0 then count_pauses = count_pauses + 1 end
  end
  local min_total_pause = count_pauses * MIN_PAUSE_TAKE
  local relaxed = false
  if pause_budget < min_total_pause and sum_word_dur > 0 then
    local effective_word_budget = math.max(0.01, item_len - min_total_pause)
    word_rate = effective_word_budget / sum_word_dur
    sum_target_word = sum_word_dur * word_rate
    pause_budget = item_len - sum_target_word
    relaxed = true
  end

  -- Pause rate: budget proporcjonalnie do TTS pause lengths
  local pause_rate
  if sum_pause_dur > 0 then
    pause_rate = pause_budget / sum_pause_dur
  else
    pause_rate = 1.0   -- brak pauz, nieistotne
  end
  if pause_rate < 0 then pause_rate = 0 end

  -- Store mean rate dla legacy field compatibility (M4+ propagation hooks)
  if not segment.dub_applied_ratio then segment.dub_applied_ratio = {} end
  segment.dub_applied_ratio[target_lang] = mean_rate

  -- W2 M1: dub_fit pisany też w ścieżce per-word (konsument: pill statusu;
  -- anti-skok §2.4 pomija per-word — słowa mają własny clamp, pauzy
  -- amortyzują budżet, więc skoki tempa nie występują tą drogą).
  write_fit_to_segment(segment, target_lang, {
    natural_len  = audio_len,
    speech_len   = sum_word_dur,
    fit_ratio    = mean_rate,
    applied_rate = word_rate,
    strategy     = 'per_word',
    smoothed     = false,
    gap_secs     = 0,
    gap_warn     = false,
    overrun_secs = 0,
    slack_used   = 0,
    relaxed      = relaxed,
  })

  -- Place markers: walk through TTS audio. Między markerami REAPER linearnie
  -- interpoluje rate, więc:
  --   word body → rate = word_rate (uniform, ±12% od 1.0)
  --   pause body → rate = pause_rate (uniform, może być >>1 lub <<1, niesłyszalne)
  local n_markers = 0

  -- Start anchor
  reaper.SetTakeStretchMarker(take, -1, 0, 0)
  n_markers = n_markers + 1

  local cur_src  = 0
  local cur_take = 0

  -- Lead silence (gdy TTS startuje z ciszą)
  if tts_lead > 0 then
    cur_src  = tts_lead
    cur_take = tts_lead * pause_rate
    if cur_take > 0 and cur_take < item_len and cur_src < audio_len then
      reaper.SetTakeStretchMarker(take, -1, cur_take, cur_src)
      n_markers = n_markers + 1
    end
  end

  for i = 1, n_tts do
    -- Body słowa i: advance src i take z word_rate
    cur_src  = cur_src + tts_word_durs[i]
    cur_take = cur_take + tts_word_durs[i] * word_rate
    if i < n_tts then
      -- Marker na końcu słowa i (= początek pauzy)
      if cur_take > 0 and cur_take < item_len and cur_src > 0 and cur_src < audio_len then
        reaper.SetTakeStretchMarker(take, -1, cur_take, cur_src)
        n_markers = n_markers + 1
      end
      -- Body pauzy między słowem i a i+1 (z pause_rate)
      if tts_pauses[i] > 0 then
        cur_src  = cur_src + tts_pauses[i]
        cur_take = cur_take + tts_pauses[i] * pause_rate
        -- Marker na początku następnego słowa (= koniec pauzy)
        if cur_take > 0 and cur_take < item_len and cur_src > 0 and cur_src < audio_len then
          reaper.SetTakeStretchMarker(take, -1, cur_take, cur_src)
          n_markers = n_markers + 1
        end
      end
    end
  end

  -- End anchor — pin take=item_len to source=audio_len. Krytyczne dla exact span match.
  reaper.SetTakeStretchMarker(take, -1, item_len, audio_len)
  n_markers = n_markers + 1

  -- NB: slope removed (legacy fix #26 deteriorated audio — z poprawnym word_rate
  -- transitions są implicit smooth: rate change wpada w ciszę przy granicach
  -- słów, body słowa ma consistent rate). Ease tylko wprowadzał wow/flutter.
  -- NB: cross-item bridge marker removed (legacy fix #27 — item_len=source_span
  -- gwarantuje implicit tempo alignment via source positions).

  -- P_EXT (mirror splice_segment dla stale propagation + identification)
  local _, item_guid_str = reaper.GetSetMediaItemInfo_String(item, 'GUID', '', false)
  set_item_pext(item, 'is_dub_output',     '1')
  set_item_pext(item, 'is_dub_per_word',   '1')
  set_item_pext(item, 'dub_n_stretch_markers', tostring(n_markers))
  set_item_pext(item, 'dub_stretch_word_rate',  ('%.4f'):format(word_rate))
  set_item_pext(item, 'dub_stretch_pause_rate', ('%.4f'):format(pause_rate))
  set_item_pext(item, 'dub_stretch_mean_rate',  ('%.4f'):format(mean_rate))
  set_item_pext(item, 'dub_stretch_relaxed',    relaxed and '1' or '0')
  set_item_pext(item, 'dub_project_guid',  project.project_guid or '')
  set_item_pext(item, 'dub_segment_id',    segment.id or '')
  set_item_pext(item, 'dub_speaker_id',    segment.speaker_id or '')
  set_item_pext(item, 'dub_target_lang',   target_lang)
  set_item_pext(item, 'dub_source_text',   segment.source_text or '')
  set_item_pext(item, 'dub_translated_text', (segment.translations and segment.translations[target_lang]) or '')
  set_item_pext(item, 'dub_voice_id',      (speaker.voices and speaker.voices[target_lang]) or '')
  set_item_pext(item, 'dub_is_stale',      '0')
  set_item_pext(item, 'dub_generated_at',  tostring(os.time()))

  -- Green I_CUSTOMCOLOR (fresh dub)
  local c_rgb = colors.PALETTE and colors.PALETTE.fresh and colors.PALETTE.fresh.rgb or { 128, 224, 144 }
  reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR',
    reaper.ColorToNative(c_rgb[1], c_rgb[2], c_rgb[3]) | 0x1000000)

  -- Refresh REAPER display: peaks pending → waveform appears po BuildPeaks
  -- completes (background). UpdateItemInProject forces re-layout including
  -- stretch marker rendering w take edit view.
  reaper.UpdateItemInProject(item)
  reaper.UpdateArrange()

  if opened_block then
    reaper.Undo_EndBlock('Reasonate: per-word splice ' .. (segment.id or ''), -1)
    reaper.PreventUIRefresh(-1)
  end

  return {
    ok          = true,
    item        = item,
    item_guid   = item_guid_str,
    n_items     = 1,                  -- ONE REAPER item (stretch markers internal)
    n_markers   = n_markers,
    per_word    = true,
    word_rate   = word_rate,
    pause_rate  = pause_rate,
    mean_rate   = mean_rate,
    relaxed     = relaxed,
  }
end

----------------------------------------------------------------------------
-- Public: mark_item_stale(item) — flip P_EXT.dub_is_stale='1' + I_CUSTOMCOLOR=cyan.
-- Called z mode_module gdy translation edit lub voice settings override.
----------------------------------------------------------------------------
function M.mark_item_stale(item)
  if not item then return end
  set_item_pext(item, 'dub_is_stale', '1')
  -- Cyan stale color (mirror Phase 11 convention)
  local c_rgb = colors.PALETTE.stale and colors.PALETTE.stale.rgb or { 100, 200, 220 }
  reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR',
    reaper.ColorToNative(c_rgb[1], c_rgb[2], c_rgb[3]) | 0x1000000)
end

return M
