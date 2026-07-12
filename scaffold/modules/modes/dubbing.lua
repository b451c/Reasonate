-- modules/modes/dubbing.lua
-- NS-B Dubbing: mode dispatch + state machine + pipeline orchestration.
--
-- Phase flow (per spec §10.2):
--   idle → starting → (isolating?) → chunking → transcribing → matching_speakers
--        → casting_voices → ready
-- Within 'ready' phase, Translate-all + Generate-dub batches run independently
-- z per-segment retry-on-429 / cost tracking.
--
-- Niezmienniki:
--   #2 source nigdy modyfikowany audio — chunker decode read-only, splicer
--      tworzy nowe items na osobnych [Dub LANG: speaker] tracks
--   #3 main thread only — ExecProcess fire-and-forget z poll w defer loop
--   #4 Undo block — splice_segment wraps each successful generation w Undo

local dubbing_state    = require 'modules.dubbing_state'
local dubbing_project  = require 'modules.dubbing_project'
local cfg              = require 'modules.config'
local util             = require 'modules.util'
local async_op         = require 'modules.async_op'

local M = {}

M.NAME        = 'dubbing'
M.LABEL       = 'Dubbing'
M.DESCRIPTION = 'Translation + TTS in target language'
M.DISABLED    = false

-- Pipeline tunables
local STT_CONCURRENCY      = 3      -- max concurrent diarize requests per spec §10.2
local TRANSLATE_CONCURRENCY= 3      -- conservative; Anthropic Tier 1 = 50 RPM
local DUB_CONCURRENCY      = 3      -- per voice TTS concurrency
-- Retry/stale constants: wspólne źródło prawdy w modules/async_op.lua
-- (audit M2-2, 2026-06-10 — wcześniej lokalne kopie rozjeżdżały się per-mode;
-- stale timeout 300 → 330 = max curl --max-time we wszystkich workers + grace).
-- Lokalne aliasy zachowują nazwy w call sites (surgical migration).
local MAX_429_RETRIES      = async_op.MAX_RETRIES
local RETRY_BACKOFF_SECS   = async_op.RETRY_BACKOFF

----------------------------------------------------------------------------
-- Per-mode state init (idempotent — called z każdego entry point).
----------------------------------------------------------------------------
local function init_state(state)
  if not state.modes then state.modes = {} end
  local d = state.modes.dubbing
  if not d then
    d = {}
    state.modes.dubbing = d
  end

  -- Persistent project
  if d.project == nil then d.project = nil end

  -- UI phase
  if d.phase == nil then d.phase = 'idle' end

  -- Modal toggles (pending_open pattern)
  if d.start_modal_pending_open         == nil then d.start_modal_pending_open         = false end
  if d.speaker_match_modal_pending_open == nil then d.speaker_match_modal_pending_open = false end
  if d.glossary_modal_pending_open      == nil then d.glossary_modal_pending_open      = false end

  -- Voice picker callback (for Cast sidebar "Clone from selection" path)
  if d.pending_voice_picker_for_speaker == nil then d.pending_voice_picker_for_speaker = nil end

  -- Per-segment async handles. Each value: { handle, retries=0, last_attempt_at=nil }
  if d.translate_handles == nil then d.translate_handles = {} end
  if d.tts_handles       == nil then d.tts_handles       = {} end
  if d.align_handles     == nil then d.align_handles     = {} end

  -- Per-speaker IVC handles
  if d.clone_handles     == nil then d.clone_handles     = {} end

  -- W2 M3 cz.2: propozycje "Match cast" (Cast Registry → mówcy dubbingu).
  -- Odświeżane throttle 2s w consume_signals; nil = brak propozycji.
  if d.match_cast_rows       == nil then d.match_cast_rows       = nil end
  if d.match_cast_checked_at == nil then d.match_cast_checked_at = nil end

  -- T2 (UX-POLISH): preview tłumaczenia segmentu (jeden naraz; handle z
  -- h.seg_id — ten sam request co Generate, patrz build_dub_tts_opts).
  if d.preview_handle        == nil then d.preview_handle        = nil end

  -- M4-3: sekwencyjna kolejka kasowania klonów (modal przy Close/Delete).
  -- Przeżywa close_project — deletes lecą w tle po zamknięciu projektu.
  if d.clone_delete_queue  == nil then d.clone_delete_queue  = {} end
  if d.clone_delete_handle == nil then d.clone_delete_handle = nil end

  -- M3.2: per-speaker similar-voices handles + results
  if d.similar_handles   == nil then d.similar_handles   = {} end
  if d.similar_results   == nil then d.similar_results   = {} end   -- {spk_id → {voices[], has_more, total_count, audio_path, top_k}}
  if d.similar_modal_pending_speaker == nil then d.similar_modal_pending_speaker = nil end
  -- M4.3: load_more handles — re-spawn similar_voices z larger top_k, append do existing modal results
  if d.similar_more_handles == nil then d.similar_more_handles = {} end   -- {spk_id → handle}

  -- M3.3+M3.4: per-segment inspector + regen / variants tracking
  if d.inspector_pending_seg_id == nil then d.inspector_pending_seg_id = nil end
  if d.regen_state == nil then d.regen_state = {} end   -- {seg_id → {target_remaining=N, handles_in_flight={}}}

  -- STT chunks (mixed_single Flow A)
  if d.chunk_handles     == nil then d.chunk_handles     = {} end

  -- Pipeline staging
  if d.chunks_plan       == nil then d.chunks_plan       = nil end   -- chunker.plan_chunks result
  if d.chunks_results    == nil then d.chunks_results    = {} end    -- chunk_idx → transcript table
  if d.isolator_handle   == nil then d.isolator_handle   = nil end   -- voice_isolator.spawn_isolate handle
  if d.isolated_audio_path == nil then d.isolated_audio_path = nil end

  -- Multi-track Flow B (M2.2): per-item STT no-diarize, track name = speaker
  if d.flow_b_items_pending == nil then d.flow_b_items_pending = {} end  -- {item_guid → {item, speaker_id, t_start, duration}}
  if d.flow_b_item_handles  == nil then d.flow_b_item_handles  = {} end  -- {item_guid → stt handle}
  if d.flow_b_item_results  == nil then d.flow_b_item_results  = {} end  -- {item_guid → transcript or {error}}

  -- Request queues (user clicks → consume_signals processes)
  if d.translate_pending == nil then d.translate_pending = false end
  if d.generate_pending  == nil then d.generate_pending  = false end

  -- 429 backoff state — per-handle scheduled retry timestamps
  if d.retry_at == nil then d.retry_at = {} end

  -- REAPER selection sync — M4.2 multi-segment set (table: seg_id → true).
  -- Backward compat: single `selected_segment_id` still mirrored = first key.
  if d.selected_segment_ids == nil then d.selected_segment_ids = {} end
  if d.selected_segment_id  == nil then d.selected_segment_id  = nil end
  if d.selected_speaker_id  == nil then d.selected_speaker_id  = nil end

  -- W3 Pakiet B+ (2026-06-10, user request): playhead → transcript sync.
  -- playhead_segment_id = segment pod kursorem/odtwarzaniem (tint w tabeli);
  -- playhead_scroll_pending = one-shot scroll przy ZMIANIE segmentu;
  -- last_playhead_t = epsilon-debounce odczytu pozycji.
  if d.playhead_segment_id     == nil then d.playhead_segment_id     = nil end
  if d.playhead_scroll_pending == nil then d.playhead_scroll_pending = nil end
  if d.last_playhead_t         == nil then d.last_playhead_t         = nil end

  -- W3 (tabela): filtr statusów tabeli segmentów (chip bucket lub nil = All).
  if d.segment_filter          == nil then d.segment_filter          = nil end

  -- Status toast
  if d.status_msg   == nil then d.status_msg   = '' end

  -- Sticky error (survives status_msg overwrite) — cleared on retry / new run.
  if d.last_run_error == nil then d.last_run_error = nil end

  -- One-time restore flag
  if d.restored == nil then d.restored = false end

  return d
end

----------------------------------------------------------------------------
-- Status toast helper (defined high — used z multiple sections)
----------------------------------------------------------------------------
local function set_status(s, msg, color)
  s.status_msg = msg or ''
  s.status_color = color
end

----------------------------------------------------------------------------
-- Stale handle detection — przeniesione do modules/async_op.lua (audit
-- M2-2, 2026-06-10): ten sam helper chroni teraz też job_manager/tts/repair
-- (wcześniej TYLKO dubbing miał stale detection). Alias zachowuje call sites.
----------------------------------------------------------------------------
local force_error_if_stale = async_op.force_error_if_stale

----------------------------------------------------------------------------
-- Mark dirty wrapper (always called via mode_module.mark_dirty)
----------------------------------------------------------------------------
local function mark_dirty(s)
  if s.project then dubbing_state.mark_dirty(s.project) end
end

----------------------------------------------------------------------------
-- Try restore project from dubbing_state on first mode entry / first frame.
----------------------------------------------------------------------------
local function try_restore(s)
  if s.restored then return end
  s.restored = true
  local project = dubbing_state.load()
  if project then
    s.project = project
    s.phase   = 'ready'
    -- Szablon promptu tłumaczenia zmienił się od ostatniego otwarcia projektu?
    -- Stored translations pochodzą ze starego szablonu — jednorazowo stale
    -- (PROMPT_VERSION jest też w cache key, więc plikowy cache nie odda
    -- starych wyników). Bez tego "Translate all" PRESERWUJE translated
    -- i nowy prompt nigdy nie dotyka istniejących projektów (live 2026-06-10).
    local llm = require 'modules.llm'
    if (project.translate_prompt_version or 0) ~= llm.PROMPT_VERSION then
      for _, lang in ipairs(project.target_languages or {}) do
        dubbing_project.mark_all_translations_stale(project, lang)
      end
      project.translate_prompt_version = llm.PROMPT_VERSION
      dubbing_state.mark_dirty(project)
      set_status(s, 'Translation prompt updated — existing translations marked stale. Press Translate all to refresh them.', 0xFFB060FF)
    end
  end
end

----------------------------------------------------------------------------
-- Cost increments (per spec §12). Atomic — call from poll-done branches.
----------------------------------------------------------------------------
local function cost_add_stt(project, minutes)
  if not project or not project.cost_tracker then return end
  project.cost_tracker.stt_minutes_used = (project.cost_tracker.stt_minutes_used or 0) + (minutes or 0)
  -- Scribe: $0.22/h audio (oficjalny cennik elevenlabs.io/pricing/api,
  -- verified 2026-06-11; stary audyt mylił h z min → zawyżenie ×109).
  project.cost_tracker.estimated_total_usd = (project.cost_tracker.estimated_total_usd or 0) + (minutes or 0) * (0.22 / 60)
end

local function cost_add_llm(project, input_tokens, output_tokens, provider)
  if not project or not project.cost_tracker then return end
  project.cost_tracker.llm_tokens_used_input = (project.cost_tracker.llm_tokens_used_input or 0) + (input_tokens or 0)
  project.cost_tracker.llm_tokens_used_output = (project.cost_tracker.llm_tokens_used_output or 0) + (output_tokens or 0)
  -- Conservative per-provider $/M tokens (input+output combined avg) — refine M2.
  local cost_per_M = 2.0   -- default; per provider override below
  if provider == 'anthropic'  then cost_per_M = 4.5 end
  if provider == 'openai'     then cost_per_M = 2.5 end
  if provider == 'gemini'     then cost_per_M = 0.8 end
  if provider == 'deepseek'   then cost_per_M = 0.2 end
  if provider == 'grok'       then cost_per_M = 1.9 end   -- W2 s6: $1.25/$2.50
  if provider == 'mistral'    then cost_per_M = 1.2 end   -- W2 s6: $0.40/$2 (medium)
  local tok = (input_tokens or 0) + (output_tokens or 0)
  project.cost_tracker.estimated_total_usd = (project.cost_tracker.estimated_total_usd or 0) + (tok / 1e6) * cost_per_M
end

local function cost_add_tts(project, chars, model)
  if not project or not project.cost_tracker then return end
  project.cost_tracker.tts_chars_used = (project.cost_tracker.tts_chars_used or 0) + (chars or 0)
  -- ElevenLabs Creator tier: ~$22/100k credits, 1 cred/char default, Flash 0.5×.
  -- Approximate $0.00022/char (Multilingual v2), $0.00011/char (Flash).
  local rate = 0.00022
  if model == 'eleven_flash_v2_5' then rate = 0.00011 end
  project.cost_tracker.estimated_total_usd = (project.cost_tracker.estimated_total_usd or 0) + (chars or 0) * rate
end

local function cost_add_forced_align(project, minutes)
  if not project or not project.cost_tracker then return end
  project.cost_tracker.forced_align_minutes_used = (project.cost_tracker.forced_align_minutes_used or 0) + (minutes or 0)
  -- Forced alignment: "Same rate as the Speech to Text API" = $0.22/h
  -- (docs overview/capabilities/forced-alignment, verified 2026-06-11;
  -- stary szacunek $0.30/min był ~80× zawyżony).
  project.cost_tracker.estimated_total_usd = (project.cost_tracker.estimated_total_usd or 0) + (minutes or 0) * (0.22 / 60)
end

----------------------------------------------------------------------------
-- Source audio path resolver (mixed_single → item active take source path).
-- Returns (path, item) lub (nil, err).
----------------------------------------------------------------------------
local function resolve_source_path_for_mixed(project)
  if not project or not project.source_item_guid then
    return nil, 'no source_item_guid'
  end
  local count = reaper.CountMediaItems(0)
  for i = 0, count - 1 do
    local it = reaper.GetMediaItem(0, i)
    local _, g = reaper.GetSetMediaItemInfo_String(it, 'GUID', '', false)
    if g == project.source_item_guid then
      local take = reaper.GetActiveTake(it)
      if not take then return nil, 'item has no take', it end
      local src = reaper.GetMediaItemTake_Source(take)
      if not src then return nil, 'take has no source', it end
      -- Walk up source parents (section/reverse wrappers) — shared helper (M2-2)
      src = require('modules.reaper_helpers').resolve_root_source(src)
      local p = reaper.GetMediaSourceFileName(src, '')
      if not p or p == '' then return nil, 'source has no file path', it end
      return p, it
    end
  end
  return nil, 'source item not found in current project'
end

----------------------------------------------------------------------------
-- Phase transition: starting → isolating? → chunking
-- Triggered z M.start_project AND z consume_signals na phase=='starting'.
----------------------------------------------------------------------------
local function find_track_by_guid(track_guid)
  if not track_guid or track_guid == '' then return nil end
  local count = reaper.CountTracks(0)
  for i = 0, count - 1 do
    local tr = reaper.GetTrack(0, i)
    if tr then
      local _, g = reaper.GetSetMediaTrackInfo_String(tr, 'GUID', '', false)
      if g == track_guid then return tr end
    end
  end
  return nil
end

local function find_item_by_guid(item_guid)
  if not item_guid or item_guid == '' then return nil end
  local count = reaper.CountMediaItems(0)
  for i = 0, count - 1 do
    local it = reaper.GetMediaItem(0, i)
    if it then
      local _, g = reaper.GetSetMediaItemInfo_String(it, 'GUID', '', false)
      if g == item_guid then return it end
    end
  end
  return nil
end

----------------------------------------------------------------------------
-- W2 M3 cz.2: kanoniczny klucz materiału źródłowego (mixed_single) dla Cast
-- Registry — parity z Repair (cast_registry.geometry_key, BEZ języka).
-- Multi-track (Flow B) nie ma jednego materiału → nil (Match cast off).
----------------------------------------------------------------------------
local function source_geom_key(s)
  local p = s.project
  if not p or p.source_kind ~= 'mixed_single' then return nil end
  local item = p.source_item_guid and find_item_by_guid(p.source_item_guid)
  if not item then return nil end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  src = require('modules.reaper_helpers').resolve_root_source(src)
  local path = reaper.GetMediaSourceFileName(src, '')
  if not path or path == '' then return nil end
  return require('modules.cast_registry').geometry_key(
    path,
    reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0,
    reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0,
    reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1)
end

----------------------------------------------------------------------------
-- W2 M3 cz.2: propozycje "Match cast" — postaci z Cast Registry → mówcy
-- dubbingu po foldzie labelu; postaci zlinkowane z materiałem źródłowym
-- wygrywają z resztą rejestru. Kandydat głosu: voices[active lang] → klon
-- IVC osoby → pick_voice. Throttle 2s (odczyt pliku rejestru per refresh);
-- s.match_cast_checked_at=nil wymusza natychmiastowy refresh (apply).
----------------------------------------------------------------------------
local function refresh_match_cast(s)
  local now = reaper.time_precise()
  if s.match_cast_checked_at and now - s.match_cast_checked_at < 2.0 then return end
  s.match_cast_checked_at = now
  s.match_cast_rows = nil
  local p = s.project
  local lang = p and p.active_target_language
  if not lang or not p.speakers or #p.speakers == 0 then return end
  local cast_registry = require 'modules.cast_registry'
  local ok, rows = pcall(function()
    local reg = cast_registry.load()
    if not reg or cast_registry.is_empty(reg) then return nil end
    local gk = source_geom_key(s)
    local by_label = {}
    for _, ch in ipairs(cast_registry.characters(reg)) do
      local key = cast_registry.normalize_label(ch.label)
      if key ~= '' then
        local linked = gk ~= nil and cast_registry.is_material_linked(ch, gk)
        local cur = by_label[key]
        if not cur or (linked and not cur.linked) then
          by_label[key] = { ch = ch, linked = linked }
        end
      end
    end
    local out = {}
    for _, spk in ipairs(p.speakers) do
      local hit = by_label[cast_registry.normalize_label(spk.label or '')]
      if hit then
        local ch = hit.ch
        local lv = ch.voices and ch.voices[lang]
        local vid   = lv and lv.voice_id
        local vname = lv and lv.voice_name
        if not vid or vid == '' then
          if type(ch.ivc_clone_id) == 'string' and ch.ivc_clone_id ~= '' then
            vid = ch.ivc_clone_id
            local dv = ch.voices and ch.voices.default
            vname = (dv and dv.voice_id == vid and dv.voice_name ~= ''
                     and dv.voice_name)
                 or ((ch.label or '?') .. ' (clone)')
          else
            vid, vname = cast_registry.pick_voice(ch, lang)
          end
        end
        local cur_vid = spk.voices and spk.voices[lang]
        if vid and vid ~= '' and vid ~= cur_vid then
          out[#out + 1] = {
            speaker_id     = spk.id,
            speaker_label  = spk.label or spk.id,
            cur_voice_id   = cur_vid,
            cur_voice_name = (spk.voice_names and spk.voice_names[lang]) or nil,
            voice_id       = vid,
            voice_name     = vname or ch.label or '?',
            from_char      = ch.label or '?',
            from_linked    = hit.linked or false,
            conflict       = (cur_vid ~= nil and cur_vid ~= ''),
          }
        end
      end
    end
    if #out == 0 then return nil end
    return out
  end)
  if ok then s.match_cast_rows = rows end
end

----------------------------------------------------------------------------
-- M2.3 + M4 Stale flag propagation (per spec §10.3 cascade).
--
-- kind:
--   'all'      → translations + dubs stale (context/glossary/style/source edit)
--   'dub_only' → only dubs + REAPER items stale (voice change / voice settings)
--
-- scope: 'all_langs' (default) lub specific lang string.
--
-- Voice-related changes (voice_id, voice_settings) NIE invalidate translation
-- text — LLM nie widzi voice settings. Only synthesized audio re-gen needed.
----------------------------------------------------------------------------
local function propagate_stale(project, scope, kind)
  if not project then return end
  kind = kind or 'all'   -- backward-compat default
  local dub_project = require 'modules.dubbing_project'
  local dub_splicer = require 'modules.dubbing_splicer'

  local langs = {}
  if scope and scope ~= 'all_langs' and type(scope) == 'string' then
    langs[1] = scope
  else
    for _, l in ipairs(project.target_languages or {}) do langs[#langs + 1] = l end
  end

  for _, lang in ipairs(langs) do
    if kind == 'all' then
      dub_project.mark_all_translations_stale(project, lang)
    end
    dub_project.mark_all_dub_stale(project, lang)
    for _, seg in ipairs(project.segments or {}) do
      local item_guid = seg.item_guids and seg.item_guids[lang]
      if item_guid and item_guid ~= '' then
        local item = find_item_by_guid(item_guid)
        if item then dub_splicer.mark_item_stale(item) end
      end
    end
  end
end

----------------------------------------------------------------------------
-- Per-segment cascade. kind: 'all' (default) / 'dub_only'.
----------------------------------------------------------------------------
local function propagate_segment_stale(project, seg, lang, kind)
  if not project or not seg or not lang then return end
  kind = kind or 'all'
  local dub_splicer = require 'modules.dubbing_splicer'
  if kind == 'all' and seg.translation_status and seg.translation_status[lang] == 'translated' then
    seg.translation_status[lang] = 'stale'
  end
  if seg.dub_status and seg.dub_status[lang] == 'generated' then
    seg.dub_status[lang] = 'stale'
  end
  local item_guid = seg.item_guids and seg.item_guids[lang]
  if item_guid and item_guid ~= '' then
    local item = find_item_by_guid(item_guid)
    if item then dub_splicer.mark_item_stale(item) end
  end
end

----------------------------------------------------------------------------
-- Per-speaker cascade: flips generated→stale tylko dla segmentów tego speakera
-- (active lang). Used gdy user zmienia voice_id przypisany do speakera
-- (clone IVC, pick from library, similar, designed). Translation text remains
-- valid (LLM nie widzi voice).
----------------------------------------------------------------------------
local function propagate_speaker_stale(project, speaker_id, lang, kind)
  if not project or not speaker_id or not lang then return end
  kind = kind or 'dub_only'
  local dub_splicer = require 'modules.dubbing_splicer'
  local n = 0
  for _, seg in ipairs(project.segments or {}) do
    if seg.speaker_id == speaker_id and not seg.dub_excluded then
      if kind == 'all' and seg.translation_status and seg.translation_status[lang] == 'translated' then
        seg.translation_status[lang] = 'stale'
      end
      if seg.dub_status and seg.dub_status[lang] == 'generated' then
        seg.dub_status[lang] = 'stale'
        n = n + 1
      end
      local item_guid = seg.item_guids and seg.item_guids[lang]
      if item_guid and item_guid ~= '' then
        local item = find_item_by_guid(item_guid)
        if item then dub_splicer.mark_item_stale(item) end
      end
    end
  end
  return n
end

----------------------------------------------------------------------------
-- Reconcile loop: detect REAPER items deleted by user → reset segment do
-- 'pending' (clear item_guids[lang] + dub_audio_paths[lang]). Throttled
-- 2s żeby nie palić CPU na każdy frame (find_item_by_guid robi O(N) scan).
----------------------------------------------------------------------------
local RECONCILE_INTERVAL_S = 2.0

local function reconcile_with_reaper(s)
  if not s.project then return end
  local now = util.now()
  s.last_reconcile_t = s.last_reconcile_t or 0
  if (now - s.last_reconcile_t) < RECONCILE_INTERVAL_S then return end
  s.last_reconcile_t = now

  local langs = s.project.target_languages or {}
  local n_orphaned = 0
  for _, seg in ipairs(s.project.segments or {}) do
    for _, lang in ipairs(langs) do
      local guid   = seg.item_guids and seg.item_guids[lang]
      local status = seg.dub_status and seg.dub_status[lang]
      -- Only check segments that should have a REAPER item (generated/stale).
      if guid and guid ~= '' and (status == 'generated' or status == 'stale') then
        local item = find_item_by_guid(guid)
        if not item then
          seg.dub_status[lang]  = 'pending'
          seg.item_guids[lang]  = ''
          if seg.dub_audio_paths then seg.dub_audio_paths[lang] = nil end
          n_orphaned = n_orphaned + 1
        end
      end
    end
  end
  if n_orphaned > 0 then
    mark_dirty(s)
    set_status(s,
      ('Detected %d deleted dub item(s) → reset to pending. Click Generate dub to re-render.'):format(n_orphaned),
      0xFFB060FF)
  end
end

----------------------------------------------------------------------------
-- Flow B (multi-track): one speaker per selected track, per-item STT no-diarize.
-- Track items concatenated chronologically into a single speaker's segments;
-- segment times are PROJECT-absolute (item D_POSITION + word start within take).
----------------------------------------------------------------------------
local function begin_flow_b(state, s)
  local project = s.project
  local dub_project = require 'modules.dubbing_project'

  if not project.source_track_guids or #project.source_track_guids == 0 then
    s.last_run_error = 'Multi-track source has no track GUIDs stored. Re-open Start modal z zaznaczonymi tracks w REAPER.'
    set_status(s, s.last_run_error, 0xFF8888FF)
    s.phase = 'idle'
    return
  end

  s.flow_b_items_pending = {}
  s.flow_b_item_handles  = {}
  s.flow_b_item_results  = {}

  local total_items = 0
  local valid_tracks = 0
  for _, track_guid in ipairs(project.source_track_guids) do
    local track = find_track_by_guid(track_guid)
    if track then
      valid_tracks = valid_tracks + 1
      local _, track_name = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
      if track_name == nil or track_name == '' then
        local _, idx = reaper.GetSetMediaTrackInfo_String(track, 'IP_TRACKNUMBER', '', false)
        track_name = 'Track ' .. tostring(idx or '?')
      end
      local spk = dub_project.add_speaker(project, track_name)
      spk.source_track_guid = track_guid

      local n_items = reaper.CountTrackMediaItems(track)
      for i = 0, n_items - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local _, item_guid = reaper.GetSetMediaItemInfo_String(item, 'GUID', '', false)
        local t_start  = reaper.GetMediaItemInfo_Value(item, 'D_POSITION') or 0
        local duration = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
        if duration > 0.05 then
          s.flow_b_items_pending[item_guid] = {
            item       = item,
            speaker_id = spk.id,
            t_start    = t_start,
            duration   = duration,
          }
          total_items = total_items + 1
        end
      end
    end
  end

  if total_items == 0 then
    set_status(s, 'No transcribable items found on selected tracks.', 0xFF8888FF)
    s.phase = 'idle'
    return
  end

  s.phase = 'transcribing'   -- transcribing_pump dispatches per-flow
  set_status(s, ('Transcribing %d items across %d tracks (per-track speakers, no diarize)...')
    :format(total_items, valid_tracks), 0xCCCCCCFF)
  mark_dirty(s)
end

local function begin_pipeline(state, s)
  if not s.project then return end
  local project = s.project
  s.last_run_error = nil    -- reset on new run

  if project.source_kind == 'multi_track' then
    begin_flow_b(state, s)
    return
  end

  -- mixed_single: validate source_item_guid exists w current REAPER project.
  -- resolve returns (path, item) on success; (nil, err_str, item?) on error.
  local source_path, err_or_item, item_obj = resolve_source_path_for_mixed(project)
  if not source_path then
    -- err_or_item is error string here (item_obj third return zarezerwowany dla M3 diagnostics)
    local err_msg = ('Cannot find source item: %s. Open Start modal, select item in REAPER, click Start project again.'):format(err_or_item or 'unknown')
    s.last_run_error = err_msg
    set_status(s, err_msg, 0xFF8888FF)
    s.phase = 'idle'
    return
  end
  -- Got a valid path → item_obj_real = err_or_item (the second return on success path is item).
  local source_item = err_or_item   -- on success, 2nd return = item

  -- M4-7 (audit 2026-07): chunker/AudioAccessor zakładają playrate=1 bez
  -- take FX (mirror guardów audio_render.plan_sts_chunks) — bez walidacji
  -- render niesie wbudowane zniekształcenie (chipmunki) do STT i klonów.
  do
    local take = source_item and reaper.GetActiveTake(source_item)
    if take then
      local playrate = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1.0
      local guard_err
      if math.abs(playrate - 1.0) > 0.001 then
        guard_err = 'Source item has playrate != 1.0 — reset the rate (glue/render) before dubbing.'
      elseif reaper.TakeFX_GetCount(take) > 0 then
        guard_err = 'Source item has take FX — render or bypass them before dubbing.'
      end
      if guard_err then
        s.last_run_error = guard_err
        set_status(s, guard_err, 0xFF8888FF)
        s.phase = 'idle'
        return
      end
    end
  end

  -- Voice Isolator opt-in pre-clean
  if project.voice_isolator_enabled and not s.isolated_audio_path then
    local voice_isolator = require 'modules.voice_isolator'
    local h = voice_isolator.spawn_isolate(source_path)
    if h.status == 'error' then
      set_status(s, ('Voice Isolator failed: %s — proceeding w raw audio'):format(h.error), 0xFFB060FF)
    else
      s.isolator_handle = h
      s.phase = 'isolating'
      set_status(s, 'Pre-cleaning source via Voice Isolator...', 0xCCCCCCFF)
      return
    end
  end

  -- Skip isolator → straight to chunking
  s.phase = 'chunking'
  set_status(s, 'Planning chunks...', 0xCCCCCCFF)
end

----------------------------------------------------------------------------
-- Phase chunking → transcribing.
-- Build chunks plan, render each chunk, spawn STT diarize per chunk (max
-- STT_CONCURRENCY concurrent).
----------------------------------------------------------------------------
local function run_chunking_phase(state, s)
  if not s.project then return end
  local project = s.project
  local dubbing_chunker = require 'modules.dubbing_chunker'

  if not s.chunks_plan then
    -- Find source item — capture both returns (path AND item on success).
    local source_path, err_or_item = resolve_source_path_for_mixed(project)
    if not source_path then
      local err_msg = ('Cannot find source item: %s'):format(err_or_item or '?')
      s.last_run_error = err_msg
      set_status(s, err_msg, 0xFF8888FF)
      s.phase = 'idle'
      return
    end
    local source_item = err_or_item   -- on success path, 2nd return is item

    local plan, perr = dubbing_chunker.plan_chunks(source_item, project.project_guid)
    if not plan then
      local err_msg = ('Chunker plan failed: %s'):format(perr or '?')
      s.last_run_error = err_msg
      set_status(s, err_msg, 0xFF8888FF)
      s.phase = 'idle'
      return
    end
    s.chunks_plan = plan
    -- Render all chunks synchronously (AudioAccessor render is fast, ~5x realtime)
    local rendered = 0
    for _, chunk in ipairs(plan) do
      local ok_r, rerr = dubbing_chunker.render_chunk(source_item, chunk)
      if not ok_r then
        set_status(s, ('Render chunk %d failed: %s'):format(chunk.idx, rerr or '?'), 0xFF8888FF)
        s.phase = 'idle'
        s.chunks_plan = nil
        return
      end
      rendered = rendered + 1
    end
    set_status(s, ('Rendered %d chunk(s). Spawning transcription...'):format(rendered), 0xCCCCCCFF)
    s.phase = 'transcribing'
    s.chunks_results = {}
    return
  end
end

----------------------------------------------------------------------------
-- Phase transcribing pump — keep STT_CONCURRENCY running, poll done, advance.
----------------------------------------------------------------------------
local function run_transcribing_pump(state, s)
  local stt = require 'modules.stt'

  -- Count active
  local active = 0
  for _ in pairs(s.chunk_handles) do active = active + 1 end

  -- Spawn next chunks up to concurrency
  if active < STT_CONCURRENCY then
    for _, chunk in ipairs(s.chunks_plan or {}) do
      if s.chunks_results[chunk.idx] == nil and not s.chunk_handles[chunk.idx] then
        -- Spawn STT diarize for this chunk
        local h = stt.spawn_diarize(chunk.output_path, {
          language_code = s.project and s.project.source_language or 'auto',
          model_id      = 'scribe_v2',
          -- M5-6 (advanced): czułość rozdzielania mówców — Settings → Dubbing.
          diarization_threshold = cfg.get_dubbing_diarization_threshold(),
        })
        if h.status == 'error' then
          s.chunks_results[chunk.idx] = { error = h.error }
        else
          h.chunk_idx = chunk.idx
          h.chunk     = chunk
          s.chunk_handles[chunk.idx] = h
          active = active + 1
          if active >= STT_CONCURRENCY then break end
        end
      end
    end
  end

  -- Poll active
  for chunk_idx, h in pairs(s.chunk_handles) do
    if h.status == 'pending' then stt.poll_transcribe(h) end
    -- M2-1 (audit 2026-07): martwy worker = handle wiecznie pending →
    -- spinner bez wyjścia (CTA renderuje się tylko w idle/ready). Stale →
    -- error → agregacja niżej przechodzi w idle z komunikatem.
    if h.status == 'pending' or h.status == 'running' then
      force_error_if_stale(h, ('STT chunk %d'):format(chunk_idx))
    end
    if h.status == 'done' then
      s.chunks_results[chunk_idx] = h.transcript or {}
      -- Cost: chunk duration in minutes
      local chunk = h.chunk or {}
      cost_add_stt(s.project, (chunk.duration or 0) / 60)
      s.chunk_handles[chunk_idx] = nil
    elseif h.status == 'error' then
      s.chunks_results[chunk_idx] = { error = h.error }
      s.chunk_handles[chunk_idx] = nil
    end
  end

  -- All chunks done?
  if s.chunks_plan and #s.chunks_plan > 0 then
    local all_done = true
    for _, chunk in ipairs(s.chunks_plan) do
      if s.chunks_results[chunk.idx] == nil then all_done = false; break end
    end
    if all_done then
      -- Aggregate errors
      local errors = {}
      for _, chunk in ipairs(s.chunks_plan) do
        local r = s.chunks_results[chunk.idx]
        if r and r.error then errors[#errors + 1] = ('chunk %d: %s'):format(chunk.idx, r.error) end
      end
      if #errors > 0 then
        set_status(s, 'STT errors: ' .. table.concat(errors, '; '), 0xFF8888FF)
        s.phase = 'idle'
        s.chunks_plan = nil
        s.chunks_results = {}
        return
      end
      -- Transition to matching_speakers
      s.phase = 'matching_speakers'
      s.speaker_match_modal_pending_open = true
      set_status(s, 'Transcription done. Assign voices to characters.', 0x80E090FF)
    end
  end
end

----------------------------------------------------------------------------
-- Flow B transcribing pump — per-item STT no-diarize via spawn_transcribe_for_item.
-- All items on same track → one speaker. Segments built when all done.
----------------------------------------------------------------------------
local function build_segments_flow_b(s)
  local project = s.project
  local dub_project = require 'modules.dubbing_project'
  for item_guid, info in pairs(s.flow_b_items_pending) do
    local transcript = s.flow_b_item_results[item_guid]
    if transcript and not transcript.error and type(transcript.words) == 'table' and #transcript.words > 0 then
      local item_offset = info.t_start
      local text_parts = {}
      local source_words = {}
      local seg_t_start, seg_t_end
      for _, w in ipairs(transcript.words) do
        local wt = (w.text and w.text ~= '') and w.text or (w.word or '')
        if wt and wt ~= '' then
          text_parts[#text_parts + 1] = wt
          local w_start = (w.start or 0) + item_offset
          local w_end   = (w['end'] or w.start or 0) + item_offset
          source_words[#source_words + 1] = { text = wt, start = w_start, ['end'] = w_end }
          if not seg_t_start then seg_t_start = w_start end
          seg_t_end = w_end
        end
      end
      if seg_t_start and #text_parts > 0 then
        dub_project.add_segment(project, info.speaker_id,
          seg_t_start, seg_t_end or (seg_t_start + info.duration),
          table.concat(text_parts, ' '),
          source_words)   -- M3.6
      end
    end
  end
  -- Sort segments by t_start (across tracks they were added in track order, but real timeline mixes)
  table.sort(project.segments, function(a, b) return (a.t_start or 0) < (b.t_start or 0) end)
end

local function run_transcribing_pump_flow_b(state, s)
  if not s.project then return end
  local stt = require 'modules.stt'

  local active = 0
  for _ in pairs(s.flow_b_item_handles) do active = active + 1 end

  -- Spawn STT per pending item up to concurrency
  if active < STT_CONCURRENCY then
    for item_guid, info in pairs(s.flow_b_items_pending) do
      if s.flow_b_item_results[item_guid] == nil and not s.flow_b_item_handles[item_guid] then
        local h = stt.spawn_transcribe_for_item(info.item, {
          language_code = (s.project.source_language ~= 'auto' and s.project.source_language) or 'en',
          model_id      = 'scribe_v2',
          diarize       = false,
        })
        if h.status == 'error' then
          s.flow_b_item_results[item_guid] = { error = h.error }
        elseif h.status == 'done' then
          -- Cache hit (p_ext or file_cache) — instant
          s.flow_b_item_results[item_guid] = h.transcript
        else
          h.flow_b_item_guid = item_guid
          s.flow_b_item_handles[item_guid] = h
          active = active + 1
          if active >= STT_CONCURRENCY then break end
        end
      end
    end
  end

  -- Poll active
  for item_guid, h in pairs(s.flow_b_item_handles) do
    if h.status == 'pending' then stt.poll_transcribe(h) end
    -- M2-1: stale → error → all_done z partial coverage (mirror chunk pump)
    if h.status == 'pending' or h.status == 'running' then
      force_error_if_stale(h, 'STT track item')
    end
    if h.status == 'done' then
      s.flow_b_item_results[item_guid] = h.transcript or {}
      local info = s.flow_b_items_pending[item_guid]
      if info and h.source == 'api' then
        cost_add_stt(s.project, (info.duration or 0) / 60)
      end
      s.flow_b_item_handles[item_guid] = nil
    elseif h.status == 'error' then
      s.flow_b_item_results[item_guid] = { error = h.error }
      s.flow_b_item_handles[item_guid] = nil
    end
  end

  -- All done?
  local all_done = true
  local any_pending = false
  for item_guid in pairs(s.flow_b_items_pending) do
    any_pending = true
    if s.flow_b_item_results[item_guid] == nil then all_done = false; break end
  end
  if any_pending and all_done then
    local errors = {}
    for item_guid in pairs(s.flow_b_items_pending) do
      local r = s.flow_b_item_results[item_guid]
      if r and r.error then errors[#errors + 1] = ('item: %s'):format(r.error) end
    end
    -- Build segments even if some items errored (partial coverage acceptable)
    build_segments_flow_b(s)
    if #errors > 0 then
      set_status(s, ('Flow B: %d item(s) errored — %d segment(s) built. %s')
        :format(#errors, #s.project.segments, errors[1]), 0xFFB060FF)
    else
      set_status(s, ('Flow B done: %d segment(s) across %d speaker(s). Assign voices.')
        :format(#s.project.segments, #s.project.speakers), 0x80E090FF)
    end
    -- Bypass speaker_match (track-name = speaker already done) → casting_voices
    s.phase = 'casting_voices'
    s.flow_b_items_pending = {}
    s.flow_b_item_results  = {}
    mark_dirty(s)
  end
end

----------------------------------------------------------------------------
-- Translate-all pump — iterate segments, spawn translate per segment up to
-- TRANSLATE_CONCURRENCY, poll done, retry-on-429.
----------------------------------------------------------------------------
local CONTEXT_PREV_WINDOW = 2   -- N "substantive" previous segments (skipping short interjections)
local CONTEXT_NEXT_WINDOW = 1   -- N "substantive" next segments (lookhead, source only)
local CONTEXT_MIN_WORDS   = 4   -- segments shorter than this skipped as context (interjections like "Yeah", "OK", "no")
local CONTEXT_MAX_SCAN    = 12  -- safety: don't scan more than this many neighbors in each direction

local function _wc(text)
  if not text or text == '' then return 0 end
  local n = 0
  for _ in text:gmatch('%S+') do n = n + 1 end
  return n
end

-- Find up to n_target "substantive" segments before idx (word count >= threshold).
-- Returns list in chronological order (earliest first). Short interjections
-- ("Yeah", "to", "Yes") skipped — they don't ground continuation.
--
-- FIX 2026-06-11 (live-caught, 7-min klip): segmenty EXCLUDED też pomijamy.
-- Pre-fix excluded substantive seg w oknie kontekstu = DEADLOCK pipeline'u:
-- prev_translations_ready czekał na jego tłumaczenie, a pompa excluded
-- nigdy nie tłumaczy (user live: 15 excluded → 64 segmentów WAITING forever
-- po seg 1). Excluded nie wnosi też kontekstu (zwykle śmieci STT / muzyka).
local function context_prev_substantive(segments, idx, n_target)
  local found = {}
  local stop = math.max(1, idx - CONTEXT_MAX_SCAN)
  for k = idx - 1, stop, -1 do
    local seg = segments[k]
    if seg and not seg.dub_excluded
       and _wc(seg.source_text or '') >= CONTEXT_MIN_WORDS then
      table.insert(found, 1, seg)
      if #found >= n_target then break end
    end
  end
  return found
end

local function context_next_substantive(segments, idx, n_target)
  local found = {}
  local stop = math.min(#segments, idx + CONTEXT_MAX_SCAN)
  for k = idx + 1, stop do
    local seg = segments[k]
    if seg and not seg.dub_excluded
       and _wc(seg.source_text or '') >= CONTEXT_MIN_WORDS then
      table.insert(found, seg)
      if #found >= n_target then break end
    end
  end
  return found
end

-- Build the sliding context section appended before the to-be-translated segment.
-- Returns string (possibly empty) + sliding hash fingerprint (for cache key).
local function build_translate_context(segments, idx, lang)
  if not cfg.get_dubbing_translate_context_enabled() then return '', '' end
  local prevs = context_prev_substantive(segments, idx, CONTEXT_PREV_WINDOW)
  -- M4-5 wariant A (user 2026-07-11): terminalnie failed prev nie wnosi
  -- kontekstu (nie ma tłumaczenia i bez akcji usera nigdy nie będzie) —
  -- tłumaczymy dalej bez tej podpowiedzi zamiast czekać w nieskończoność.
  local kept = {}
  for _, p in ipairs(prevs) do
    local st = p.translation_status and p.translation_status[lang]
    if st ~= 'failed' then kept[#kept + 1] = p end
  end
  prevs = kept
  local nexts = context_next_substantive(segments, idx, CONTEXT_NEXT_WINDOW)
  if #prevs == 0 and #nexts == 0 then return '', '' end
  local hash_parts = {}
  local lines = {}
  if #prevs > 0 then
    table.insert(lines, 'Previous context (already translated — FOR REFERENCE ONLY, do not re-translate):')
    for _, prev in ipairs(prevs) do
      local src = prev.source_text or ''
      local trn = (prev.translations and prev.translations[lang]) or ''
      table.insert(lines, ('[%s] %s'):format(prev.id or '?', src))
      if trn ~= '' then
        table.insert(lines, ('     → %s'):format(trn))
      end
      table.insert(hash_parts, src)
    end
  end
  if #nexts > 0 then
    if #lines > 0 then table.insert(lines, '') end
    table.insert(lines, 'Upcoming segment (for continuation awareness, do not translate):')
    for _, nxt in ipairs(nexts) do
      local src = nxt.source_text or ''
      table.insert(lines, ('[%s] %s'):format(nxt.id or '?', src))
      table.insert(hash_parts, src)
    end
  end
  local section = table.concat(lines, '\n')
  local fingerprint = ('%08x'):format(util.simple_hash(table.concat(hash_parts, '|')))
  return section, fingerprint
end

-- Headless test hook (pure scanner) — regression guard na deadlock excluded
-- w oknie kontekstu (tests/run.lua).
M.context_prev_substantive = context_prev_substantive

-- Check if substantive previous segments are translated. Short interjections
-- (skipped from context) don't gate spawn — concurrency preserved for them.
-- M4-5 wariant A (user 2026-07-11): status 'failed' NIE blokuje — segment
-- tłumaczy się dalej bez kontekstu z nieudanego sąsiada (pre-fix: ogon
-- czekał wiecznie; failed pokazuje pill FAILED + [Retry], reszta jedzie).
local function prev_translations_ready(segments, idx, lang)
  local prevs = context_prev_substantive(segments, idx, CONTEXT_PREV_WINDOW)
  for _, prev in ipairs(prevs) do
    local st = prev.translation_status and prev.translation_status[lang]
    if st ~= 'translated' and st ~= 'failed' then return false end
  end
  return true
end

-- Headless test hook (M4-5 regression: failed prev nie blokuje ogona).
M.prev_translations_ready = prev_translations_ready

local function run_translate_pump(state, s)
  if not s.project then return end
  local llm = require 'modules.llm'
  local tempo_math = require 'modules.tempo_math'
  local lang = s.project.active_target_language
  if not lang then return end

  local active = 0
  for _ in pairs(s.translate_handles) do active = active + 1 end

  local context_enabled = cfg.get_dubbing_translate_context_enabled()

  -- Spawn new translates up to concurrency
  if s.translate_pending and active < TRANSLATE_CONCURRENCY then
    for i, seg in ipairs(s.project.segments) do
      local status = seg.translation_status and seg.translation_status[lang]
      if not seg.dub_excluded
         and (status == 'pending' or status == 'stale')
         and not s.translate_handles[seg.id]
         and (not s.retry_at[seg.id] or s.retry_at[seg.id] <= util.now()) then
        -- Best-effort sequential gate: gdy context ON, czekaj aż poprzednie
        -- N segments są translated. Inaczej zachowujemy concurrency.
        -- M4-5: failed prev NIE blokuje (ready traktuje 'failed' jak
        -- rozstrzygnięty) — ogon jedzie dalej, kontekst z failed pominięty
        -- w build_translate_context; failed segment ma pill + [Retry].
        if context_enabled and not prev_translations_ready(s.project.segments, i, lang) then
          -- Skip — czekamy na in-flight poprzednie, next tick ponowi.
        else
        local system_prompt = llm.build_system_prompt(s.project, lang)
        -- M2.6: cache_control honoruje per-provider toggle. Anthropic = full off/on
        -- (90% off after first request, 5min TTL). Other providers ignore the flag.
        local cache_on = (llm.effective_provider() == 'anthropic')
                        and cfg.get_dubbing_anthropic_prompt_caching()
        -- Sliding context section (empty string when disabled)
        local ctx_section, ctx_fingerprint = build_translate_context(s.project.segments, i, lang)
        -- M3.5: director's note appended per-segment (not w system prompt — preserves cache).
        local prefix = (ctx_section ~= '') and (ctx_section .. '\n\n') or ''
        -- Timing budget (2026-06-10): LLM dostaje czas + sylaby źródła —
        -- tłumaczenie ma wypełnić czas frazą/pauzami (PAUSE SYNTAX w system
        -- prompcie) zamiast zdawać się na stretch w dubbing_splicer.
        local seg_dur = math.max(0, (seg.t_end or 0) - (seg.t_start or 0))
        local src_syl = tempo_math.syllable_count(seg.source_text or '')
        local timing_line = ('TIMING BUDGET: the source line lasts %.1f seconds (%d syllables). Spoken translation + inserted pauses must fill the full %.1f seconds — if your translation has fewer syllables than the source, add roughly 1 second of pause per 5 missing syllables, placed per the pacing rules.')
          :format(seg_dur, src_syl, seg_dur)
        local user_prompt
        if seg.director_note and seg.director_note ~= '' then
          user_prompt = ('%sTranslate the following segment to %s, maintaining continuity with previous context above. Return JSON {translation, alternatives?, syllable_count?, confidence?}.\n\n%s\n\nDirector\'s note for this segment: %s\n\nSegment to translate: %s')
            :format(prefix, lang, timing_line, seg.director_note, seg.source_text or '')
        else
          user_prompt = ('%sTranslate the following segment to %s, maintaining continuity with previous context above. Return JSON {translation, alternatives?, syllable_count?, confidence?}.\n\n%s\n\nSegment to translate: %s')
            :format(prefix, lang, timing_line, seg.source_text or '')
        end
        -- Cache key includes sliding context fingerprint — re-translation of any
        -- neighbor invalidates this segment's cache entry (correct: context
        -- changed → translation may need to differ).
        local proj_ctx_hash = require('modules.dubbing_project').context_hash(s.project)
        local combined_ctx_hash = proj_ctx_hash .. '|slide:' .. (ctx_fingerprint or '')
        local h = llm.spawn_translate({
          system_prompt  = system_prompt,
          user_prompt    = user_prompt,
          -- Budget folded do cache key — zmiana timingu segmentu = świeże tłumaczenie.
          source_text    = (seg.source_text or '') .. '|note:' .. (seg.director_note or '')
                           .. ('|tb:%.1f/%d'):format(seg_dur, src_syl),
          target_lang    = lang,
          glossary_hash  = require('modules.dubbing_project').glossary_hash(s.project),
          context_hash   = combined_ctx_hash,
          max_tokens     = 1024,
          temperature    = 0.7,
          cache_control  = cache_on,
        })
        if h.status == 'error' then
          seg.translation_status[lang] = 'pending'
          set_status(s, ('Translate %s err: %s'):format(seg.id, h.error or '?'), 0xFF8888FF)
        elseif h.status == 'done' and h.result then
          -- Cache hit (instant, doesn't count toward concurrency)
          local prev_text = seg.translations[lang]
          seg.translations[lang] = h.result.translation
          seg.translation_status[lang] = 'translated'
          -- Nowy tekst = wygenerowany dub gra starą wersję → stale (2026-06-10;
          -- pre-fix re-translate zostawiał dub 'generated' i Generate dub no-op).
          if prev_text and prev_text ~= h.result.translation then
            propagate_segment_stale(s.project, seg, lang, 'dub_only')
          end
          if s.project.cost_tracker then
            s.project.cost_tracker.translate_cache_hits = (s.project.cost_tracker.translate_cache_hits or 0) + 1
          end
          mark_dirty(s)
        else
          h.seg_id = seg.id
          h.retries = h.retries or 0
          s.translate_handles[seg.id] = h
          active = active + 1
          if active >= TRANSLATE_CONCURRENCY then break end
        end
        end   -- end of `if context_enabled and not prev_ready ... else ...`
      end
    end
    -- Check if anything left pending (skip excluded)
    local any_pending = false
    for _, seg in ipairs(s.project.segments) do
      if not seg.dub_excluded then
        local status = seg.translation_status and seg.translation_status[lang]
        if status == 'pending' or status == 'stale' then any_pending = true; break end
      end
    end
    -- Also check for running handles
    if not any_pending then
      local any_running = next(s.translate_handles) ~= nil
      if not any_running then s.translate_pending = false end
    end
  end

  -- Poll running translate handles
  for seg_id, h in pairs(s.translate_handles) do
    if h.status == 'running' then llm.poll(h) end
    if h.status == 'running' then force_error_if_stale(h, ('Translate %s'):format(seg_id)) end
    if h.status == 'done' then
      local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
      if seg and h.result then
        local prev_text = seg.translations[lang]
        seg.translations[lang] = h.result.translation
        seg.translation_status[lang] = 'translated'
        if seg.translation_error then seg.translation_error[lang] = nil end
        -- Nowy tekst = wygenerowany dub gra starą wersję → stale (2026-06-10).
        if prev_text and prev_text ~= h.result.translation then
          propagate_segment_stale(s.project, seg, lang, 'dub_only')
        end
        if not h.from_cache and h.result.usage then
          cost_add_llm(s.project, h.result.usage.input_tokens, h.result.usage.output_tokens, h.provider)
          if s.project.cost_tracker then
            s.project.cost_tracker.translate_fresh = (s.project.cost_tracker.translate_fresh or 0) + 1
          end
        end
        mark_dirty(s)
      end
      s.translate_handles[seg_id] = nil
    elseif h.status == 'error' then
      -- Retry on 429
      if h.http_code == 429 and (h.retries or 0) < MAX_429_RETRIES then
        h.retries = (h.retries or 0) + 1
        local delay = RETRY_BACKOFF_SECS[h.retries] or 4
        s.retry_at[seg_id] = util.now() + delay
        -- Reset seg back to pending; will respawn after retry_at
        local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
        if seg then seg.translation_status[lang] = 'pending' end
        s.translate_handles[seg_id] = nil
        set_status(s, ('Rate-limited; retry %s in %.1fs'):format(seg_id, delay), 0xFFB060FF)
      else
        -- M1-4b (audit 2026-06-10): terminal 'failed' zamiast resetu do
        -- 'pending'. Pre-fix: status 'pending' + brak retry_at = pompa
        -- respawnowała failed segment CO TICK w nieskończoność (request
        -- spam przy trwałym błędzie typu zły klucz / model error).
        -- 'failed' nie matchuje warunku spawnu; Translate all resetuje
        -- failed → pending (user-driven retry).
        local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
        if seg then
          seg.translation_status[lang] = 'failed'
          -- W3 quick win: przyczyna trwale przy segmencie (tooltip na FAILED
          -- w tabeli) — status line nadpisuje się po chwili.
          seg.translation_error = seg.translation_error or {}
          seg.translation_error[lang] = tostring(h.error or '?')
        end
        s.translate_handles[seg_id] = nil
        set_status(s, ('Translate %s failed: %s'):format(seg_id, h.error or '?'), 0xFF8888FF)
      end
    end
  end
end

----------------------------------------------------------------------------
-- Generate-dub pump — per segment: TTS → forced_align (optional) → splice.
-- State machine per seg.dub_status:
--   pending → tts_running → tts_done → align_running → align_done → splicing → generated
----------------------------------------------------------------------------
----------------------------------------------------------------------------
-- W3 Pakiet B+ (backlog s2): terminalne porażki generowania dubu — mirror
-- M1-4b z translate pump. 'failed' nie matchuje warunku spawnu (pending/
-- stale), więc trwały błąd NIE wraca do pompy w pętli (pre-fix: powrót do
-- 'pending' = natychmiastowy płatny respawn dopóki generate aktywne). Powód
-- trwale per-segment w seg.dub_error[lang] (tooltip FAILED + chip [Retry]
-- w stopce); lazy-init = backward compat ze starymi projektami.
----------------------------------------------------------------------------
local function set_dub_failed(s, seg, lang, why)
  seg.dub_status[lang] = 'failed'
  seg.dub_error = seg.dub_error or {}
  seg.dub_error[lang] = tostring(why or '?')
  mark_dirty(s)
end

----------------------------------------------------------------------------
-- W2 M1: request stitching — previous_text/next_text z NAJBLIŻSZYCH kwestii
-- TEGO speakera (target lang) dla ciągłości prozodii między segmentami.
-- BRAMKA MODELU obowiązkowa: tylko v2/turbo/flash — eleven_v3 zwraca
-- HTTP 400 na prev/next (live-caught 2026-06-11, KNOWN-ISSUES durable).
-- Najbliższy sąsiad bez tłumaczenia → bez kontekstu z tej strony (dalszy
-- segment NIE jest prozodycznym sąsiadem — nie podstawiamy).
----------------------------------------------------------------------------
local STITCH_MODELS = {
  eleven_multilingual_v2 = true,
  eleven_turbo_v2_5      = true,
  eleven_flash_v2_5      = true,
}

local function stitch_context_for(project, seg, lang, model_id)
  if not STITCH_MODELS[model_id or ''] then return nil, nil end
  local segments = project.segments or {}
  local idx
  for i, sg in ipairs(segments) do
    if sg.id == seg.id then idx = i; break end
  end
  if not idx then return nil, nil end
  local function translated_text(sg)
    local st = sg.translation_status and sg.translation_status[lang]
    if st ~= 'translated' and st ~= 'stale' then return nil end
    local t = sg.translations and sg.translations[lang]
    if t and t ~= '' then return t end
    return nil
  end
  local prev_text, next_text
  for i = idx - 1, 1, -1 do
    local sg = segments[i]
    if sg.speaker_id == seg.speaker_id and not sg.dub_excluded then
      prev_text = translated_text(sg)
      break
    end
  end
  for i = idx + 1, #segments do
    local sg = segments[i]
    if sg.speaker_id == seg.speaker_id and not sg.dub_excluded then
      next_text = translated_text(sg)
      break
    end
  end
  return prev_text, next_text
end

----------------------------------------------------------------------------
-- W2 M1 (user decision 2026-06-11): seed DETERMINISTYCZNY per segment+take —
-- wznowienie przerwanego batcha = cache hit (zero kosztu), świeża
-- interpretacja przez JAWNY Re-gen / Force re-gen (bump seg.dub_take_n).
-- Zamyka KNOWN-ISSUES "uncached-by-design" (random seed w kluczu cache);
-- licznik tts_cache_hits w cost trackerze ożywa.
----------------------------------------------------------------------------
local function dub_seed_for(seg, lang)
  local take_n = (seg.dub_take_n and seg.dub_take_n[lang]) or 0
  local h = util.simple_hash(('dubseed|%s|%s|%d'):format(tostring(seg.id), tostring(lang), take_n))
  return (h % 0x7FFFFFFE) + 1
end

local function bump_dub_take(seg, lang)
  seg.dub_take_n = seg.dub_take_n or {}
  seg.dub_take_n[lang] = (seg.dub_take_n[lang] or 0) + 1
end

----------------------------------------------------------------------------
-- T2 (UX-POLISH 2026-07): JEDNO źródło opts dla TTS segmentu — pump
-- Generate ORAZ preview tłumaczenia budują IDENTYCZNY request (voice
-- resolution + settings + stitching + deterministyczny seed) → preview
-- renderuje do tego samego cache, Generate po odsłuchu = cache hit
-- (zero podwójnego billingu). Zwraca (opts, voice_id) | (nil, err_msg).
----------------------------------------------------------------------------
local function build_dub_tts_opts(s, seg, lang)
  local speaker = require('modules.dubbing_project').find_speaker(s.project, seg.speaker_id)
  if not speaker then
    return nil, ('Speaker %s missing'):format(seg.speaker_id or '?'), 'no_speaker'
  end
  local voice_id = (seg.voice_id_overrides and seg.voice_id_overrides[lang])
               or (speaker.voices and speaker.voices[lang])
  if not voice_id or voice_id == '' then
    return nil, ('Speaker %s has no voice for %s')
      :format(speaker.label or speaker.id, lang:upper()), 'no_voice'
  end
  local text = (seg.translations and seg.translations[lang]) or ''
  if text == '' then return nil, 'segment has no translation', 'no_text' end
  local voice_settings = (seg.voice_settings_overrides and seg.voice_settings_overrides[lang])
                      or (speaker.voice_settings_per_lang and speaker.voice_settings_per_lang[lang])
                      or nil
  local model_id = s.project.tts_model or cfg.get_dubbing_default_tts_model()
  local prev_text, next_text = stitch_context_for(s.project, seg, lang, model_id)
  return {
    voice_id       = voice_id,
    text           = text,
    model_id       = model_id,
    voice_settings = voice_settings,
    language_code  = lang,
    output_format  = 'mp3_44100_128',
    prev_text      = prev_text,
    next_text      = next_text,
    seed           = dub_seed_for(seg, lang),
  }
end

----------------------------------------------------------------------------
-- W2 M1 §2.4: anti-skok — po splice'u segmentu porównaj applied_rate z
-- sąsiadami TEGO speakera (w OBIE strony — przy concurrency 3 późniejszy
-- segment może być wygenerowany pierwszy); |Δ| > 0.12 → kompromis w stronę
-- średniej (tylko strefa zielona obu + bez tworzenia NOWEGO overrunu),
-- re-fit OBU itemów in-place (zero API). Pomijane dla per-word / natural /
-- overrun (własne reguły tempa). Wynik znaczony smoothed w seg.dub_fit.
----------------------------------------------------------------------------
local function smooth_pair(s, seg_a, seg_b, lang)
  local tempo_math = require 'modules.tempo_math'
  local dubbing_splicer = require 'modules.dubbing_splicer'
  local project = s.project

  local fit_a = seg_a.dub_fit and seg_a.dub_fit[lang]
  local fit_b = seg_b.dub_fit and seg_b.dub_fit[lang]
  if not fit_a or not fit_b then return end
  -- W2 M2: user override (suwak) = jawna decyzja — anti-skok nie nadpisuje
  -- żadnej strony pary (kompromis liczyłby się z wartością, której user
  -- nie chce ruszać).
  if (seg_a.dub_stretch_override and seg_a.dub_stretch_override[lang])
  or (seg_b.dub_stretch_override and seg_b.dub_stretch_override[lang]) then
    return
  end
  -- Tylko pary force_span fit/gap — per-word i natural mają własne reguły,
  -- overrun już stoi na R_MIN (kompromis pogorszyłby nakładkę).
  local smoothable = { fit = true, gap = true }
  if not smoothable[fit_a.strategy] or not smoothable[fit_b.strategy] then return end
  if not (seg_a.dub_status and seg_a.dub_status[lang] == 'generated') then return end
  if not (seg_b.dub_status and seg_b.dub_status[lang] == 'generated') then return end

  local r_min, r_max = cfg.get_dubbing_fit_bounds()
  -- Feasibility cap: rate w górę tylko do (span+slack)/speech_len — smoothing
  -- nie może wyprodukować nakładki, której fit uniknął. Slack z PEŁNEJ
  -- dostępnej przestrzeni (project-based, deterministyczny).
  local function hi_cap(sg, fit)
    local span = math.max(0.05, (sg.t_end or 0) - (sg.t_start or 0))
    local slack_avail = dubbing_splicer.compute_slack_for_segment(project, sg)
    local geom = (span + slack_avail) / math.max(0.05, fit.speech_len or 1)
    return math.min(r_max, math.max(r_min, geom))
  end
  local na, nb = tempo_math.dub_fit_smooth(
    fit_a.applied_rate, fit_b.applied_rate,
    r_min, hi_cap(seg_a, fit_a),
    r_min, hi_cap(seg_b, fit_b))
  if not na then return end

  local pairs_to_fit = { { seg_a, na }, { seg_b, nb } }
  for _, pr in ipairs(pairs_to_fit) do
    local sg, rate = pr[1], pr[2]
    dubbing_splicer.refit_segment_item(project, sg, lang, {
      rate_override = rate,
      smoothed      = true,
      alignment     = sg.dub_alignment and sg.dub_alignment[lang] or nil,
    })
  end
  mark_dirty(s)
end

local function smooth_with_neighbors(s, seg, lang)
  local segments = (s.project and s.project.segments) or {}
  local idx
  for i, sg in ipairs(segments) do
    if sg.id == seg.id then idx = i; break end
  end
  if not idx then return end
  for i = idx - 1, 1, -1 do
    local sg = segments[i]
    if sg.speaker_id == seg.speaker_id and not sg.dub_excluded then
      smooth_pair(s, sg, seg, lang)
      break
    end
  end
  for i = idx + 1, #segments do
    local sg = segments[i]
    if sg.speaker_id == seg.speaker_id and not sg.dub_excluded then
      smooth_pair(s, seg, sg, lang)
      break
    end
  end
end

-- Wywoływane po KAŻDYM udanym splice'u (fresh/cache/regen). pcall —
-- smoothing to polish, nigdy nie może zablokować pipeline'u generowania.
local function on_segment_dubbed(s, seg, lang)
  local okp, serr = pcall(smooth_with_neighbors, s, seg, lang)
  if not okp then
    set_status(s, ('Anti-jump smoothing error (non-fatal): %s'):format(tostring(serr)), 0xFFB060FF)
  end
end

local function run_generate_dub_pump(state, s)
  if not s.project then return end
  local lang = s.project.active_target_language
  if not lang then return end
  local voice_admin = require 'modules.voice_admin'
  local forced_align = require 'modules.forced_align'
  local dubbing_splicer = require 'modules.dubbing_splicer'

  local active = 0
  for _ in pairs(s.tts_handles) do active = active + 1 end
  for _ in pairs(s.align_handles) do active = active + 1 end

  -- Spawn next TTS up to concurrency
  if s.generate_pending and active < DUB_CONCURRENCY then
    for _, seg in ipairs(s.project.segments) do
      local trans_status = seg.translation_status and seg.translation_status[lang]
      local dub_status   = seg.dub_status and seg.dub_status[lang]
      -- M4 fix: accept both 'translated' AND 'stale' translation status — gdy
      -- translation has text, dub can be generated (user accepts staleness or
      -- propagate_stale was triggered przez voice change, not context change).
      local trans_ready = (trans_status == 'translated' or trans_status == 'stale')
                          and ((seg.translations and seg.translations[lang]) or '') ~= ''
      if not seg.dub_excluded
         and trans_ready
         and (dub_status == 'pending' or dub_status == 'stale')
         and not s.tts_handles[seg.id]
         and not s.align_handles[seg.id]
         and (not s.retry_at['tts_' .. seg.id] or s.retry_at['tts_' .. seg.id] <= util.now()) then
        -- T2 (UX-POLISH): opts przez build_dub_tts_opts — TO SAMO źródło
        -- co preview tłumaczenia (W2 M1: stitching z bramką modelu +
        -- deterministyczny seed → resume/preview = cache hit).
        local tts_opts, oerr, okind = build_dub_tts_opts(s, seg, lang)
        if not tts_opts and okind == 'no_speaker' then
          set_status(s, oerr, 0xFF8888FF)
          seg.dub_status[lang] = 'pending'
        elseif not tts_opts and okind == 'no_voice' then
          set_status(s, oerr, 0xFFB060FF)
          -- Don't infinitely re-trigger
          s.generate_pending = false
          return
        else
          if not tts_opts then
            -- no_text (pusty translation mimo trans_ready — defensywnie)
            seg.dub_status[lang] = 'pending'
          else
            local h = voice_admin.spawn_tts(tts_opts)
            if h.status == 'error' then
              set_dub_failed(s, seg, lang, 'TTS spawn: ' .. tostring(h.error or '?'))
              set_status(s, ('TTS %s err: %s'):format(seg.id, h.error or '?'), 0xFF8888FF)
            else
              h.seg_id = seg.id
              h.lang   = lang
              h.retries = 0
              s.tts_handles[seg.id] = h
              seg.dub_status[lang] = 'tts_running'
              -- Świeża próba unieważnia stary powód porażki
              if seg.dub_error then seg.dub_error[lang] = nil end
              -- Cache hit (status='done' z spawn) — poll branch below picks it
              -- up on the same frame; cost gated by from_cache flag in done branch.
              active = active + 1
              if active >= DUB_CONCURRENCY then break end
            end
          end
        end
      end
    end
  end

  -- Poll TTS handles → on done spawn forced_align (or splice directly if config off)
  for seg_id, h in pairs(s.tts_handles) do
    if h.status == 'running' then voice_admin.poll(h) end
    if h.status == 'running' then force_error_if_stale(h, ('TTS %s'):format(seg_id)) end
    if h.status == 'done' then
      local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
      if seg and h.result then
        seg.dub_audio_paths[lang] = h.result   -- mp3 path
        if h.from_cache then
          if s.project.cost_tracker then
            s.project.cost_tracker.tts_cache_hits = (s.project.cost_tracker.tts_cache_hits or 0) + 1
          end
        else
          cost_add_tts(s.project, util.utf8_len(seg.translations[lang] or ''), s.project.tts_model)
        end
        -- Trigger forced_align (if config enabled) lub splice directly
        if cfg.get_dubbing_forced_align_auto() then
          local align_h = forced_align.spawn(h.result, seg.translations[lang] or '')
          if align_h.status == 'error' then
            set_status(s, ('Align %s err: %s — proceeding bez alignment'):format(seg_id, align_h.error or '?'), 0xFFB060FF)
            -- Splice without alignment
            local sp_res = dubbing_splicer.splice_segment(s.project, seg, require('modules.dubbing_project').find_speaker(s.project, seg.speaker_id), lang, h.result, { regen = false })
            if sp_res.ok then
              seg.dub_status[lang] = 'generated'
              seg.item_guids[lang] = sp_res.item_guid
              seg.dub_n_items[lang] = sp_res.n_items or 1
              if not seg.dub_per_word then seg.dub_per_word = {} end
              seg.dub_per_word[lang] = sp_res.per_word == true
              mark_dirty(s)
              on_segment_dubbed(s, seg, lang)
            else
              set_dub_failed(s, seg, lang, 'Splice: ' .. tostring(sp_res.err))
              set_status(s, ('Splice %s err: %s'):format(seg_id, sp_res.err), 0xFF8888FF)
            end
          else
            align_h.seg_id = seg_id
            align_h.lang   = lang
            s.align_handles[seg_id] = align_h
            seg.dub_status[lang] = 'align_running'
            -- Cache hit → process inline (FIX #19: toggle-aware splice —
            -- previously hardcoded splice_segment, ignored per-word toggle
            -- when forced_align cache hit, requiring REAPER restart workaround).
            if align_h.status == 'done' then
              seg.dub_alignment[lang] = align_h.result
              cost_add_forced_align(s.project, (seg.t_end - seg.t_start) / 60)
              local speaker = require('modules.dubbing_project').find_speaker(s.project, seg.speaker_id)
              local sp_res
              local fallback_reason = ''
              if cfg.get_dubbing_per_word_splice() then
                sp_res = dubbing_splicer.splice_segment_per_word(s.project, seg, speaker, lang, h.result, align_h.result, { regen = false })
                if not sp_res.ok then
                  fallback_reason = sp_res.err or 'unknown'
                  set_status(s, ('Per-word splice %s fallback: %s'):format(seg_id, fallback_reason), 0xFFB060FF)
                  sp_res = nil
                end
              else
                fallback_reason = 'toggle_off'
              end
              if not sp_res then
                sp_res = dubbing_splicer.splice_segment(s.project, seg, speaker, lang, h.result,
                  { regen = false, alignment = align_h.result })
              end
              if sp_res.ok then
                seg.dub_status[lang] = 'generated'
                seg.item_guids[lang] = sp_res.item_guid
                seg.dub_n_items[lang] = sp_res.n_items or 1
                if not seg.dub_per_word then seg.dub_per_word = {} end
                seg.dub_per_word[lang] = sp_res.per_word == true
                if not seg.dub_per_word_fallback_reason then seg.dub_per_word_fallback_reason = {} end
                seg.dub_per_word_fallback_reason[lang] = sp_res.per_word and '' or fallback_reason
                mark_dirty(s)
                on_segment_dubbed(s, seg, lang)
              else
                set_dub_failed(s, seg, lang, 'Splice: ' .. tostring(sp_res.err))
                set_status(s, ('Splice %s err: %s'):format(seg_id, sp_res.err), 0xFF8888FF)
              end
              s.align_handles[seg_id] = nil
            end
          end
        else
          -- Forced align off — splice directly
          local sp_res = dubbing_splicer.splice_segment(s.project, seg, require('modules.dubbing_project').find_speaker(s.project, seg.speaker_id), lang, h.result, { regen = false })
          if sp_res.ok then
            seg.dub_status[lang] = 'generated'
            seg.item_guids[lang] = sp_res.item_guid
            mark_dirty(s)
            on_segment_dubbed(s, seg, lang)
          else
            set_dub_failed(s, seg, lang, 'Splice: ' .. tostring(sp_res.err))
            set_status(s, ('Splice %s err: %s'):format(seg_id, sp_res.err), 0xFF8888FF)
          end
        end
      end
      s.tts_handles[seg_id] = nil
    elseif h.status == 'error' then
      if h.http_code == 429 and (h.retries or 0) < MAX_429_RETRIES then
        h.retries = (h.retries or 0) + 1
        local delay = RETRY_BACKOFF_SECS[h.retries] or 4
        s.retry_at['tts_' .. seg_id] = util.now() + delay
        local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
        if seg then seg.dub_status[lang] = 'pending' end
        s.tts_handles[seg_id] = nil
        set_status(s, ('TTS rate-limited; retry %s in %.1fs'):format(seg_id, delay), 0xFFB060FF)
      else
        local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
        if seg then set_dub_failed(s, seg, lang, 'TTS: ' .. tostring(h.error or '?')) end
        s.tts_handles[seg_id] = nil
        set_status(s, ('TTS %s failed: %s'):format(seg_id, h.error or '?'), 0xFF8888FF)
      end
    end
  end

  -- Poll align handles
  for seg_id, h in pairs(s.align_handles) do
    if h.status == 'running' then forced_align.poll(h) end
    if h.status == 'running' then force_error_if_stale(h, ('Align %s'):format(seg_id)) end
    if h.status == 'done' then
      local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
      if seg and h.result then
        seg.dub_alignment[lang] = h.result
        cost_add_forced_align(s.project, (seg.t_end - seg.t_start) / 60)
        local audio_path = seg.dub_audio_paths and seg.dub_audio_paths[lang]
        if audio_path then
          local speaker = require('modules.dubbing_project').find_speaker(s.project, seg.speaker_id)
          local sp_res
          local fallback_reason = ''
          -- M3.6: try per-word splice if toggle ON + alignment + source_words present
          if cfg.get_dubbing_per_word_splice() then
            sp_res = dubbing_splicer.splice_segment_per_word(s.project, seg, speaker, lang, audio_path, h.result, { regen = false })
            if not sp_res.ok then
              fallback_reason = sp_res.err or 'unknown'
              set_status(s, ('Per-word splice %s fallback: %s'):format(seg_id, fallback_reason), 0xFFB060FF)
              sp_res = nil   -- trigger fallback below
            end
          else
            fallback_reason = 'toggle_off'
          end
          if not sp_res then
            sp_res = dubbing_splicer.splice_segment(s.project, seg, speaker, lang, audio_path,
              { regen = false, alignment = h.result })
          end
          if sp_res.ok then
            seg.dub_status[lang] = 'generated'
            seg.item_guids[lang] = sp_res.item_guid
            seg.dub_n_items[lang] = sp_res.n_items or 1
            if not seg.dub_per_word then seg.dub_per_word = {} end
            seg.dub_per_word[lang] = sp_res.per_word == true
            if not seg.dub_per_word_fallback_reason then seg.dub_per_word_fallback_reason = {} end
            seg.dub_per_word_fallback_reason[lang] = sp_res.per_word and '' or fallback_reason
            mark_dirty(s)
            on_segment_dubbed(s, seg, lang)
          else
            set_dub_failed(s, seg, lang, 'Splice: ' .. tostring(sp_res.err))
            set_status(s, ('Splice %s err: %s'):format(seg_id, sp_res.err), 0xFF8888FF)
          end
        end
      end
      s.align_handles[seg_id] = nil
    elseif h.status == 'error' then
      -- Align failure → fall back to splice without alignment
      local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
      local audio_path = seg and seg.dub_audio_paths and seg.dub_audio_paths[lang]
      if seg and audio_path then
        local sp_res = dubbing_splicer.splice_segment(s.project, seg, require('modules.dubbing_project').find_speaker(s.project, seg.speaker_id), lang, audio_path, { regen = false })
        if sp_res.ok then
          seg.dub_status[lang] = 'generated'
          seg.item_guids[lang] = sp_res.item_guid
          mark_dirty(s)
          on_segment_dubbed(s, seg, lang)
        else
          set_dub_failed(s, seg, lang,
            'Splice (after align error): ' .. tostring(sp_res.err))
        end
      end
      s.align_handles[seg_id] = nil
      set_status(s, ('Align %s err — fallback splice'):format(seg_id), 0xFFB060FF)
    end
  end

  -- Check if all done
  if s.generate_pending then
    local any_pending = false
    for _, seg in ipairs(s.project.segments) do
      local status = seg.translation_status and seg.translation_status[lang]
      local dub_status = seg.dub_status and seg.dub_status[lang]
      local text_ready = (status == 'translated' or status == 'stale')
                         and ((seg.translations and seg.translations[lang]) or '') ~= ''
      if text_ready and (dub_status == 'pending' or dub_status == 'stale' or dub_status == 'tts_running' or dub_status == 'align_running') then
        any_pending = true
        break
      end
    end
    if not any_pending then
      local any_active = next(s.tts_handles) ~= nil
      if not any_active then
        any_active = next(s.align_handles) ~= nil
      end
      if not any_active then
        s.generate_pending = false
        -- M4+ visibility: count per-word vs full-segment splices + breakdown
        -- fallback reasons.
        local n_pw, n_fs = 0, 0
        local fallback_reasons = {}    -- reason → count
        for _, seg in ipairs(s.project.segments) do
          if seg.dub_status and seg.dub_status[lang] == 'generated' then
            local is_pw = seg.dub_per_word and seg.dub_per_word[lang] == true
            if is_pw then
              n_pw = n_pw + 1
            else
              n_fs = n_fs + 1
              local r = seg.dub_per_word_fallback_reason and seg.dub_per_word_fallback_reason[lang] or ''
              if r ~= '' and r ~= 'toggle_off' then
                -- Strip detail z error message (np. "word_count_mismatch: src=3 tts=5 (>30%)"
                -- → "word_count_mismatch") for grouping.
                local short = r:match('^(.-):') or r
                fallback_reasons[short] = (fallback_reasons[short] or 0) + 1
              end
            end
          end
        end
        if cfg.get_dubbing_per_word_splice() and (n_pw > 0 or n_fs > 0) then
          local most_reason, most_count = nil, 0
          for r, c in pairs(fallback_reasons) do
            if c > most_count then most_reason = r; most_count = c end
          end
          if most_reason then
            set_status(s,
              ('Dub generation complete. Per-word: %d / full-segment: %d (most fallbacks: %s ×%d).')
                :format(n_pw, n_fs, most_reason, most_count),
              0x80E090FF)
          else
            set_status(s,
              ('Dub generation complete. Per-word: %d / full-segment: %d.'):format(n_pw, n_fs),
              0x80E090FF)
          end
        else
          set_status(s, 'Dub generation complete.', 0x80E090FF)
        end
      end
    end
  end
end

----------------------------------------------------------------------------
-- Public API: surface mode contract per NS-A
----------------------------------------------------------------------------
function M.render(ctx, state, deps)
  local s = init_state(state)
  try_restore(s)
  local panel = require 'modules.gui.dubbing_panel'
  panel.render(ctx, state, deps, M)
end

function M.render_modals(ctx, state, deps)
  local s = init_state(state)
  local panel = require 'modules.gui.dubbing_panel'
  if panel.render_modals then panel.render_modals(ctx, state, deps, M) end

  -- Speaker matching modal dispatch
  local speaker_match = require 'modules.gui.dubbing_speaker_match'
  if s.speaker_match_modal_pending_open then
    -- Compute source→project time offset (Flow A mixed_single).
    -- Chunks have t_start_in_src = source-file-relative time. REAPER timeline
    -- positions = source_item.D_POSITION + (source_time - D_STARTOFFS) / playrate.
    -- Per KNOWN-ISSUES we assume playrate=1.0 dla now.
    local project_offset = 0
    if s.project and s.project.source_kind == 'mixed_single' then
      local _, source_item = resolve_source_path_for_mixed(s.project)
      -- resolve returns (path, item) on success. Second return is item only on success.
      if source_item and type(source_item) == 'userdata' then
        local d_pos    = reaper.GetMediaItemInfo_Value(source_item, 'D_POSITION') or 0
        local take     = reaper.GetActiveTake(source_item)
        local d_startoffs = take and reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
        project_offset = d_pos - d_startoffs
      end
    end
    -- Build chunks_input dla modal: combine chunks_plan + chunks_results
    local chunks_input = {}
    for _, chunk in ipairs(s.chunks_plan or {}) do
      local transcript = s.chunks_results[chunk.idx]
      if transcript and not transcript.error then
        chunks_input[#chunks_input + 1] = {
          idx              = chunk.idx,
          t_start_in_src   = chunk.t_start_in_src,
          t_end_in_src     = chunk.t_end_in_src,
          project_offset   = project_offset,    -- M4 fix: source→project mapping
          audio_path       = chunk.output_path,
          transcript       = transcript,
        }
      end
    end
    speaker_match.open(chunks_input)
    s.speaker_match_modal_pending_open = false
    s._chunks_input_cache = chunks_input    -- preserve dla confirm callback
  end
  if speaker_match.is_open() then
    local action = speaker_match.render(ctx, state, M, deps)
    if action == 'confirm' then
      local ok_b, berr = speaker_match.build_segments_and_speakers(s.project, s._chunks_input_cache or {})
      if ok_b then
        s.phase = 'casting_voices'
        mark_dirty(s)
        set_status(s, ('Built %d segment(s) across %d speaker(s). Assign voices to start dubbing.')
          :format(#s.project.segments, #s.project.speakers), 0x80E090FF)
        s._chunks_input_cache = nil
      else
        set_status(s, ('Segment build failed: %s'):format(berr or '?'), 0xFF8888FF)
      end
    elseif action == 'cancel' then
      -- User cancelled — drop chunks data, return to idle for re-start
      s.phase = 'idle'
      s.chunks_plan = nil
      s.chunks_results = {}
      s._chunks_input_cache = nil
      set_status(s, 'Speaker matching cancelled.', 0xCCCCCCFF)
    end
  end

  -- M3.2: Similar-voices picker modal dispatch
  local similar_picker = require 'modules.gui.dubbing_similar_picker'
  if s.similar_modal_pending_speaker then
    local spk_id = s.similar_modal_pending_speaker
    local results = s.similar_results[spk_id]
    if results and type(results.voices) == 'table' then
      local spk = require('modules.dubbing_project').find_speaker(s.project, spk_id)
      similar_picker.open({
        speaker_id    = spk_id,
        speaker_label = spk and spk.label or spk_id,
        voices        = results.voices,
        total_count   = results.total_count or #results.voices,
        has_more      = results.has_more or false,
        top_k         = results.top_k or 10,
      })
    end
    s.similar_modal_pending_speaker = nil
  end
  if similar_picker.is_open() then
    local action = similar_picker.render(ctx)
    if action == 'select' then
      local sel = similar_picker.get_selection()
      local spk_id = similar_picker.get_speaker_id()
      if sel and spk_id then
        M.apply_voice_for_speaker(state, spk_id, sel.voice_id, sel.name)
      end
    elseif action == 'cancel' then
      -- Drop results so user has to re-fetch (they're transient)
      local spk_id = similar_picker.get_speaker_id()
      if spk_id then s.similar_results[spk_id] = nil end
    elseif action == 'load_more' then
      -- M4.3: re-spawn similar_voices z larger top_k, append to modal results
      local spk_id = similar_picker.get_speaker_id()
      local stored = s.similar_results[spk_id]
      local next_k = similar_picker.consume_load_more_request()
      if spk_id and stored and stored.audio_path and next_k and not s.similar_more_handles[spk_id] then
        -- BUG fix (2026-06-10, audit M0-2): voice_admin był undefined w tym
        -- scope (require'owany lokalnie w innych funkcjach) → "Load more"
        -- crashował z attempt-to-index-nil. Wykryte przez luacheck gate.
        local voice_admin = require 'modules.voice_admin'
        local h = voice_admin.spawn_similar_voices(stored.audio_path, { top_k = next_k })
        if h.status == 'error' then
          set_status(s, ('Load more err: %s'):format(h.error or '?'), 0xFF8888FF)
        else
          h.speaker_id = spk_id
          s.similar_more_handles[spk_id] = h
        end
      end
    end
  end

  -- M4.1: Voice Design modal dispatch (self-managing — opened przez Cast sidebar)
  local voice_design_modal = require 'modules.gui.dubbing_voice_design'
  if voice_design_modal.is_open() then
    voice_design_modal.render(ctx, state, M)
  end

  -- M4+: Voice settings modal dispatch (callback-based, opened przez Cast sidebar / Inspector)
  local voice_settings_modal = require 'modules.gui.dubbing_voice_settings'
  if voice_settings_modal.is_open() then
    voice_settings_modal.render(ctx)
  end

  -- M3.3-M3.5: Inspector modal dispatch
  local inspector = require 'modules.gui.dubbing_inspector'
  if s.inspector_pending_seg_id then
    inspector.open(s.inspector_pending_seg_id)
    s.inspector_pending_seg_id = nil
  end
  if inspector.is_open() then
    local action = inspector.render(ctx, state, M)
    if action == 'preview' then
      M.request_segment_preview(state, inspector.get_seg_id())
    elseif action == 'regen_1' then
      M.request_regen_segment(state, inspector.get_seg_id(), 1)
    elseif action == 'variants' then
      M.request_regen_segment(state, inspector.get_seg_id(), inspector.get_variant_count() or 3)
    elseif action == 'cancel_regen' then
      M.cancel_regen_segment(state, inspector.get_seg_id())
    end
  end

  -- Glossary modal dispatch
  local glossary_modal = require 'modules.gui.dubbing_glossary'
  if s.glossary_modal_pending_open then
    glossary_modal.open(s.project)
    s.glossary_modal_pending_open = false
  end
  if glossary_modal.is_open() then
    local action = glossary_modal.render(ctx, state, M, deps)
    if action == 'save' then
      mark_dirty(s)
      -- Cascade stale across ALL languages (glossary changes affect translations in every lang).
      if s.project then propagate_stale(s.project, 'all_langs') end
      set_status(s, 'Glossary saved. Translations + dubs marked stale across all languages.', 0xFFB060FF)
    elseif action == 'save_nochange' then
      -- W2 M1: Save bez zmian = no-op (zero stale, neutralny komunikat —
      -- pre-fix każde otwarcie+Save straszyło pełnym re-translate).
      set_status(s, 'Glossary unchanged — translations untouched.', 0xCCCCCCFF)
    end
  end
end

----------------------------------------------------------------------------
-- M3.7: REAPER selection sync — if user clicks dub item w arrange view,
-- extract its dub_segment_id z P_EXT i ustaw s.selected_segment_id.
----------------------------------------------------------------------------
local function sync_selection_from_reaper(s)
  if not s.project then return end
  -- Panel click sets panel_selection_just_set for ONE frame. Skip sync so we
  -- don't overwrite the panel's authoritative selection within the same defer
  -- cycle (REAPER selection may include other items beyond what panel set).
  if s.panel_selection_just_set then
    s.panel_selection_just_set = false
    return
  end
  -- Build fresh set from REAPER selection (multi-select aware per M4.2).
  local n_sel = reaper.CountSelectedMediaItems(0)
  if n_sel == 0 then
    -- Empty REAPER selection — preserve panel selection (user might still
    -- want highlighted row even though arrange has nothing selected).
    return
  end
  local new_set = {}
  local first_seg = nil
  for i = 0, n_sel - 1 do
    local it = reaper.GetSelectedMediaItem(0, i)
    if it then
      local _, is_dub = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:Reasonate.is_dub_output', '', false)
      if is_dub == '1' then
        local _, seg_id = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:Reasonate.dub_segment_id', '', false)
        if seg_id and seg_id ~= '' then
          new_set[seg_id] = true
          if not first_seg then first_seg = seg_id end
        end
      end
    end
  end
  if next(new_set) ~= nil then
    s.selected_segment_ids = new_set
    -- Primary single = first found (used by inspector context or single-seg ops)
    s.selected_segment_id = first_seg
  end
end

----------------------------------------------------------------------------
-- W3 Pakiet B+ (2026-06-10, user request): playhead → transcript sync.
-- Klik w miejsce na timeline (lub odtwarzanie) podświetla i przewija tabelę
-- segmentów do segmentu pod kursorem — szybka orientacja "gdzie jestem".
-- Oś czasu: seg.t_start/t_end ≈ project time (ta sama konwencja co
-- dubbing_splicer D_POSITION i reveal_segment_in_reaper fallback).
-- Scroll TYLKO przy zmianie segmentu — ręczne przewijanie tabeli nie jest
-- nadpisywane w kółko; w przerwach między segmentami zostaje ostatni tint.
----------------------------------------------------------------------------
local function sync_playhead_segment(s)
  if not s.project or not s.project.segments or #s.project.segments == 0 then
    s.playhead_segment_id = nil
    return
  end
  local play_state = reaper.GetPlayState() or 0
  local t
  if (play_state & 1) == 1 then
    t = reaper.GetPlayPosition()
  else
    t = reaper.GetCursorPosition()
  end
  if not t then return end
  if s.last_playhead_t and math.abs(t - s.last_playhead_t) < 0.01 then return end
  s.last_playhead_t = t
  for _, seg in ipairs(s.project.segments) do
    local t0, t1 = tonumber(seg.t_start), tonumber(seg.t_end)
    if t0 and t1 and t >= t0 and t <= t1 then
      if seg.id ~= s.playhead_segment_id then
        s.playhead_segment_id     = seg.id
        s.playhead_scroll_pending = true
      end
      return
    end
  end
end

-- Forward declaration — run_regen_pump body defined later (uses voice_admin /
-- dubbing_splicer / dub_project requires which live higher in the file).
-- Per KNOWN-ISSUES "Lua lexical scoping": consume_signals NEEDS to see this
-- upvalue at compile time, even though function body is defined below.
local run_regen_pump

function M.consume_signals(state, deps)
  local s = init_state(state)
  try_restore(s)
  sync_selection_from_reaper(s)
  sync_playhead_segment(s)
  reconcile_with_reaper(s)   -- detect user-deleted dub items (2s debounce)

  local llm           = require 'modules.llm'
  local voice_admin   = require 'modules.voice_admin'
  local forced_align  = require 'modules.forced_align'
  local stt           = require 'modules.stt'
  local voice_isolator = require 'modules.voice_isolator'

  -- M4-3: pompa kasowania klonów — sekwencyjnie, NIEZALEŻNIE od projektu
  -- (kolejka zasiana przy Close/Delete żyje po close_project).
  if s.clone_delete_handle then
    local dh = s.clone_delete_handle
    if dh.status == 'running' then voice_admin.poll(dh) end
    if dh.status == 'running' then force_error_if_stale(dh, 'Clone delete') end
    if dh.status ~= 'running' then
      if dh.status == 'error' then
        set_status(s, ('Clone delete failed: %s'):format(dh.error or '?'), 0xFFB060FF)
      end
      s.clone_delete_handle = nil
    end
  end
  if not s.clone_delete_handle and #s.clone_delete_queue > 0 then
    local nxt = table.remove(s.clone_delete_queue, 1)
    local dh = voice_admin.spawn_delete(nxt)
    if dh.status ~= 'error' then
      s.clone_delete_handle = dh
    else
      set_status(s, ('Clone delete failed: %s'):format(dh.error or '?'), 0xFFB060FF)
    end
  end

  -- Clone (IVC) handles — independent of pipeline phase, can run any time
  for spk_id, h in pairs(s.clone_handles) do
    if h.status == 'running' then voice_admin.poll(h) end
    if h.status == 'running' then force_error_if_stale(h, ('Clone %s'):format(spk_id)) end
    if h.status == 'done' then
      local speaker = require('modules.dubbing_project').find_speaker(s.project, spk_id)
      if speaker and h.result then
        -- M4-3: rejestr klonów utworzonych przez TEN projekt — modal
        -- sprzątania przy Close/Delete (klony nigdy nie były kasowane →
        -- zapchane voice sloty konta). Persist z projektem (mark_dirty niżej).
        s.project.created_clone_ids = s.project.created_clone_ids or {}
        s.project.created_clone_ids[#s.project.created_clone_ids + 1] = {
          voice_id = h.result,
          name     = (h.args and h.args.name) or 'Clone',
        }
        -- W2 M3 cz.2: klon identyfikuje OSOBĘ (lang-independent) — trafia
        -- do Cast Registry przez sync_from_dubbing na flushu (konsumenci:
        -- propozycja głosu w Repair, Match cast).
        speaker.ivc_clone_id = h.result
        local lang = s.project.active_target_language
        if lang then
          local prev_voice_id = speaker.voices and speaker.voices[lang]
          speaker.voices[lang] = h.result   -- voice_id
          speaker.voice_names[lang] = h.args and h.args.name or 'Clone'
          -- Voice changed → invalidate existing dubs dla tego speakera
          if prev_voice_id and prev_voice_id ~= h.result then
            local n = propagate_speaker_stale(s.project, spk_id, lang, 'dub_only') or 0
            if n > 0 then
              set_status(s,
                ('Voice cloned for %s · %d existing dub(s) marked stale. Click Generate dub.'):format(
                  speaker.label or spk_id, n), 0xFFB060FF)
            else
              set_status(s, ('Voice cloned for %s'):format(speaker.label or spk_id), 0x80E090FF)
            end
          else
            set_status(s, ('Voice cloned for %s'):format(speaker.label or spk_id), 0x80E090FF)
          end
        end
        mark_dirty(s)
      end
      s.clone_handles[spk_id] = nil
    elseif h.status == 'error' then
      s.clone_handles[spk_id] = nil
      -- M4-3: limit slotów głosów = najczęstsza terminalna przyczyna po
      -- wielu projektach dubbingu — powiedz co zrobić zamiast surowego 400.
      local emsg = tostring(h.error or '?')
      if emsg:find('voice_limit') or emsg:find('voice_add_edit_limit')
          or emsg:find('maximum amount of custom voices') then
        local st = require 'modules.state'
        local slots = ''
        if st.quota_voice_slots_used and st.quota_voice_limit then
          slots = (' (%d/%d slots used)'):format(
            st.quota_voice_slots_used, st.quota_voice_limit)
        end
        emsg = emsg .. (' — voice slot limit reached%s: delete unused clones in Voice Manager.'):format(slots)
      end
      set_status(s, ('Clone %s failed: %s'):format(spk_id, emsg), 0xFF8888FF)
    end
  end

  -- M3.2: Similar-voices handles → store results, open modal
  for spk_id, h in pairs(s.similar_handles) do
    if h.status == 'running' then voice_admin.poll(h) end
    if h.status == 'running' then force_error_if_stale(h, ('Similar %s'):format(spk_id)) end
    if h.status == 'done' then
      if h.result and type(h.result.voices) == 'table' then
        s.similar_results[spk_id] = {
          voices      = h.result.voices,
          has_more    = h.result.has_more or false,
          total_count = h.result.total_count or #h.result.voices,
          audio_path  = h.args and h.args.audio_path,    -- M4.3 preserved dla load_more
          top_k       = (h.args and h.args.top_k) or 10,
        }
        s.similar_modal_pending_speaker = spk_id
        local n = #h.result.voices
        set_status(s, ('Found %d similar voice(s) for %s'):format(n, spk_id), 0x80E090FF)
      end
      s.similar_handles[spk_id] = nil
    elseif h.status == 'error' then
      s.similar_handles[spk_id] = nil
      set_status(s, ('Similar-voices %s failed: %s'):format(spk_id, h.error or '?'), 0xFF8888FF)
    end
  end

  -- M4.3: Similar-voices load_more handles → append do existing modal results
  local similar_picker_for_more = require 'modules.gui.dubbing_similar_picker'
  for spk_id, h in pairs(s.similar_more_handles) do
    if h.status == 'running' then voice_admin.poll(h) end
    if h.status == 'running' then force_error_if_stale(h, ('Similar more %s'):format(spk_id)) end
    if h.status == 'done' then
      if h.result and type(h.result.voices) == 'table' then
        -- Update stored results
        local stored = s.similar_results[spk_id] or {}
        local existing_ids = {}
        for _, v in ipairs(stored.voices or {}) do existing_ids[v.voice_id] = true end
        for _, v in ipairs(h.result.voices) do
          if v.voice_id and not existing_ids[v.voice_id] then
            stored.voices[#stored.voices + 1] = v
            existing_ids[v.voice_id] = true
          end
        end
        stored.has_more = h.result.has_more or false
        stored.total_count = math.max(stored.total_count or 0, h.result.total_count or 0)
        stored.top_k = (h.args and h.args.top_k) or stored.top_k
        s.similar_results[spk_id] = stored
        -- Push do modal jeśli ten speaker jest open
        if similar_picker_for_more.is_open() and similar_picker_for_more.get_speaker_id() == spk_id then
          similar_picker_for_more.append_voices(h.result.voices, stored.has_more, stored.total_count, stored.top_k)
        end
      end
      s.similar_more_handles[spk_id] = nil
    elseif h.status == 'error' then
      s.similar_more_handles[spk_id] = nil
      set_status(s, ('Load more failed: %s'):format(h.error or '?'), 0xFF8888FF)
    end
  end

  -- Phase-specific orchestration
  if s.phase == 'starting' then
    begin_pipeline(state, s)
  elseif s.phase == 'isolating' then
    if s.isolator_handle then
      if s.isolator_handle.status == 'running' then voice_isolator.poll(s.isolator_handle) end
      -- M2-1: martwy worker izolatora = wieczny spinner; stale → error →
      -- istniejąca ścieżka błędu kontynuuje pipeline z surowym audio.
      if s.isolator_handle.status == 'running' then
        force_error_if_stale(s.isolator_handle, 'Voice Isolator')
      end
      if s.isolator_handle.status == 'done' then
        s.isolated_audio_path = s.isolator_handle.result
        s.isolator_handle = nil
        set_status(s, 'Voice Isolator done. Chunking source...', 0xCCCCCCFF)
        s.phase = 'chunking'
      elseif s.isolator_handle.status == 'error' then
        set_status(s, ('Isolator failed: %s'):format(s.isolator_handle.error or '?'), 0xFFB060FF)
        s.isolator_handle = nil
        s.phase = 'chunking'   -- continue z raw audio
      end
    end
  elseif s.phase == 'chunking' then
    run_chunking_phase(state, s)
  elseif s.phase == 'transcribing' then
    if s.project and s.project.source_kind == 'multi_track' then
      run_transcribing_pump_flow_b(state, s)
    else
      run_transcribing_pump(state, s)
    end
  elseif s.phase == 'casting_voices' then
    -- Idle; sidebar handles voice picker
    -- Transition to 'ready' gdy all speakers mają voice dla active_lang
    if s.project then
      local lang = s.project.active_target_language
      local all_ready = #s.project.speakers > 0
      for _, spk in ipairs(s.project.speakers) do
        if not spk.voices or not spk.voices[lang] or spk.voices[lang] == '' then
          all_ready = false; break
        end
      end
      if all_ready then s.phase = 'ready' end
    end
  end

  -- Translate + Generate pumps (run independent of pipeline phase, gated on
  -- 'ready' phase + project.segments existing).
  if s.project and #s.project.segments > 0
     and (s.phase == 'ready' or s.phase == 'casting_voices') then
    run_translate_pump(state, s)
    run_generate_dub_pump(state, s)
    run_regen_pump(state, s)
  end

  -- W2 M3 cz.2: propozycje Match cast (throttle 2s w środku) — tylko w
  -- fazach, w których sidebar castu jest aktywny.
  if s.project and (s.phase == 'ready' or s.phase == 'casting_voices') then
    refresh_match_cast(s)
  end

  -- T2 (UX-POLISH): preview tłumaczenia — poll → play_file. Świeży render
  -- = realny płatny request → uczciwie do cost_trackera; Generate po
  -- odsłuchu trafia w ten sam cache (identyczne opts + seed) = zero
  -- podwójnego billingu.
  if s.preview_handle then
    local h = s.preview_handle
    if h.status == 'running' then voice_admin.poll(h) end
    if h.status == 'running' then force_error_if_stale(h, 'Translation preview') end
    if h.status == 'done' then
      s.preview_handle = nil
      if h.result then
        local lang = s.project and s.project.active_target_language
        if h.from_cache then
          if s.project and s.project.cost_tracker then
            s.project.cost_tracker.tts_cache_hits =
              (s.project.cost_tracker.tts_cache_hits or 0) + 1
          end
        elseif s.project and lang then
          local seg = require('modules.dubbing_project').find_segment(s.project, h.seg_id)
          local chars = seg and util.utf8_len((seg.translations and seg.translations[lang]) or '') or 0
          if chars > 0 then
            cost_add_tts(s.project, chars, s.project.tts_model)
            mark_dirty(s)
          end
        end
        require('modules.preview').play_file(h.result, 'dub_prev_' .. tostring(h.seg_id))
        set_status(s, h.from_cache and 'Playing translation preview (cached)'
                                    or 'Playing translation preview', 0x80E090FF)
      end
    elseif h.status == 'error' then
      s.preview_handle = nil
      set_status(s, 'Preview failed: ' .. tostring(h.error or '?'), 0xFF8888FF)
    end
  end

  -- Debounced save. W2 M3.1: realny flush = jedyny hook sync rejestru
  -- postaci (każda mutacja głosów/glossary idzie przez mark_dirty → flush;
  -- pcall — registry to polish, nigdy nie blokuje pętli). W2 M3 cz.2:
  -- geom_key źródła → marker links.materials na postaciach.
  if dubbing_state.flush_if_needed() and s.project then
    pcall(function()
      require('modules.cast_registry').sync_from_dubbing(s.project,
        { geom_key = source_geom_key(s) })
    end)
  end
end

function M.shutdown(state)
  local s = init_state(state)
  if dubbing_state.flush_now() and s.project then
    pcall(function()
      require('modules.cast_registry').sync_from_dubbing(s.project,
        { geom_key = source_geom_key(s) })
    end)
  end
end

----------------------------------------------------------------------------
-- Mutation API (called z dubbing_panel)
----------------------------------------------------------------------------
function M.mark_dirty(state)
  local s = init_state(state)
  mark_dirty(s)
end

-- T2 (UX-POLISH): odsłuch tłumaczenia PRZED wstawieniem. Ten sam request
-- co Generate (build_dub_tts_opts — wspólny cache + deterministyczny
-- seed), więc Generate po odsłuchu = cache hit. Jeden preview naraz.
-- Kliknięcie w trakcie odtwarzania = stop.
function M.request_segment_preview(state, seg_id)
  local s = init_state(state)
  if s.preview_handle then return end
  local prev = require 'modules.preview'
  if prev.is_playing('dub_prev_' .. tostring(seg_id)) then
    prev.stop()
    return
  end
  local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
  local lang = s.project and s.project.active_target_language
  if not seg or not lang then return end
  local opts, oerr = build_dub_tts_opts(s, seg, lang)
  if not opts then
    set_status(s, 'Preview: ' .. tostring(oerr), 0xFFB060FF)
    return
  end
  local h = require('modules.voice_admin').spawn_tts(opts)
  if h.status == 'error' then
    set_status(s, 'Preview TTS: ' .. tostring(h.error or '?'), 0xFF8888FF)
    return
  end
  h.seg_id = seg_id
  s.preview_handle = h
  set_status(s, 'Rendering translation preview…', 0xB0B0B0FF)
end

function M.is_segment_previewing(state, seg_id)
  local s = init_state(state)
  if s.preview_handle and (seg_id == nil or s.preview_handle.seg_id == seg_id) then
    return true
  end
  if seg_id ~= nil then
    return require('modules.preview').is_playing('dub_prev_' .. tostring(seg_id))
  end
  return false
end

-- W2 M3 cz.2: Match cast — panel czyta propozycje (nil = brak / faza off).
function M.match_cast_rows(state)
  local s = init_state(state)
  return s.match_cast_rows
end

-- Aplikuje zaznaczone wiersze modala Match cast (rows = subset propozycji).
-- Zmiana głosu na mówcy z istniejącym INNYM głosem → stale dubów tego
-- mówcy (mirror clone-done). Zwraca liczbę zaaplikowanych.
function M.apply_match_cast(state, rows)
  local s = init_state(state)
  local p = s.project
  local lang = p and p.active_target_language
  if not lang or type(rows) ~= 'table' then return 0 end
  local dub_project = require 'modules.dubbing_project'
  local applied, stale_n = 0, 0
  for _, r in ipairs(rows) do
    local spk = dub_project.find_speaker(p, r.speaker_id)
    if spk and type(r.voice_id) == 'string' and r.voice_id ~= '' then
      local prev = spk.voices and spk.voices[lang]
      if prev ~= r.voice_id then
        spk.voices[lang]      = r.voice_id
        spk.voice_names[lang] = r.voice_name or ''
        applied = applied + 1
        if prev and prev ~= '' then
          stale_n = stale_n
            + (propagate_speaker_stale(p, spk.id, lang, 'dub_only') or 0)
        end
      end
    end
  end
  if applied > 0 then
    mark_dirty(s)
    s.match_cast_checked_at = nil   -- natychmiastowy refresh listy propozycji
    if stale_n > 0 then
      set_status(s,
        ('Cast matched: %d voice(s) applied · %d existing dub(s) marked stale. Click Generate dub.')
          :format(applied, stale_n), 0xFFB060FF)
    else
      set_status(s,
        ('Cast matched: %d voice(s) applied from the project cast registry.')
          :format(applied), 0x80E090FF)
    end
  end
  return applied
end

function M.start_project(state, opts)
  local s = init_state(state)
  local project, err = dubbing_project.new_project(opts)
  if not project then return nil, err end
  s.project = project
  s.phase   = 'starting'
  s.chunks_plan = nil
  s.chunks_results = {}
  s.translate_handles = {}
  s.tts_handles = {}
  s.align_handles = {}
  s.chunk_handles = {}
  s.clone_handles = {}
  s.translate_pending = false
  s.generate_pending = false
  s.isolator_handle = nil
  s.isolated_audio_path = nil
  s.retry_at = {}
  s.flow_b_items_pending = {}
  s.flow_b_item_handles  = {}
  s.flow_b_item_results  = {}
  s.similar_handles = {}
  s.similar_results = {}
  s.similar_more_handles = {}
  s.last_run_error = nil
  mark_dirty(s)
  dubbing_state.save(project)
  return project, nil
end

----------------------------------------------------------------------------
-- M4-3: sprzątanie klonów IVC przy Close/Delete projektu (DECYZJA
-- 2026-07-02: modal z listą, default Delete; NIGDY po cichu; wykluczone =
-- klony w Cast Registry lub przypisane jako track voice — sekcja Keep).
----------------------------------------------------------------------------
function M.collect_deletable_clones(state)
  local s = init_state(state)
  local deletable, kept = {}, {}
  local project = s.project
  if not project or type(project.created_clone_ids) ~= 'table'
     or #project.created_clone_ids == 0 then
    return deletable, kept
  end
  local protected = {}
  do
    local cast_registry = require 'modules.cast_registry'
    local okr, registry = pcall(cast_registry.load)
    if okr and registry then
      for _, ch in ipairs(cast_registry.characters(registry) or {}) do
        for _, v in pairs(ch.voices or {}) do
          local vid = (type(v) == 'table' and v.voice_id) or v
          if type(vid) == 'string' and vid ~= '' then
            protected[vid] = 'Cast Registry'
          end
        end
      end
    end
  end
  do
    local helpers = require 'modules.reaper_helpers'
    for i = 0, reaper.CountTracks(0) - 1 do
      local tr = reaper.GetTrack(0, i)
      if tr then
        local vid = helpers.get_track_voice(tr)
        if vid then protected[vid] = protected[vid] or 'track voice' end
        local clone = helpers.get_track_voice_clone(tr)
        if clone and clone.voice_id and clone.voice_id ~= '' then
          protected[clone.voice_id] = protected[clone.voice_id] or 'track clone'
        end
      end
    end
  end
  local seen = {}
  for _, c in ipairs(project.created_clone_ids) do
    local vid  = (type(c) == 'table' and c.voice_id) or c
    local name = (type(c) == 'table' and c.name) or nil
    if type(vid) == 'string' and vid ~= '' and not seen[vid] then
      seen[vid] = true
      local entry = { voice_id = vid, name = name or vid }
      if protected[vid] then
        entry.kept_reason = protected[vid]
        kept[#kept + 1] = entry
      else
        deletable[#deletable + 1] = entry
      end
    end
  end
  return deletable, kept
end

function M.delete_clones(state, list)
  local s = init_state(state)
  for _, c in ipairs(list or {}) do
    local vid = (type(c) == 'table' and c.voice_id) or c
    if type(vid) == 'string' and vid ~= '' then
      s.clone_delete_queue[#s.clone_delete_queue + 1] = vid
    end
  end
  if #s.clone_delete_queue > 0 then
    set_status(s, ('Deleting %d cloned voice(s) in background…')
      :format(#s.clone_delete_queue), 0xCCCCCCFF)
  end
end

function M.close_project(state)
  local s = init_state(state)
  s.project = nil
  s.phase = 'idle'
  s.translate_handles = {}
  s.tts_handles       = {}
  s.align_handles     = {}
  s.clone_handles     = {}
  s.chunk_handles     = {}
  s.chunks_plan = nil
  s.chunks_results = {}
  s.isolator_handle = nil
  s.isolated_audio_path = nil
  s.translate_pending = false
  s.generate_pending = false
  s.retry_at = {}
  s.status_msg        = ''
  s.flow_b_items_pending = {}
  s.flow_b_item_handles  = {}
  s.flow_b_item_results  = {}
  s.similar_handles = {}
  s.similar_results = {}
  s.similar_more_handles = {}
end

function M.active_target_lang(state)
  local s = init_state(state)
  if not s.project then return nil end
  return s.project.active_target_language
end

function M.set_active_target_lang(state, lang)
  local s = init_state(state)
  if not s.project then return false end
  for _, l in ipairs(s.project.target_languages) do
    if l == lang then
      s.project.active_target_language = lang
      mark_dirty(s)
      return true
    end
  end
  return false
end

function M.set_status(state, msg, color)
  local s = init_state(state)
  set_status(s, msg, color)
end

-- M2.3 + M4: cascade stale propagation. scope = 'all_langs' (default) or lang.
-- kind = 'all' (translations+dubs, context/glossary/style edits) or 'dub_only'
-- (only dubs, voice/voice_settings changes — translation text remains valid).
function M.propagate_stale(state, scope, kind)
  local s = init_state(state)
  if s.project then propagate_stale(s.project, scope, kind) end
  mark_dirty(s)
end

-- Per-segment cascade. kind same semantics.
function M.propagate_segment_stale(state, seg, lang, kind)
  local s = init_state(state)
  if s.project then propagate_segment_stale(s.project, seg, lang, kind) end
  mark_dirty(s)
end

-- W3 quick win (2026-06-10): czy segment jest wstrzymany przez context-gate
-- (czeka aż poprzednie segmenty się przetłumaczą)? Panel renderuje wtedy
-- 'WAITING' zamiast mylącego 'pending' (wyglądało na zamrożone — audyt W3).
function M.is_segment_context_gated(state, seg_index, lang)
  local s = init_state(state)
  if not s.project or not s.translate_pending then return false end
  if not cfg.get_dubbing_translate_context_enabled() then return false end
  local seg = s.project.segments[seg_index]
  if not seg or seg.dub_excluded then return false end
  local st = seg.translation_status and seg.translation_status[lang]
  if st ~= 'pending' and st ~= 'stale' then return false end
  return not prev_translations_ready(s.project.segments, seg_index, lang)
end

-- Per-speaker cascade — flips generated→stale dla segmentów tego speakera
-- (active lang). Used przy zmianach voice_id (clone / pick / similar / design).
function M.propagate_speaker_stale(state, speaker_id, lang, kind)
  local s = init_state(state)
  if s.project then
    local n = propagate_speaker_stale(s.project, speaker_id, lang, kind)
    mark_dirty(s)
    return n or 0
  end
  return 0
end

----------------------------------------------------------------------------
-- M2.5: Cost estimation for upcoming Generate-dub run.
-- Returns { est_usd, est_chars, n_pending } dla pending+stale segments
-- na active target language. Used by panel for tier alerts + confirm dialog.
----------------------------------------------------------------------------
function M.estimate_pending_generate_cost(state)
  local s = init_state(state)
  if not s.project then return { est_usd = 0, est_chars = 0, n_pending = 0 } end
  local lang = s.project.active_target_language
  if not lang then return { est_usd = 0, est_chars = 0, n_pending = 0 } end

  local tts_rate = 0.00022   -- default Multilingual v2
  if s.project.tts_model == 'eleven_flash_v2_5' then tts_rate = 0.00011 end

  local total_chars = 0
  local n_pending = 0
  for _, seg in ipairs(s.project.segments or {}) do
    if not seg.dub_excluded then
      local trans_status = seg.translation_status and seg.translation_status[lang]
      local dub_status   = seg.dub_status and seg.dub_status[lang]
      if (dub_status == 'pending' or dub_status == 'stale') then
        local text = (seg.translations and seg.translations[lang]) or ''
        if text == '' then
          text = seg.source_text or ''
          total_chars = total_chars + math.floor(util.utf8_len(text) * 1.1)
        else
          total_chars = total_chars + util.utf8_len(text)
        end
        n_pending = n_pending + 1
      end
    end
  end

  local tts_cost = total_chars * tts_rate
  -- LLM cost rough: $0.005 per pending-translation segment (skip excluded)
  local llm_pending = 0
  for _, seg in ipairs(s.project.segments or {}) do
    if not seg.dub_excluded then
      local ts = seg.translation_status and seg.translation_status[lang]
      local ds = seg.dub_status and seg.dub_status[lang]
      if (ds == 'pending' or ds == 'stale') and (ts == 'pending' or ts == 'stale') then
        llm_pending = llm_pending + 1
      end
    end
  end
  local llm_cost = llm_pending * 0.005

  return {
    est_usd   = tts_cost + llm_cost,
    est_chars = total_chars,
    n_pending = n_pending,
  }
end

----------------------------------------------------------------------------
-- User actions (called from buttons)
----------------------------------------------------------------------------
function M.request_translate_all(state)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  if #s.project.segments == 0 then return false, 'no segments to translate' end
  local lang = s.project.active_target_language
  if not lang then return false, 'no active target language' end
  -- Mark all pending/stale as fresh for re-translation; preserve translated
  local llm = require 'modules.llm'
  if not llm.effective_provider() then
    return false, 'no LLM provider configured — open Settings → AI tab'
  end
  -- M1-4b: failed segments wracają do gry przy user-driven Translate all
  -- (terminal 'failed' nie matchuje warunku spawnu pompy — celowo).
  for _, seg in ipairs(s.project.segments) do
    if seg.translation_status and seg.translation_status[lang] == 'failed' then
      seg.translation_status[lang] = 'pending'
    end
  end
  s.translate_pending = true
  set_status(s, 'Translating segments...', 0xCCCCCCFF)
  return true
end

function M.request_generate_dub(state)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  if #s.project.segments == 0 then return false, 'no segments to dub' end
  local lang = s.project.active_target_language
  if not lang then return false, 'no active target language' end
  -- M4 fix: validate "any non-empty translation text" — stale translations
  -- nadal mają usable text (user dropped context but kept text). Earlier check
  -- required status='translated' which blocked Generate after propagate_stale.
  local any_with_text = false
  for _, seg in ipairs(s.project.segments) do
    local text = seg.translations and seg.translations[lang]
    if text and text ~= '' then
      any_with_text = true; break
    end
  end
  if not any_with_text then
    return false, 'no translated text — run Translate all first'
  end
  -- Validate all speakers have voices
  for _, spk in ipairs(s.project.speakers) do
    if not spk.voices or not spk.voices[lang] or spk.voices[lang] == '' then
      return false, ('Speaker %s has no voice for %s'):format(spk.label or spk.id, lang:upper())
    end
  end
  -- W3 Pakiet B+ (mirror M1-4b translate): terminal 'failed' wraca do gry
  -- przy user-driven Generate dub / chip [Retry] — reset do 'pending' żeby
  -- pompa podniosła segmenty w next tick.
  for _, seg in ipairs(s.project.segments) do
    if seg.dub_status and seg.dub_status[lang] == 'failed' then
      seg.dub_status[lang] = 'pending'
    end
  end
  s.generate_pending = true
  set_status(s, 'Generating dubs...', 0xCCCCCCFF)
  return true
end

function M.cancel_translate(state)
  local s = init_state(state)
  s.translate_pending = false
  -- In-flight handles let finish (per invariant #7 cancel = wait not kill)
  set_status(s, 'Translate cancelled (in-flight finish naturally).', 0xCCCCCCFF)
end

function M.cancel_generate(state)
  local s = init_state(state)
  s.generate_pending = false
  set_status(s, 'Dub generation cancelled (in-flight finish naturally).', 0xCCCCCCFF)
end

----------------------------------------------------------------------------
-- Polish #3 (PM5): Force re-translate ALL. Flips wszystkie 'translated' do
-- 'stale' → standard translate pump picks them up + regeneruje z bieżącym
-- kontekstem/glossary/LLM provider. Dub status preserved (audio side not
-- invalidated — user może osobno kliknąć Generate dub jeśli chce).
----------------------------------------------------------------------------
function M.force_retranslate_all(state)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local lang = s.project.active_target_language
  if not lang then return false, 'no active target language' end
  if #s.project.segments == 0 then return false, 'no segments' end
  local n_flipped = 0
  for _, seg in ipairs(s.project.segments) do
    if not seg.dub_excluded and seg.translation_status
       and seg.translation_status[lang] == 'translated' then
      seg.translation_status[lang] = 'stale'
      n_flipped = n_flipped + 1
    end
  end
  s.translate_pending = true
  mark_dirty(s)
  set_status(s, ('Force re-translate: %d segment(s) marked stale. Translating fresh...')
    :format(n_flipped), 0xCCCCCCFF)
  return true
end

----------------------------------------------------------------------------
-- M4+ Force re-generate ALL dubs. Flips wszystkie generated segs do 'stale'
-- → standard generate pump picks them up. Translation NIE invalidowane
-- (re-gen tylko audio side). Cleanup propagates via splicer
-- delete_all_existing_dub_items.
----------------------------------------------------------------------------
function M.force_regen_all_dubs(state)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local lang = s.project.active_target_language
  if not lang then return false, 'no active target language' end
  if #s.project.segments == 0 then return false, 'no segments' end
  -- Validate at least one z text (otherwise Generate pump will reject anyway)
  local any_text = false
  for _, seg in ipairs(s.project.segments) do
    local t = seg.translations and seg.translations[lang]
    if t and t ~= '' then any_text = true; break end
  end
  if not any_text then return false, 'no translated text — run Translate all first' end
  -- Flip generated → stale (preserves pending/translated/in-flight states).
  -- Skip excluded segments — user marked them out of dub.
  -- W2 M1: bump take_n per segment — "fresh dubs" obiecane w confirmie
  -- wymaga NOWEGO seeda (deterministyczny seed bez bumpa = cache hit =
  -- identyczna kopia zamiast świeżej interpretacji).
  local n_flipped = 0
  for _, seg in ipairs(s.project.segments) do
    if not seg.dub_excluded and seg.dub_status and seg.dub_status[lang] == 'generated' then
      seg.dub_status[lang] = 'stale'
      bump_dub_take(seg, lang)
      n_flipped = n_flipped + 1
    end
  end
  -- Mark REAPER items cyan (skip excluded)
  for _, seg in ipairs(s.project.segments) do
    if not seg.dub_excluded then
      local item_guid = seg.item_guids and seg.item_guids[lang]
      if item_guid and item_guid ~= '' then
        local item = find_item_by_guid(item_guid)
        if item then require('modules.dubbing_splicer').mark_item_stale(item) end
      end
    end
  end
  s.generate_pending = true
  mark_dirty(s)
  set_status(s, ('Force re-gen: %d segment(s) marked stale. Generating fresh dubs...')
    :format(n_flipped), 0xCCCCCCFF)
  return true
end

----------------------------------------------------------------------------
-- M.retry_pipeline — re-run STT pipeline z idle/ready state (after failure or
-- when restored project has empty speakers/segments). Re-validates source +
-- spawns chunking/transcribing again.
-- Returns (ok, err) — false jeśli no project or no source.
----------------------------------------------------------------------------
function M.retry_pipeline(state)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  -- Reset transient pipeline state (preserve speakers/segments — user may want partial)
  s.chunks_plan = nil
  s.chunks_results = {}
  s.chunk_handles = {}
  s.flow_b_items_pending = {}
  s.flow_b_item_handles  = {}
  s.flow_b_item_results  = {}
  s.isolator_handle = nil
  s.isolated_audio_path = nil
  s.last_run_error = nil
  s.phase = 'starting'
  set_status(s, 'Restarting pipeline...', 0xCCCCCCFF)
  return true
end

----------------------------------------------------------------------------
-- M3.2: Find similar voices for speaker (REAPER sample → /v1/similar-voices).
-- Result voices list opens modal dla user-select. On select → speaker.voices[lang].
----------------------------------------------------------------------------
function M.request_similar_for_speaker(state, speaker_id, audio_path)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local speaker = require('modules.dubbing_project').find_speaker(s.project, speaker_id)
  if not speaker then return false, 'speaker not found' end
  if not audio_path or audio_path == '' or not util.file_exists(audio_path) then
    return false, 'audio sample not found'
  end
  local voice_admin = require 'modules.voice_admin'
  local h = voice_admin.spawn_similar_voices(audio_path, { top_k = 10 })
  if h.status == 'error' then return false, h.error or 'spawn_similar_voices failed' end
  h.speaker_id = speaker_id
  s.similar_handles[speaker_id] = h
  set_status(s, ('Searching similar voices for %s...'):format(speaker.label or speaker_id), 0xCCCCCCFF)
  return true
end

----------------------------------------------------------------------------
-- M3.4: Per-segment regen / variants. Sequential TTS spawn (max 1 at a time
-- per segment — keeps state simple, avoids exhausting DUB_CONCURRENCY z one
-- segment). After each completion, splice z opts.regen=true (AddTake mode).
--
-- regen_state[seg_id] = { target_remaining = N, current_handle = h?, lang }
-- Pump in consume_signals advances state machine.
----------------------------------------------------------------------------
function M.request_regen_segment(state, seg_id, count)
  local s = init_state(state)
  if not s.project or not seg_id then return false, 'no seg_id' end
  local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
  if not seg then return false, 'segment not found' end
  local lang = s.project.active_target_language
  if not lang then return false, 'no active language' end

  local text = seg.translations and seg.translations[lang]
  if not text or text == '' then
    set_status(s, ('Segment %s has no translation — translate first.'):format(seg_id), 0xFF8888FF)
    return false, 'no translation'
  end

  local speaker = require('modules.dubbing_project').find_speaker(s.project, seg.speaker_id)
  if not speaker then return false, 'speaker not found' end
  local voice_id = (seg.voice_id_overrides and seg.voice_id_overrides[lang])
                or (speaker.voices and speaker.voices[lang])
  if not voice_id or voice_id == '' then
    set_status(s, ('Speaker %s has no voice for %s'):format(speaker.label or seg.speaker_id, lang:upper()), 0xFFB060FF)
    return false, 'no voice'
  end

  -- Init or extend regen state (allow user clicking variants multiple times)
  if s.regen_state[seg_id] then
    s.regen_state[seg_id].target_remaining = (s.regen_state[seg_id].target_remaining or 0) + (count or 1)
  else
    s.regen_state[seg_id] = {
      target_remaining = count or 1,
      current_handle   = nil,
      lang             = lang,
    }
  end
  set_status(s, ('Re-generating %s — %d take(s) queued'):format(seg_id, s.regen_state[seg_id].target_remaining), 0xCCCCCCFF)
  return true
end

function M.cancel_regen_segment(state, seg_id)
  local s = init_state(state)
  if not seg_id or not s.regen_state[seg_id] then return false end
  -- In-flight handle finishes naturally (invariant #7 cancel=wait); future takes dropped.
  s.regen_state[seg_id].target_remaining = 0
  set_status(s, ('Re-gen %s cancelled (in-flight take will finish).'):format(seg_id), 0xCCCCCCFF)
  return true
end

----------------------------------------------------------------------------
-- Regen pump — called z consume_signals. Per segment, spawn 1 TTS at a time,
-- on done splice z regen=true, decrement counter, spawn next if remaining>0.
----------------------------------------------------------------------------
-- Body for the forward-declared run_regen_pump (defined above consume_signals).
function run_regen_pump(state, s)
  if not s.project then return end
  local voice_admin = require 'modules.voice_admin'
  local dubbing_splicer = require 'modules.dubbing_splicer'
  local dub_project = require 'modules.dubbing_project'

  for seg_id, rs in pairs(s.regen_state) do
    local seg = dub_project.find_segment(s.project, seg_id)
    if not seg then
      s.regen_state[seg_id] = nil
    else
      local lang = rs.lang
      -- Spawn next take if no current handle + remaining > 0
      if not rs.current_handle and (rs.target_remaining or 0) > 0 then
        local speaker = dub_project.find_speaker(s.project, seg.speaker_id)
        local voice_id = (seg.voice_id_overrides and seg.voice_id_overrides[lang])
                      or (speaker and speaker.voices and speaker.voices[lang])
        local voice_settings = (seg.voice_settings_overrides and seg.voice_settings_overrides[lang])
                            or (speaker and speaker.voice_settings_per_lang and speaker.voice_settings_per_lang[lang])
        local text = seg.translations and seg.translations[lang]
        if voice_id and text and text ~= '' then
          -- W2 M1: Re-gen = JAWNIE świeża interpretacja → bump take_n
          -- (nowy deterministyczny seed = nowy slot cache, nigdy kopia).
          bump_dub_take(seg, lang)
          local model_id = s.project.tts_model or cfg.get_dubbing_default_tts_model()
          local prev_text, next_text = stitch_context_for(s.project, seg, lang, model_id)
          local h = voice_admin.spawn_tts({
            voice_id       = voice_id,
            text           = text,
            model_id       = model_id,
            voice_settings = voice_settings,
            language_code  = lang,
            output_format  = 'mp3_44100_128',
            prev_text      = prev_text,
            next_text      = next_text,
            seed           = dub_seed_for(seg, lang),
          })
          if h.status == 'error' then
            set_status(s, ('Re-gen TTS %s err: %s'):format(seg_id, h.error or '?'), 0xFF8888FF)
            s.regen_state[seg_id] = nil
          else
            h.regen_seg_id = seg_id
            rs.current_handle = h
            -- M4+ feedback: flip dub_status so segments table pill shows GEN...
            -- (previously remained 'generated' throughout regen → no visual cue)
            seg.dub_status[lang] = 'tts_running'
            mark_dirty(s)
          end
        else
          s.regen_state[seg_id] = nil
        end
      end

      -- Poll current handle
      if rs.current_handle then
        local h = rs.current_handle
        if h.status == 'running' then voice_admin.poll(h) end
        if h.status == 'running' then force_error_if_stale(h, ('Re-gen TTS %s'):format(seg_id)) end
        if h.status == 'done' then
          if h.result then
            if not h.from_cache then
              cost_add_tts(s.project, util.utf8_len(seg.translations[lang] or ''), s.project.tts_model)
            end
            -- Splice z regen=true → AddTake mode
            local sp_res = dubbing_splicer.splice_segment(s.project, seg,
              dub_project.find_speaker(s.project, seg.speaker_id),
              lang, h.result, { regen = true })
            if sp_res.ok then
              seg.dub_status[lang] = 'generated'
              if sp_res.item_guid then seg.item_guids[lang] = sp_res.item_guid end
              seg.dub_n_items[lang] = sp_res.n_items or 1
              if not seg.dub_per_word then seg.dub_per_word = {} end
              seg.dub_per_word[lang] = sp_res.per_word == true
              mark_dirty(s)
              on_segment_dubbed(s, seg, lang)
            else
              set_status(s, ('Re-gen splice err %s: %s'):format(seg_id, sp_res.err or '?'), 0xFF8888FF)
            end
          end
          rs.current_handle = nil
          rs.target_remaining = (rs.target_remaining or 1) - 1
          if rs.target_remaining <= 0 then
            s.regen_state[seg_id] = nil
            set_status(s, ('Re-gen complete: %s'):format(seg_id), 0x80E090FF)
          end
        elseif h.status == 'error' then
          set_status(s, ('Re-gen TTS err %s: %s'):format(seg_id, h.error or '?'), 0xFF8888FF)
          rs.current_handle = nil
          rs.target_remaining = 0
          s.regen_state[seg_id] = nil
        end
      end
    end
  end
end

-- M3.2: Apply selected voice from similar-voices results
function M.apply_voice_for_speaker(state, speaker_id, voice_id, voice_name)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local speaker = require('modules.dubbing_project').find_speaker(s.project, speaker_id)
  if not speaker then return false, 'speaker not found' end
  local lang = s.project.active_target_language
  if not lang then return false, 'no active language' end
  local prev_voice_id = speaker.voices and speaker.voices[lang]
  speaker.voices[lang] = voice_id
  speaker.voice_names[lang] = voice_name or 'voice'
  s.similar_results[speaker_id] = nil
  -- Voice changed → invalidate existing dubs dla tego speakera
  if prev_voice_id and prev_voice_id ~= voice_id then
    local n = propagate_speaker_stale(s.project, speaker_id, lang, 'dub_only') or 0
    if n > 0 then
      set_status(s,
        ('Voice set for %s · %d existing dub(s) marked stale.'):format(speaker.label or speaker_id, n),
        0xFFB060FF)
    else
      set_status(s, ('Voice set for %s'):format(speaker.label or speaker_id), 0x80E090FF)
    end
  else
    set_status(s, ('Voice set for %s'):format(speaker.label or speaker_id), 0x80E090FF)
  end
  mark_dirty(s)
  return true
end

----------------------------------------------------------------------------
-- M4-1: item źródłowy projektu (Flow A mixed_single) dla panelu — sampel
-- klonu budowany z segmentów speakera przez audio_concat, bez wymogu
-- zaznaczenia w REAPER. nil gdy brak / nie znaleziony / Flow B.
----------------------------------------------------------------------------
function M.resolve_source_item(state)
  local s = init_state(state)
  if not s.project or s.project.source_kind ~= 'mixed_single' then return nil end
  local _, item = resolve_source_path_for_mixed(s.project)
  if item and type(item) == 'userdata' then return item end
  return nil
end

----------------------------------------------------------------------------
-- Voice cloning for speaker (called z Cast sidebar "Clone from selection")
----------------------------------------------------------------------------
function M.request_clone_for_speaker(state, speaker_id, audio_path, voice_name)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local speaker = require('modules.dubbing_project').find_speaker(s.project, speaker_id)
  if not speaker then return false, 'speaker not found' end
  if not audio_path or audio_path == '' or not util.file_exists(audio_path) then
    return false, 'audio sample not found'
  end
  local voice_admin = require 'modules.voice_admin'
  local name = voice_name or (speaker.label .. '_dub_' .. (s.project.active_target_language or 'lang') .. '_' .. tostring(os.time()):sub(-6))
  local h = voice_admin.spawn_train(name, audio_path)
  if h.status == 'error' then return false, h.error or 'spawn_train failed' end
  h.args = h.args or {}
  h.args.name = name
  s.clone_handles[speaker_id] = h
  set_status(s, ('Cloning voice for %s...'):format(speaker.label or speaker_id), 0xCCCCCCFF)
  return true
end

----------------------------------------------------------------------------
-- Context menu actions (right-click segments table).
----------------------------------------------------------------------------

-- Delete segment: removes z project + matching REAPER item per all langs.
function M.delete_segment(state, seg_id)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local segments = s.project.segments or {}
  local idx
  for i, seg in ipairs(segments) do
    if seg.id == seg_id then idx = i; break end
  end
  if not idx then return false, 'segment not found' end
  local seg = segments[idx]

  -- Remove REAPER items dla wszystkich target_langs
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  for _, lang in ipairs(s.project.target_languages or {}) do
    local item_guid = seg.item_guids and seg.item_guids[lang]
    if item_guid and item_guid ~= '' then
      local item = find_item_by_guid(item_guid)
      if item then
        local track = reaper.GetMediaItem_Track(item)
        reaper.DeleteTrackMediaItem(track, item)
      end
    end
  end
  table.remove(segments, idx)
  -- Drop in-flight handles dla tego seg
  if s.translate_handles then s.translate_handles[seg_id] = nil end
  if s.tts_handles then s.tts_handles[seg_id] = nil end
  if s.align_handles then s.align_handles[seg_id] = nil end
  if s.regen_state then s.regen_state[seg_id] = nil end
  if s.selected_segment_ids then s.selected_segment_ids[seg_id] = nil end
  if s.selected_segment_id == seg_id then s.selected_segment_id = nil end
  reaper.Undo_EndBlock('Reasonate: delete segment ' .. seg_id, -1)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  mark_dirty(s)
  set_status(s, ('Deleted segment %s'):format(seg_id), 0xCCCCCCFF)
  return true
end

-- Reassign segment do another speaker.
function M.reassign_segment_speaker(state, seg_id, new_speaker_id)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local dub_project = require 'modules.dubbing_project'
  local seg = dub_project.find_segment(s.project, seg_id)
  if not seg then return false, 'segment not found' end
  local new_spk = dub_project.find_speaker(s.project, new_speaker_id)
  if not new_spk then return false, 'speaker not found' end
  if seg.speaker_id == new_speaker_id then return false, 'already assigned' end
  seg.speaker_id = new_speaker_id
  -- Speaker change → existing dub stale (different voice would be used)
  for _, lang in ipairs(s.project.target_languages or {}) do
    propagate_segment_stale(s.project, seg, lang, 'dub_only')
  end
  mark_dirty(s)
  set_status(s, ('Reassigned %s → %s'):format(seg_id, new_spk.label or new_speaker_id), 0xCCCCCCFF)
  return true
end

-- Merge segment z previous lub next (direction: 'prev' | 'next').
-- Concatenates source_text + source_words. Keeps t_start z earlier, t_end z later.
-- Drops translations (must re-translate) + dub items per all langs.
function M.merge_segment(state, seg_id, direction)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local segments = s.project.segments or {}
  local idx
  for i, seg in ipairs(segments) do
    if seg.id == seg_id then idx = i; break end
  end
  if not idx then return false, 'segment not found' end
  local other_idx = (direction == 'prev') and (idx - 1) or (idx + 1)
  if other_idx < 1 or other_idx > #segments then
    return false, 'no ' .. direction .. ' segment'
  end
  local a = segments[math.min(idx, other_idx)]   -- earlier
  local b = segments[math.max(idx, other_idx)]   -- later

  -- Delete REAPER items dla obu segments (will re-dub merged)
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  for _, seg in ipairs({a, b}) do
    for _, lang in ipairs(s.project.target_languages or {}) do
      local item_guid = seg.item_guids and seg.item_guids[lang]
      if item_guid and item_guid ~= '' then
        local item = find_item_by_guid(item_guid)
        if item then
          local track = reaper.GetMediaItem_Track(item)
          reaper.DeleteTrackMediaItem(track, item)
        end
      end
    end
  end

  -- Merge a + b → a, drop b
  a.t_start    = math.min(a.t_start or 0, b.t_start or 0)
  a.t_end      = math.max(a.t_end or 0, b.t_end or 0)
  a.source_text = ((a.source_text or '') .. ' ' .. (b.source_text or '')):gsub('^%s+', ''):gsub('%s+$', '')
  -- Concat source_words (assume already sorted by start; merge preserves order)
  if type(a.source_words) ~= 'table' then a.source_words = {} end
  if type(b.source_words) == 'table' then
    for _, w in ipairs(b.source_words) do a.source_words[#a.source_words + 1] = w end
  end
  -- Reset translations + dub (merged content needs fresh)
  for _, lang in ipairs(s.project.target_languages or {}) do
    if a.translations then a.translations[lang] = '' end
    if a.translation_status then a.translation_status[lang] = 'pending' end
    if a.dub_status then a.dub_status[lang] = 'pending' end
    if a.dub_audio_paths then a.dub_audio_paths[lang] = nil end
    if a.dub_alignment then a.dub_alignment[lang] = nil end
    if a.item_guids then a.item_guids[lang] = nil end
    if a.dub_n_items then a.dub_n_items[lang] = 0 end
  end
  -- Remove b (always by larger index first)
  local b_real_idx
  for i, seg in ipairs(segments) do
    if seg.id == b.id then b_real_idx = i; break end
  end
  if b_real_idx then table.remove(segments, b_real_idx) end
  -- Drop in-flight handles dla b
  if s.translate_handles then s.translate_handles[b.id] = nil end
  if s.tts_handles then s.tts_handles[b.id] = nil end
  if s.align_handles then s.align_handles[b.id] = nil end
  if s.regen_state then s.regen_state[b.id] = nil end
  if s.selected_segment_ids then s.selected_segment_ids[b.id] = nil end
  reaper.Undo_EndBlock('Reasonate: merge segments ' .. a.id .. ' + ' .. b.id, -1)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  mark_dirty(s)
  set_status(s, ('Merged %s + %s → %s. Re-translate + re-generate.'):format(a.id, b.id, a.id), 0xFFB060FF)
  return true
end

-- Re-translate single segment: clear translation + mark stale + spawn fresh.
-- Toggle dub_excluded flag dla segmentu. Excluded = skipped przez translate +
-- generate pumps. User uses [+] / [X] inline buttons or right-click menu.
function M.set_segment_excluded(state, seg_id, excluded)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local dub_project = require 'modules.dubbing_project'
  local seg = dub_project.find_segment(s.project, seg_id)
  if not seg then return false, 'segment not found' end
  seg.dub_excluded = (excluded == true) or nil
  mark_dirty(s)
  if seg.dub_excluded then
    set_status(s, ('Segment %s excluded from dub.'):format(seg_id), 0xCCCCCCFF)
  else
    set_status(s, ('Segment %s included in dub.'):format(seg_id), 0xCCCCCCFF)
  end
  return true
end

function M.retranslate_segment(state, seg_id)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local dub_project = require 'modules.dubbing_project'
  local seg = dub_project.find_segment(s.project, seg_id)
  if not seg then return false, 'segment not found' end
  local lang = s.project.active_target_language
  if not lang then return false, 'no active language' end
  if seg.translations then seg.translations[lang] = '' end
  if seg.translation_status then seg.translation_status[lang] = 'pending' end
  -- Dub też stale (translation will change)
  propagate_segment_stale(s.project, seg, lang, 'all')
  s.translate_pending = true   -- triggers pump to spawn translate
  mark_dirty(s)
  set_status(s, ('Re-translating %s...'):format(seg_id), 0xCCCCCCFF)
  return true
end

----------------------------------------------------------------------------
-- W2 M1: quick action GAP/OVERRUN — dopisz timing hint do director's note
-- (note wchodzi do LLM user_prompt + cache key → wymusza świeże tłumaczenie)
-- i odpal retranslate. Hint widoczny i edytowalny w Inspektorze; poprzedni
-- auto-hint (linia 'TIMING:') podmieniany, nie dublowany. kind =
-- 'expand' (gap — wydłuż tłumaczenie) | 'shorten' (overrun — skróć).
----------------------------------------------------------------------------
function M.request_fit_retranslate(state, seg_id, kind)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
  if not seg then return false, 'segment not found' end
  local lang = s.project.active_target_language
  if not lang then return false, 'no active language' end
  local fit = seg.dub_fit and seg.dub_fit[lang]
  local span = math.max(0, (seg.t_end or 0) - (seg.t_start or 0))
  local hint
  if kind == 'expand' then
    local gap = (fit and fit.gap_secs) or 0
    hint = ('TIMING: previous translation left ~%.1fs of silence in a %.1fs slot — make the translation a bit longer (same meaning, natural phrasing).')
      :format(gap, span)
  else
    local over = fit and ((fit.overrun_secs or 0) + (fit.slack_used or 0)) or 0
    hint = ('TIMING: previous translation overflowed the %.1fs slot by ~%.1fs — make the translation tighter and shorter (same meaning).')
      :format(span, over)
  end
  local note = (seg.director_note or ''):gsub('TIMING:[^\n]*\n?', '')
  note = note:gsub('%s+$', '')
  if note ~= '' then note = note .. '\n' end
  seg.director_note = note .. hint
  return M.retranslate_segment(state, seg_id)
end

-- W3 (tabela): per-segment retry nieudanego GENEROWANIA dubu — reset
-- failed→pending dla tego jednego segmentu + pompa (mirror resetu z
-- request_generate_dub; konsument: przycisk przy statusie wiersza).
function M.retry_segment_dub(state, seg_id)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
  if not seg then return false, 'segment not found' end
  local lang = s.project.active_target_language
  if not lang then return false, 'no active language' end
  if seg.dub_status and seg.dub_status[lang] == 'failed' then
    seg.dub_status[lang] = 'pending'
  end
  s.generate_pending = true
  mark_dirty(s)
  set_status(s, ('Retrying dub %s...'):format(seg_id), 0xCCCCCCFF)
  return true
end

----------------------------------------------------------------------------
-- W2 M2 (PHASE-W2 §3): suwak tempa per segment — trwały user override
-- drabiny. Commit (UI: IsItemDeactivatedAfterEdit) → re-splice in-place na
-- ACTIVE take (zero API); refit otwiera własny Undo block = 1 blok per gest
-- (inv #4). Override przeżywa Re-gen (splice_segment też go czyta); Reset
-- czyści pole → drabina przelicza strategię od zera.
----------------------------------------------------------------------------
do
  local tm = require 'modules.tempo_math'
  M.STRETCH_OVERRIDE_MAX = tm.STRETCH_MAX_RATIO        -- 1.35 (wolniej)
  M.STRETCH_OVERRIDE_MIN = 1 / tm.STRETCH_MAX_RATIO    -- ~0.74 (szybciej)
end

-- Jeden właściciel itemu naraz: suwak disabled gdy segment ma aktywny
-- handle TTS / alignmentu / sekwencji regen (konsument: panel + inspektor).
function M.is_segment_busy(state, seg_id)
  local s = init_state(state)
  return (s.tts_handles and s.tts_handles[seg_id] ~= nil)
      or (s.align_handles and s.align_handles[seg_id] ~= nil)
      or (s.regen_state and s.regen_state[seg_id] ~= nil)
end

function M.set_stretch_override(state, seg_id, rate)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
  if not seg then return false, 'segment not found' end
  local lang = s.project.active_target_language
  if not lang then return false, 'no active language' end
  if not (seg.dub_status and seg.dub_status[lang] == 'generated') then
    return false, 'dub not generated'
  end
  -- Refit przelicza markery JEDNEGO itemu segmentu: per-word ma N małych
  -- itemów (refit złapałby pierwszy), short-bypass 'natural' celowo nie
  -- jest span-fitted — suwak tylko dla strategii drabiny (fit/gap/overrun).
  local fit = seg.dub_fit and seg.dub_fit[lang]
  if fit and (fit.strategy == 'per_word' or fit.strategy == 'natural') then
    return false, 'stretch applies to span-fitted segments only'
  end
  if M.is_segment_busy(state, seg_id) then
    set_status(s, ('Segment %s is busy — wait for generation to finish.'):format(seg_id), 0xFFB060FF)
    return false, 'busy'
  end
  rate = math.max(M.STRETCH_OVERRIDE_MIN,
    math.min(M.STRETCH_OVERRIDE_MAX, tonumber(rate) or 1.0))
  seg.dub_stretch_override = seg.dub_stretch_override or {}
  seg.dub_stretch_override[lang] = rate
  local res = require('modules.dubbing_splicer').refit_segment_item(s.project, seg, lang, {
    alignment = seg.dub_alignment and seg.dub_alignment[lang] or nil,
  })
  if not res.ok then
    seg.dub_stretch_override[lang] = nil
    set_status(s, ('Stretch failed: %s'):format(res.err or '?'), 0xFF8888FF)
    return false, res.err
  end
  mark_dirty(s)
  set_status(s, ('Segment %s tempo set to %.2fx (custom).'):format(seg_id, rate), 0xCCCCCCFF)
  return true
end

function M.clear_stretch_override(state, seg_id)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local seg = require('modules.dubbing_project').find_segment(s.project, seg_id)
  if not seg then return false, 'segment not found' end
  local lang = s.project.active_target_language
  if not lang then return false, 'no active language' end
  if not (seg.dub_stretch_override and seg.dub_stretch_override[lang]) then
    return true   -- nic do czyszczenia
  end
  if M.is_segment_busy(state, seg_id) then
    set_status(s, ('Segment %s is busy — wait for generation to finish.'):format(seg_id), 0xFFB060FF)
    return false, 'busy'
  end
  seg.dub_stretch_override[lang] = nil
  if seg.dub_status and seg.dub_status[lang] == 'generated' then
    local res = require('modules.dubbing_splicer').refit_segment_item(s.project, seg, lang, {
      alignment = seg.dub_alignment and seg.dub_alignment[lang] or nil,
    })
    if not res.ok then
      set_status(s, ('Reset failed: %s'):format(res.err or '?'), 0xFF8888FF)
      return false, res.err
    end
  end
  mark_dirty(s)
  set_status(s, ('Segment %s tempo back to auto.'):format(seg_id), 0xCCCCCCFF)
  return true
end

-- Reveal segment's dub item w REAPER arrange (scroll + select + zoom).
function M.reveal_segment_in_reaper(state, seg_id)
  local s = init_state(state)
  if not s.project then return false, 'no project' end
  local dub_project = require 'modules.dubbing_project'
  local seg = dub_project.find_segment(s.project, seg_id)
  if not seg then return false, 'segment not found' end
  local lang = s.project.active_target_language
  if not lang then return false, 'no active language' end
  local item_guid = seg.item_guids and seg.item_guids[lang]
  if item_guid and item_guid ~= '' then
    local item = find_item_by_guid(item_guid)
    if item then
      reaper.Main_OnCommand(40289, 0)   -- Unselect all items
      reaper.SetMediaItemSelected(item, true)
      -- Scroll arrange do item position
      local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION') or 0
      reaper.SetEditCurPos(pos, true, false)   -- moveview=true, seekplay=false
      reaper.UpdateArrange()
      return true
    end
  end
  -- No dub item: just move cursor do segment t_start (source timeline)
  reaper.SetEditCurPos(seg.t_start or 0, true, false)
  set_status(s, ('No dub item dla %s (use source timeline cursor)'):format(seg_id), 0xFFB060FF)
  return true
end

----------------------------------------------------------------------------
-- Init state externally callable
----------------------------------------------------------------------------
M.init_state = init_state

return M
