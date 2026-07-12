-- modules/dubbing_project.lua
-- NS-B Dubbing: data model factory + helpers.
--
-- Multi-language ready od M1 (per Correction 2). Voices, translations,
-- dub output — wszystkie per-lang maps. UI active_target_language switcher
-- przełącza widok ale data trzyma WSZYSTKIE languages równocześnie.
--
-- Niezmiennik #2 (source nigdy nie modyfikowany audio) enforce'owany na
-- użytkowniku przez track structure: source = top, [Dub <LANG>: <speaker>]
-- jako folder children pod source.
--
-- Time fields naming convention: t_start / t_end (NIE 'end' bo reserved
-- word w Lua wymaga bracket access).

local util = require 'modules.util'
local cfg  = require 'modules.config'
local dubbing_state = require 'modules.dubbing_state'

local M = {}

M.VERSION = 1

----------------------------------------------------------------------------
-- Defaults
----------------------------------------------------------------------------
M.DEFAULT_VOICE_SETTINGS = {
  stability        = 0.5,
  similarity_boost = 0.75,
  style            = 0.0,
  speed            = 1.0,
  speaker_boost    = true,
}

-- Style presets — rozbudowa 2026-06-10 (user-approved ~13, było 5 per spec
-- §13.2 AD3). Pola enum MUSZĄ mieścić się w opcjach dropdownów
-- dubbing_context.lua. `label` = UI display (4 consumers iterują
-- STYLE_PRESET_ORDER). `brief` = 1-3 zdania wskazówek stylu (EN) — apply
-- presetu wpisuje go do context.free_text (widoczny/edytowalny; wchodzi
-- w system prompt i context_hash, więc inwaliduje translate cache).
M.STYLE_PRESETS = {
  drama_modern = {
    label = 'Drama / film & series',
    tone = 'informal', era = 'modern', audience = 'adult', media_type = 'drama_film', honorific = 'mix',
    brief = 'Write natural spoken dialogue, not prose — contractions, interruptions and colloquial word order are welcome. Prioritize subtext, tension and emotional truth over literal accuracy. Keep lines as punchy as the original.',
  },
  drama_period = {
    label = 'Period / historical drama',
    tone = 'dramatic', era = 'historical', audience = 'adult', media_type = 'drama_film', honorific = 'formal',
    brief = 'Use slightly elevated, era-appropriate language; avoid modern slang and anachronisms. Keep forms of address and titles consistent with period etiquette, without turning stiff or archaic to the point of parody.',
  },
  comedy = {
    label = 'Comedy / sitcom',
    tone = 'informal', era = 'modern', audience = 'mixed', media_type = 'drama_film', honorific = 'informal',
    brief = 'Joke timing beats literal accuracy: adapt puns, wordplay and cultural references to equivalents that genuinely land in the target language. Keep punchlines at the end of the line and protect the setup-punchline rhythm.',
  },
  thriller_horror = {
    label = 'Thriller / horror',
    tone = 'dramatic', era = 'modern', audience = 'adult', media_type = 'drama_film', honorific = 'mix',
    brief = 'Terse, tense lines — short sentences, no softening of menace. Preserve ambiguity and dread; never explain what the original leaves unsaid.',
  },
  kids = {
    label = 'Kids / animation',
    tone = 'informal', era = 'modern', audience = 'kids', media_type = 'animation', honorific = 'informal',
    brief = 'Simple vocabulary, short sentences, playful rhythm and lots of energy. Avoid idioms children may not know; keep character names and catchphrases consistent and fun to say aloud.',
  },
  documentary = {
    label = 'Documentary / factual',
    tone = 'neutral', era = 'modern', audience = 'mixed', media_type = 'documentary', honorific = 'formal',
    brief = 'Clear, factual register with precise terminology — keep domain terms exact rather than paraphrased. Measured narration flow; no dramatization beyond what the source carries.',
  },
  podcast_interview = {
    label = 'Podcast / interview',
    tone = 'conversational', era = 'modern', audience = 'adult', media_type = 'podcast', honorific = 'mix',
    brief = 'Loose conversational register with natural connectors and discourse markers. Preserve each speaker\'s personality and quirks; smooth out only what genuinely hurts listening.',
  },
  news_report = {
    label = 'News / reportage',
    tone = 'formal', era = 'modern', audience = 'mixed', media_type = 'documentary', honorific = 'formal',
    brief = 'Broadcast news register: concise declarative sentences, neutral vocabulary, no editorializing. Lead with the key fact; numbers, names and titles must be exact.',
  },
  corporate = {
    label = 'Corporate / e-learning',
    tone = 'formal', era = 'modern', audience = 'professional', media_type = 'training', honorific = 'formal',
    brief = 'Professional, clear, friendly but businesslike. Keep product names, UI labels and role titles consistent throughout; prefer plain language over corporate jargon; instructions must be unambiguous.',
  },
  commercial = {
    label = 'Commercial / advert',
    tone = 'conversational', era = 'modern', audience = 'mixed', media_type = 'commercial', honorific = 'informal',
    brief = 'Punchy persuasive copy: rhythm, brand tone and memorability beat literal wording. Slogans and calls to action must sound idiomatic and natural, as if written for the target market.',
  },
  audiobook_fiction = {
    label = 'Audiobook — fiction',
    tone = 'neutral', era = 'modern', audience = 'adult', media_type = 'audiobook', honorific = 'mix',
    brief = 'Literary prose with a flow built for listening: preserve imagery, rhythm and narrative voice. Give dialogue lines a distinctly spoken register against the narration.',
  },
  audiobook_nonfiction = {
    label = 'Audiobook — non-fiction',
    tone = 'neutral', era = 'modern', audience = 'adult', media_type = 'audiobook', honorific = 'formal',
    brief = 'Clear expository prose that stays listenable: keep the argument structure and emphasis intact, terminology precise and consistent, sentences shorter than print would allow.',
  },
  game = {
    label = 'Video game',
    tone = 'informal', era = 'modern', audience = 'teen', media_type = 'game', honorific = 'mix',
    brief = 'Short, punchy lines that survive fast gameplay — barks and callouts must be instantly readable by ear. Keep character voice, world terminology and item names rigorously consistent.',
  },
  -- LEGACY (projekty sprzed 2026-06-10): resolve'uje stary klucz, nie jest
  -- w STYLE_PRESET_ORDER → niewidoczny w UI dla nowych wyborów.
  podcast_scifi = {
    label = 'Sci-fi podcast (legacy)',
    tone = 'conversational', era = 'modern', audience = 'adult', media_type = 'podcast', honorific = 'mix',
  },
}

-- Kolejność prezentacji w UI. Konsumenci: dubbing_context (Translation
-- context), dubbing_panel (Start + Edit modale), settings_dialog (default).
M.STYLE_PRESET_ORDER = {
  'drama_modern', 'drama_period', 'comedy', 'thriller_horror', 'kids',
  'documentary', 'podcast_interview', 'news_report', 'corporate',
  'commercial', 'audiobook_fiction', 'audiobook_nonfiction', 'game',
}

-- Czy txt to brief któregoś presetu (lub pusty)? Gate bezpiecznego nadpisania
-- free_text przy zmianie presetu — tekst user-authored NIE znika bez pytania.
function M.is_stock_style_text(txt)
  if not txt or txt == '' then return true end
  for _, p in pairs(M.STYLE_PRESETS) do
    if p.brief == txt then return true end
  end
  return false
end

----------------------------------------------------------------------------
-- Init helper: per-language map z default value.
----------------------------------------------------------------------------
local function init_lang_map(target_languages, default_value)
  local out = {}
  for _, lang in ipairs(target_languages) do
    out[lang] = default_value
  end
  return out
end

local function clone_voice_settings()
  return {
    stability        = M.DEFAULT_VOICE_SETTINGS.stability,
    similarity_boost = M.DEFAULT_VOICE_SETTINGS.similarity_boost,
    style            = M.DEFAULT_VOICE_SETTINGS.style,
    speed            = M.DEFAULT_VOICE_SETTINGS.speed,
    speaker_boost    = M.DEFAULT_VOICE_SETTINGS.speaker_boost,
  }
end

----------------------------------------------------------------------------
-- new_project(opts) → project, err
--
-- opts: {
--   source_kind        = 'mixed_single' | 'multi_track'
--   source_item_guid   (mixed_single)
--   source_track_guids[] (multi_track)
--   source_language    = 'en' (auto-detect lub user-set)
--   target_languages   = {'pl', 'es'} REQUIRED — at least 1
--   tts_model          (default = cfg.get_dubbing_default_tts_model())
--   style_preset       (default 'drama_modern')
--   voice_isolator_enabled = false
-- }
----------------------------------------------------------------------------
function M.new_project(opts)
  opts = opts or {}
  local target_langs = opts.target_languages
  if type(target_langs) ~= 'table' or #target_langs == 0 then
    return nil, 'target_languages required (at least 1 language)'
  end

  local style_key = opts.style_preset or 'drama_modern'
  local style_ctx = M.STYLE_PRESETS[style_key]
  -- T10c (user-caught): własny styl usera ('saved:<Name>' — snapshot
  -- kontekstu z ExtState) honorowany już przy TWORZENIU projektu; projekt
  -- rodzi się z pełnym kontekstem usera. Brak/wykasowany styl → default.
  if not style_ctx then
    local saved_name = style_key:match('^saved:(.+)$')
    local st = saved_name and cfg.get_custom_styles('dubbing')[saved_name]
    if st then
      style_ctx = {
        tone       = st.tone,
        era        = st.era,
        audience   = st.audience,
        media_type = st.media_type,
        honorific  = st.honorific,
        brief      = st.free_text or '',
      }
    end
  end
  style_ctx = style_ctx or M.STYLE_PRESETS.drama_modern

  return {
    version                = M.VERSION,
    project_guid           = dubbing_state.generate_project_guid(),
    source_kind            = opts.source_kind or 'mixed_single',
    source_item_guid       = opts.source_item_guid,
    source_track_guids     = opts.source_track_guids or {},
    source_language        = opts.source_language or 'en',
    target_languages       = target_langs,
    active_target_language = target_langs[1],
    tts_model              = opts.tts_model or cfg.get_dubbing_default_tts_model(),
    voice_isolator_enabled = opts.voice_isolator_enabled == true,
    style_preset           = style_key,
    -- Wersja szablonu promptu tłumaczenia w momencie utworzenia projektu.
    -- Restore (modes/dubbing.try_restore) porównuje z llm.PROMPT_VERSION —
    -- mismatch = jednorazowe mark_all_translations_stale (świadomy koszt).
    translate_prompt_version = require('modules.llm').PROMPT_VERSION,
    context = {
      tone       = style_ctx.tone,
      era        = style_ctx.era,
      audience   = style_ctx.audience,
      media_type = style_ctx.media_type,
      honorific  = style_ctx.honorific,
      free_text  = style_ctx.brief or '',
    },
    speakers = {},
    segments = {},
    glossary = {
      characters       = {},
      terms            = {},
      do_not_translate = {},
    },
    cost_tracker = {
      stt_minutes_used          = 0,
      llm_tokens_used_input     = 0,
      llm_tokens_used_output    = 0,
      tts_chars_used            = 0,
      forced_align_minutes_used = 0,
      estimated_total_usd       = 0,
      -- M2.4 cache visibility — counters never billed (instant returns):
      translate_cache_hits      = 0,
      translate_fresh           = 0,
      tts_cache_hits            = 0,
    },
    created_at_unix = os.time(),
  }, nil
end

----------------------------------------------------------------------------
-- Speakers
----------------------------------------------------------------------------
local function next_spk_id(project)
  local n = #project.speakers + 1
  return string.format('spk_%03d', n)
end

function M.add_speaker(project, label, opts)
  opts = opts or {}
  local spk = {
    id                = next_spk_id(project),
    label             = label or ('Speaker_' .. (#project.speakers + 1)),
    -- voice_path USUNIĘTE M4-10 (2026-07-11, user OK) — pisane, nigdy nie
    -- czytane; stare persisted JSON-y mogą je nieść (ignorowane).
    voices            = init_lang_map(project.target_languages, nil),
    voice_names       = init_lang_map(project.target_languages, nil),
    voice_settings_per_lang = {},
    track_guids       = init_lang_map(project.target_languages, nil),
    sample_audio_path = opts.sample_audio_path,
    sample_time_range = opts.sample_time_range,
    -- NS-G: Scribe diarize local_ids (mapping persistence dla speaker_picker).
    -- Populated przez speaker_match.build_segments_and_speakers po user
    -- assignment "speaker_0 → Host". Empty dla pre-NS-G projects.
    local_ids         = opts.local_ids or {},
  }
  for _, lang in ipairs(project.target_languages) do
    spk.voice_settings_per_lang[lang] = clone_voice_settings()
  end
  project.speakers[#project.speakers + 1] = spk
  return spk
end

function M.find_speaker(project, speaker_id)
  for _, s in ipairs(project.speakers) do
    if s.id == speaker_id then return s end
  end
  return nil
end

-- remove_speaker USUNIĘTE M4-10 (2026-07-11, user OK) — zero callerów;
-- git history zachowuje. Wróci, gdy UI dostanie akcję usuwania mówcy.

----------------------------------------------------------------------------
-- Segments
----------------------------------------------------------------------------
local function next_seg_id(project)
  local n = #project.segments + 1
  return string.format('seg_%04d', n)
end

function M.add_segment(project, speaker_id, t_start, t_end, source_text, source_words)
  local seg = {
    id           = next_seg_id(project),
    speaker_id   = speaker_id,
    t_start      = t_start or 0,
    t_end        = t_end or 0,
    source_text  = source_text or '',
    -- M3.6: per-word source timing preserved dla per-word splice mode.
    -- Array of { text, start, end } w project-absolute seconds.
    source_words = source_words or {},
    translations         = init_lang_map(project.target_languages, ''),
    translation_status   = init_lang_map(project.target_languages, 'pending'),
    voice_id_overrides   = init_lang_map(project.target_languages, nil),
    voice_settings_overrides = init_lang_map(project.target_languages, nil),
    dub_status           = init_lang_map(project.target_languages, 'pending'),
    dub_audio_paths      = init_lang_map(project.target_languages, nil),
    dub_alignment        = init_lang_map(project.target_languages, nil),
    item_guids           = init_lang_map(project.target_languages, nil),
    -- M4+ per-word splice indicator: number of REAPER items created per segment.
    -- = 1 dla full-segment splice (default); > 1 dla legacy per-word splice
    -- (pre-stretch-markers rewrite, deprecated). Current per-word produces 1
    -- item z stretch markers — flag dub_per_word[lang] dedykowany dla mode display.
    dub_n_items          = init_lang_map(project.target_languages, 0),
    dub_per_word         = init_lang_map(project.target_languages, false),
    -- M4+ visibility: gdy per-word splice attempted ale fallback do full-segment,
    -- stored reason ('word_count_mismatch', 'missing_data: ...', etc.).
    -- '' = per-word succeeded OR not attempted. Wyświetlane w Inspector.
    dub_per_word_fallback_reason = init_lang_map(project.target_languages, ''),
    -- M4+ fix #27: applied stretch ratio (item_len / audio_len). Stored po splice
    -- żeby NEXT segment mógł smooth-transition do swojego ratio (avoid tempo jump
    -- between adjacent items). Per-lang.
    dub_applied_ratio   = init_lang_map(project.target_languages, nil),
    needs_redub          = false,
    director_note        = '',
    -- Auto-exclude short interjections from dub pipeline ("Yeah", "Tak", "OK",
    -- "Yes", "Mhm"). Threshold: word_count <= INTERJECTION_MAX_WORDS (default 2).
    -- User can manually include via [+] button or exclude via right-click.
    -- nil/false = active, true = skipped przez translate + generate_dub pumps.
    dub_excluded         = false,
  }
  -- Auto-mark short interjections excluded by default
  do
    local INTERJECTION_MAX_WORDS = 2
    local wc = 0
    for _ in (source_text or ''):gmatch('%S+') do wc = wc + 1 end
    if wc > 0 and wc <= INTERJECTION_MAX_WORDS then
      seg.dub_excluded = true
    end
  end
  project.segments[#project.segments + 1] = seg
  return seg
end

function M.find_segment(project, seg_id)
  for _, s in ipairs(project.segments) do
    if s.id == seg_id then return s end
  end
  return nil
end

----------------------------------------------------------------------------
-- M4-1 (audit 2026-07): regiony do próbki IVC z segmentów JEDNEGO speakera
-- (pre-fix: klon trenował się na całym zmiksowanym itemie = wszyscy mówcy
-- w próbce). Chronologicznie, merge przyległych segmentów (gap ≤ merge_gap),
-- łączny czas przycięty do max_secs (IVC/concat cap).
-- UWAGA OSIE CZASU (hotfix 2026-07-11 — 2 klony wytrenowane na ciszy):
-- regiony wychodzą w TEJ SAMEJ osi co seg.t_start/t_end = czas PROJEKTU
-- (project_offset dodawany przy build segmentów). Konsument MUSI
-- przekonwertować na czas pliku źródłowego przed concat_regions
-- (S = P + D_STARTOFFS - D_POSITION) + clamp do okna itemu — patrz
-- dubbing_panel path_clone. Pure — headless-tested.
----------------------------------------------------------------------------
function M.speaker_sample_regions(project, speaker_id, opts)
  opts = opts or {}
  local max_secs  = tonumber(opts.max_secs) or 240   -- audio_concat.MAX_DURATION_SECS
  local merge_gap = tonumber(opts.merge_gap) or 0.75
  local merged = {}
  for _, seg in ipairs((project and project.segments) or {}) do
    if seg.speaker_id == speaker_id and not seg.dub_excluded then
      local s = tonumber(seg.t_start) or 0
      local e = tonumber(seg.t_end) or 0
      if e > s then
        local last = merged[#merged]
        if last and s >= last.start and (s - last['end']) <= merge_gap then
          if e > last['end'] then last['end'] = e end
        else
          merged[#merged + 1] = { start = s, ['end'] = e }
        end
      end
    end
  end
  local out, total = {}, 0
  for _, r in ipairs(merged) do
    local dur = r['end'] - r.start
    if total + dur >= max_secs then
      local room = max_secs - total
      if room > 0.25 then
        out[#out + 1] = { start = r.start, ['end'] = r.start + room }
      end
      break
    end
    out[#out + 1] = r
    total = total + dur
  end
  return out
end

----------------------------------------------------------------------------
-- Stale flag propagation (per spec §10.3).
-- Called when context/glossary/style edit mutates → translations stale.
----------------------------------------------------------------------------
function M.mark_all_translations_stale(project, lang)
  for _, seg in ipairs(project.segments) do
    if seg.translation_status[lang] == 'translated' then
      seg.translation_status[lang] = 'stale'
    end
  end
end

function M.mark_all_dub_stale(project, lang)
  for _, seg in ipairs(project.segments) do
    if seg.dub_status[lang] == 'generated' then
      seg.dub_status[lang] = 'stale'
    end
  end
end

----------------------------------------------------------------------------
-- Add/remove target language (Correction 2 — multi-lang manipulation).
-- When adding new lang, wszystkie speakers + segments dostają new per-lang entries.
--
-- W2 M3 cz.2 (user decision 2026-07-11 nocna: "kopiuj cicho + status"):
-- nowy język DZIEDZICZY cast. Głosy ElevenLabs (library + IVC) są
-- multilingual — seed przypisań + voice_settings per speaker ze
-- skonfigurowanego języka zamiast pustych pól (pola nowego języka są
-- puste, więc niczego nie nadpisujemy; hybrid per-row zostaje — user może
-- nadpisać głos per język). Źródło: aktywny język jeśli ma głosy, inaczej
-- pierwszy target z głosami. Zwraca (true, nil, info|nil), gdzie info =
-- { inherited_from, count } — panel pokazuje status.
----------------------------------------------------------------------------
local function lang_has_voices(project, lang)
  for _, s in ipairs(project.speakers) do
    local v = s.voices and s.voices[lang]
    if v and v ~= '' then return true end
  end
  return false
end

function M.add_target_language(project, lang)
  for _, l in ipairs(project.target_languages) do
    if l == lang then return false, 'language already added' end
  end
  project.target_languages[#project.target_languages + 1] = lang

  local src_lang
  if project.active_target_language and project.active_target_language ~= lang
     and lang_has_voices(project, project.active_target_language) then
    src_lang = project.active_target_language
  else
    for _, l in ipairs(project.target_languages) do
      if l ~= lang and lang_has_voices(project, l) then
        src_lang = l
        break
      end
    end
  end

  local inherited = 0
  for _, s in ipairs(project.speakers) do
    local src_v = src_lang and s.voices and s.voices[src_lang]
    if src_v and src_v ~= '' then
      s.voices[lang]      = src_v
      s.voice_names[lang] = (s.voice_names and s.voice_names[src_lang]) or nil
      inherited = inherited + 1
    else
      if s.voices      then s.voices[lang]      = nil end
      if s.voice_names then s.voice_names[lang] = nil end
    end
    if s.track_guids then s.track_guids[lang] = nil end
    if s.voice_settings_per_lang then
      local src_vs = src_lang and s.voice_settings_per_lang[src_lang]
      if src_vs then
        local copy = {}
        for k, v in pairs(src_vs) do copy[k] = v end
        s.voice_settings_per_lang[lang] = copy
      else
        s.voice_settings_per_lang[lang] = clone_voice_settings()
      end
    end
  end
  for _, seg in ipairs(project.segments) do
    seg.translations[lang]             = ''
    seg.translation_status[lang]       = 'pending'
    seg.voice_id_overrides[lang]       = nil
    seg.voice_settings_overrides[lang] = nil
    seg.dub_status[lang]               = 'pending'
    seg.dub_audio_paths[lang]          = nil
    seg.dub_alignment[lang]            = nil
    seg.item_guids[lang]               = nil
    -- M4-9: komplet pól per-lang jak w add_segment (pre-fix ratował
    -- lazy-init u konsumentów; spójny init = mniej niespodzianek).
    if type(seg.dub_n_items) == 'table'  then seg.dub_n_items[lang]  = 0 end
    if type(seg.dub_per_word) == 'table' then seg.dub_per_word[lang] = false end
    if type(seg.dub_per_word_fallback_reason) == 'table' then
      seg.dub_per_word_fallback_reason[lang] = ''
    end
    if type(seg.dub_applied_ratio) == 'table' then
      seg.dub_applied_ratio[lang] = nil
    end
  end
  return true, nil,
    (inherited > 0) and { inherited_from = src_lang, count = inherited } or nil
end

function M.remove_target_language(project, lang)
  local found_idx = nil
  for i, l in ipairs(project.target_languages) do
    if l == lang then found_idx = i; break end
  end
  if not found_idx then return false, 'language not in project' end
  if #project.target_languages == 1 then
    return false, 'cannot remove last language'
  end
  table.remove(project.target_languages, found_idx)
  if project.active_target_language == lang then
    project.active_target_language = project.target_languages[1]
  end
  for _, s in ipairs(project.speakers) do
    if s.voices                  then s.voices[lang]                  = nil end
    if s.voice_names             then s.voice_names[lang]             = nil end
    if s.voice_settings_per_lang then s.voice_settings_per_lang[lang] = nil end
    if s.track_guids             then s.track_guids[lang]             = nil end
  end
  for _, seg in ipairs(project.segments) do
    seg.translations[lang]             = nil
    seg.translation_status[lang]       = nil
    seg.voice_id_overrides[lang]       = nil
    seg.voice_settings_overrides[lang] = nil
    seg.dub_status[lang]               = nil
    seg.dub_audio_paths[lang]          = nil
    seg.dub_alignment[lang]            = nil
    seg.item_guids[lang]               = nil
  end
  return true
end

----------------------------------------------------------------------------
-- Context/glossary hashing for translation cache key (per spec §11.5).
-- Different context → different cache → fresh translation.
----------------------------------------------------------------------------
function M.context_hash(project)
  if not project or not project.context then return '0' end
  local c = project.context
  local input = string.format(
    '%s|%s|%s|%s|%s|%s',
    c.tone or '', c.era or '', c.audience or '',
    c.media_type or '', c.honorific or '', c.free_text or '')
  return string.format('%08x', util.simple_hash(input))
end

function M.glossary_hash(project)
  if not project or not project.glossary then return '0' end
  local parts = {}
  local g = project.glossary
  if type(g.characters) == 'table' then
    for _, c in ipairs(g.characters) do
      parts[#parts + 1] = (c.name or '') .. '|'
                       .. (c.speaking_style or '') .. '|'
                       .. tostring(c.preserve_name or false)
    end
  end
  if type(g.terms) == 'table' then
    for _, t in ipairs(g.terms) do
      parts[#parts + 1] = (t.source or '') .. '->'
                       .. (t.target or '') .. '|'
                       .. (t.consistency or '')
    end
  end
  if type(g.do_not_translate) == 'table' then
    for _, w in ipairs(g.do_not_translate) do
      parts[#parts + 1] = '!' .. w
    end
  end
  return string.format('%08x', util.simple_hash(table.concat(parts, ';;')))
end

----------------------------------------------------------------------------
-- Track label builder per Correction 2: [Dub <LANG_UPPER>: <speaker_label>]
-- np. "[Dub PL: Anna]". Uniform pattern dla wszystkich target_languages.
----------------------------------------------------------------------------
function M.track_label(speaker_label, lang)
  return string.format('[Dub %s: %s]', (lang or ''):upper(), speaker_label or '?')
end

return M
