-- modules/modes/repair.lua
--
-- NS-F: Repair mode — Descript-like word-level audio editing.
-- Standalone 4-ty tryb. Replaces Phase 11 modal Repair w Voice Replacement.
--
-- Workflow:
--   1. User selects 'Repair' mode → mode_tabs / mode_selector
--   2. User clicks item w REAPER → side panel auto-detects change
--   3. Auto-STT (cache hit instant, miss spawns worker)
--   4. Source-side forced_align refines word boundaries (precision splice)
--   5. User clicks word chip(s), types replacement, ⌘+Enter
--   6. Spawn TTS → forced_align TTS audio → repair_splicer.splice_phrase
--   7. 3 itemy na source tracku, full-source layout, precision crossfades
--
-- Architecture decisions per PHASE-NS-F.md:
--   D6: Precision boundaries via forced_align (eliminuje 2 zgłoszone bugi)
--   D11: F_overlap = lead_sil (full overlap crossfaded, NOT capped)
--   D4: Auto-STT z cache (zero clicks)
--   D5: Output items inline na source tracku (3-item split jak Phase 11)
--   D9: Per-word ▶ play preview button
--   D13: ⌘+Enter regen / Esc unselect

local state          = require 'modules.state'
local helpers        = require 'modules.reaper_helpers'
local theme          = require 'modules.theme'
local util           = require 'modules.util'
local cfg            = require 'modules.config'
local stt            = require 'modules.stt'
local audio_render   = require 'modules.audio_render'
local transcript     = require 'modules.transcript'
local forced_align   = require 'modules.forced_align'
local vc             = require 'modules.voice_clone'
local voice_admin    = require 'modules.voice_admin'
local voice_picker   = require 'modules.gui.voice_picker'
local speaker_picker = require 'modules.gui.speaker_picker'    -- NS-G
local cast_registry  = require 'modules.cast_registry'         -- W2 M3.2
local isolator       = require 'modules.voice_isolator'
local repair_splicer = require 'modules.repair_splicer'
local repair_panel   = require 'modules.gui.repair_panel'
local tempo_math     = require 'modules.tempo_math'
local async_op       = require 'modules.async_op'   -- audit M1-2/M1-3: stale + retry

local M = {}

----------------------------------------------------------------------------
-- State init (idempotent merge per memory init_state_idempotent_merge —
-- state.lua pre-inits state.modes.repair = {}, so we MUST defensively
-- merge per-field, NEVER bail-on-truthy).
----------------------------------------------------------------------------
local function init_state(s)
  if s.initialized == nil then s.initialized = false end
  -- Target item tracking
  if s.last_seen_item_guid == nil then s.last_seen_item_guid = nil end
  if s.source_item_guid    == nil then s.source_item_guid    = nil end
  if s.item_label          == nil then s.item_label          = nil end
  if s.track_name          == nil then s.track_name          = nil end
  -- Voice resolution
  if s.voice               == nil then s.voice               = nil end
  -- STT + alignment pipeline. 'idle' = pre-flight (cache check pending);
  -- 'awaiting_user' = cache miss, waiting na user click "Transcribe" button;
  -- 'preparing_isolate' / 'transcribing' / 'aligning_source' = mid-flight;
  -- 'ready' = transcript loaded; 'error' = failed.
  if s.stt_state           == nil then s.stt_state           = 'idle' end
  if s.stt_cache_key       == nil then s.stt_cache_key       = nil end
  if s.stt_render_info     == nil then s.stt_render_info     = nil end
  if s.stt_source_path     == nil then s.stt_source_path     = nil end
  if s.stt_handle          == nil then s.stt_handle          = nil end
  if s.isolate_handle      == nil then s.isolate_handle      = nil end
  if s.cleaned_audio_path  == nil then s.cleaned_audio_path  = nil end
  if s.transcript          == nil then s.transcript          = nil end
  if s.source_alignment    == nil then s.source_alignment    = nil end
  if s.align_handle        == nil then s.align_handle        = nil end
  if s.words_tbl           == nil then s.words_tbl           = nil end
  if s.visible_words       == nil then s.visible_words       = nil end
  if s.error               == nil then s.error               = nil end
  if s.load_source         == nil then s.load_source         = nil end
  if s.load_elapsed        == nil then s.load_elapsed        = 0 end
  -- Editor state
  if s.sel_first           == nil then s.sel_first           = nil end
  if s.sel_last            == nil then s.sel_last            = nil end
  if s.edit_mode           == nil then s.edit_mode           = 'replace' end
  if s.edit_buffer         == nil then s.edit_buffer         = '' end
  -- scope_kind USUNIĘTE M5-4 (2026-07-11) — selektor okna kontekstu nigdy
  -- nie trafił do UI; kontekst TTS = CONTEXT_N_WORDS (stała pipeline'u).
  if s.scope               == nil then s.scope               = nil end
  -- M2 Insert mode: cursor between chips. 0 = przed pierwszym, N = po ostatnim.
  -- nil = nie umieszczony (default po wejściu w Insert mode).
  if s.cursor_idx          == nil then s.cursor_idx          = nil end
  -- M2 Delete mode: confirm modal trigger
  if s.delete_confirm_pending == nil then s.delete_confirm_pending = false end
  -- Voice settings override (per-repair)
  if s.vs_expanded         == nil then s.vs_expanded         = false end
  if s.vs_settings_init    == nil then s.vs_settings_init    = false end
  if s.vs_settings         == nil then
    s.vs_settings = {
      stability         = 0.5,
      similarity_boost  = 0.75,
      style             = 0.0,
      use_speaker_boost = true,
      speed             = 1.0,
    }
  end
  -- Defensive: jeśli vs_settings istnieje od starszej sesji bez pola speed,
  -- dosypujemy 1.0 (idempotent merge per init_state_idempotent_merge memory)
  if s.vs_settings.speed   == nil then s.vs_settings.speed           = 1.0 end
  -- M2 v3.1 tempo match: auto-set voice_settings.speed do matched źródła
  -- speakera. Od 2026-06-10 (user decision) flaga żyje w ExtState
  -- (cfg.get/set_repair_match_pace, default OFF — natural: głos + kontekst
  -- decydują) — panel i Settings → Repair czytają config live, zero cache.
  -- Last applied auto-speed (displayed w slider read-only gdy match_pace ON).
  if s.last_applied_pace_speed == nil then s.last_applied_pace_speed = 1.0 end
  if s.vs_override_active  == nil then s.vs_override_active  = false end
  -- Regen pipeline (TTS → align TTS → splice)
  if s.regen_state         == nil then s.regen_state         = 'idle' end
  if s.regen_status_text   == nil then s.regen_status_text   = nil end
  if s.regen_error         == nil then s.regen_error         = nil end
  if s.tts_handle          == nil then s.tts_handle          = nil end
  if s.tts_audio_path      == nil then s.tts_audio_path      = nil end
  if s.tts_elapsed         == nil then s.tts_elapsed         = 0 end
  if s.align_tts_handle    == nil then s.align_tts_handle    = nil end
  if s.align_tts_result    == nil then s.align_tts_result    = nil end
  -- M0-1 (audit 2026-07): async align error MUSI zostawić trwały ślad —
  -- bez flagi re-entry perform_op respawnowałby forced_align w nieskończoność
  -- (błędy nie są cache'owane, każdy cykl = płatny POST /v1/forced-alignment).
  if s.align_tts_failed    == nil then s.align_tts_failed    = false end
  if s.pending_regen       == nil then s.pending_regen       = false end
  -- M2 v2 async snapshot dla context regen: pending_ctx + pending_op_mode
  -- preserved across TTS + align waits, żeby mode/selection switch mid-flight
  -- nie corruptował aktywnego op.
  if s.pending_ctx         == nil then s.pending_ctx         = nil end
  if s.pending_op_mode     == nil then s.pending_op_mode     = nil end
  -- Clone confirm modal (mirror Phase 11)
  if s.clone_confirm_pending_open == nil then s.clone_confirm_pending_open = false end
  if s.clone_confirm_name         == nil then s.clone_confirm_name         = '' end
  if s.clone_train_handle         == nil then s.clone_train_handle         = nil end
  if s.clone_train_track          == nil then s.clone_train_track          = nil end
  -- W2 M3.2: snapshot linku klon↔mówca (sid + geom_key + label) z momentu
  -- spawnu treningu — konsumowany w done handlerze (registry upsert+link).
  if s.clone_train_registry       == nil then s.clone_train_registry       = nil end
  -- W2 M3.2 (b): propozycja głosu z Cast Registry (refresh_voice_suggestion).
  if s.voice_suggestion           == nil then s.voice_suggestion           = nil end
  if s.voice_suggestion_sig       == nil then s.voice_suggestion_sig       = nil end
  -- W2 M3 (c-lite): hint po "Split at speaker boundary" ({first, rest}).
  if s.split_rest_hint            == nil then s.split_rest_hint            = nil end
  -- T7 (UX-POLISH): casting mówców — {sid → {voice_id, voice_name}} z P_EXT
  -- itemu; selection_voice = auto-głos bieżącej selekcji; cast_rev bump
  -- inwaliduje cache selekcji; banner/modal "Cast voices".
  if s.speaker_voices             == nil then s.speaker_voices             = {} end
  if s.selection_voice            == nil then s.selection_voice            = nil end
  if s.cast_rev                   == nil then s.cast_rev                   = 0 end
  if s.cast_banner_dismissed      == nil then s.cast_banner_dismissed      = false end
  if s.cast_modal_pending_open    == nil then s.cast_modal_pending_open    = false end
  if s.clone_pref_speaker_sid     == nil then s.clone_pref_speaker_sid     = nil end
  if s.cast_status_sig            == nil then s.cast_status_sig            = nil end
  if s.cast_uncast_n              == nil then s.cast_uncast_n              = 0 end
  if s.clone_train_error          == nil then s.clone_train_error          = nil end
  if s.clone_train_done_toast     == nil then s.clone_train_done_toast     = nil end
  -- NS-G: speaker-aware clone source selection. Async diarize spawn przed
  -- speaker_picker modal (gdy diarize cache miss). pending_clone preserved
  -- across modal close/open transitions (clone confirm modal → speaker_picker).
  if s.clone_diarize_handle      == nil then s.clone_diarize_handle      = nil end
  if s.clone_diarize_pending     == nil then s.clone_diarize_pending     = nil end
  if s.clone_picker_request      == nil then s.clone_picker_request      = nil end
  if s.clone_status_text         == nil then s.clone_status_text         = nil end
  -- NS-G follow-up: speaker tabs w transcript view (gdy diarize=true STT).
  -- s.speakers: list {id, label, word_count} computed po STT done.
  -- s.active_speaker_tab: 'all' (default) lub speaker_id — chip filter.
  -- s.speaker_labels: { scribe_id → user-typed label }, P_EXT persisted.
  -- s.speaker_rename_pending: { sid, buffer } gdy right-click rename popup active.
  if s.speakers                  == nil then s.speakers                  = {} end
  if s.active_speaker_tab        == nil then s.active_speaker_tab        = 'all' end
  if s.speaker_labels            == nil then s.speaker_labels            = {} end
  if s.speaker_rename_pending    == nil then s.speaker_rename_pending    = nil end
  -- NS-G: legacy_cache_hint = cached STT pre-diarize (no speaker info) →
  -- visible hint "Cached transcript missing speaker info. Re-Transcribe."
  if s.legacy_cache_hint         == nil then s.legacy_cache_hint         = false end
  -- History (M1 placeholder — full impl w M3)
  if s.history             == nil then s.history             = {} end
  -- Result toast (consumed by reasonate.lua → footer)
  if s.last_result         == nil then s.last_result         = nil end
  -- W3 Pakiet B: undo integration. proj_change_count = licznik stanu projektu
  -- z poprzedniej klatki; own_proj_change_count = stamp NASZYCH zmian (splice /
  -- undo z przycisku) — detektor je pomija; prev_redo_label = redo-top z
  -- poprzedniej klatki (detekcja ruchu etykiety undo↔redo); undo_top_is_ours =
  -- enabled przycisku "Undo last edit"; undo_notice = transient → theme.flash.
  if s.proj_change_count     == nil then s.proj_change_count     = nil end
  if s.own_proj_change_count == nil then s.own_proj_change_count = nil end
  if s.prev_redo_label       == nil then s.prev_redo_label       = nil end
  if s.undo_top_is_ours      == nil then s.undo_top_is_ours      = false end
  if s.undo_notice           == nil then s.undo_notice           = nil end
  -- W3 Pakiet B+ (user request): playhead → transcript sync (mirror Dubbing).
  -- playhead_word_idx = indeks words_tbl słowa pod kursorem/odtwarzaniem
  -- (podkreślenie chipa); playhead_scroll_pending = one-shot scroll przy
  -- ZMIANIE słowa; last_playhead_t = epsilon-debounce.
  if s.playhead_word_idx       == nil then s.playhead_word_idx       = nil end
  if s.playhead_scroll_pending == nil then s.playhead_scroll_pending = nil end
  if s.last_playhead_t         == nil then s.last_playhead_t         = nil end
  s.initialized = true
end

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------
local function compute_item_bounds(item)
  if not item then return nil end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local item_offs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
  local item_len  = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
  local playrate  = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1
  if playrate <= 0 then playrate = 1 end
  return { lo = item_offs, hi = item_offs + item_len * playrate }
end

local function take_source_path(take)
  if not take then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  return reaper.GetMediaSourceFileName(src, '')
end

local function get_item_label(item)
  if not item then return '?' end
  local take = reaper.GetActiveTake(item)
  local take_name = ''
  if take then
    local _, n = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
    take_name = n or ''
  end
  local track = reaper.GetMediaItemTrack(item)
  local track_name = track and helpers.track_name(track) or ''
  if take_name ~= '' and track_name ~= '' then
    return ('%s @ %s'):format(take_name, track_name)
  elseif take_name ~= '' then
    return take_name
  elseif track_name ~= '' then
    return ('(unnamed) @ %s'):format(track_name)
  end
  return '(unnamed item)'
end

----------------------------------------------------------------------------
-- W3 Pakiet B: lekki undo. REAPER cofa splice natywnie (inv #4 — Undo block),
-- ale panel desynchronizował się po Cmd+Z: s.transcript/words_tbl dalej
-- opisywały stan SPRZED cofnięcia (detect_selection_change nie odpala się dla
-- tego samego GUID), więc kolejna edycja mogła wkleić się w złe miejsce.
-- Rozwiązanie: detekcja zewnętrznego undo/redo naszych edycji per frame +
-- wymuszony resync + widoczny przycisk "Undo last edit" w panelu.
----------------------------------------------------------------------------
local REPAIR_UNDO_PREFIX = 'Reasonate: Repair'   -- prefix etykiet Undo_EndBlock w repair_splicer

function M.is_repair_undo_label(lbl)
  return type(lbl) == 'string' and lbl:find(REPAIR_UNDO_PREFIX, 1, true) == 1
end

-- Czysta decyzja "czy zewnętrzny undo/redo dotknął edycji Repair" (headless-
-- tested w tests/run.lua). Undo naszej edycji ⇔ nasza etykieta wypłynęła na
-- szczyt REDO stacka (nowa akcja czyści redo stack, więc ours-on-redo-top po
-- zmianie licznika = właśnie cofnięto naszą edycję). Redo ⇔ etykieta przeszła
-- z redo-top (poprzednia klatka) na undo-top.
function M.undo_resync_decision(a)
  if a.prev_count == nil then return false end       -- pierwsza klatka: seed only
  if a.count == a.prev_count then return false end   -- brak zmiany stanu projektu
  if a.count == a.own_count then return false end    -- nasza własna zmiana (splice / przycisk)
  if M.is_repair_undo_label(a.redo_label) then return true end
  if M.is_repair_undo_label(a.undo_label) and a.undo_label == a.prev_redo_label then
    return true
  end
  return false
end

-- M0-1 (audit 2026-07): czysta decyzja "czy spawnować forced-align dla TTS"
-- (headless-tested). Async error alignmentu ustawia align_tts_failed — bez
-- tej bramki re-entry perform_op respawnowałby align z identycznym wejściem
-- w nieskończoność (forced_align cache'uje tylko sukcesy → każdy cykl =
-- płatny POST). failed → splice fallback (20ms crossfade + align_warning).
function M.should_spawn_tts_align(s)
  return not s.align_tts_result and not s.align_tts_failed
end

local function force_timeline_resync(s)
  -- Sentinel (nigdy realny GUID) wymusza pełny reset w detect_selection_change
  -- OBIEMA ścieżkami: item selected → guid ~= sentinel → pełny reload (w tym
  -- teardown I1); brak selekcji → guard `last_seen ~= nil` → pełny clear.
  s.last_seen_item_guid = '__timeline_resync__'
end

local function detect_external_undo(s)
  local cur      = reaper.GetProjectStateChangeCount(0)
  local undo_lbl = reaper.Undo_CanUndo2(0)
  local redo_lbl = reaper.Undo_CanRedo2(0)
  s.undo_top_is_ours = M.is_repair_undo_label(undo_lbl)
  if M.undo_resync_decision({
       count           = cur,
       prev_count      = s.proj_change_count,
       own_count       = s.own_proj_change_count,
       undo_label      = undo_lbl,
       redo_label      = redo_lbl,
       prev_redo_label = s.prev_redo_label,
     }) then
    force_timeline_resync(s)
    s.undo_notice = 'Timeline undo detected — transcript reloaded.'
  end
  s.proj_change_count = cur
  s.prev_redo_label   = redo_lbl
end

----------------------------------------------------------------------------
-- W3 Pakiet B+ (user request): playhead → word chip sync (mirror Dubbing
-- sync_playhead_segment). Words_tbl żyje w osi czasu ŹRÓDŁA — pozycja
-- kursora (project time) konwertowana przez geometrię itemu. Scroll TYLKO
-- przy zmianie słowa; między słowami (pauzy) zostaje ostatni marker.
----------------------------------------------------------------------------
local function sync_playhead_word(s, item)
  if not item or not s.words_tbl or #s.words_tbl == 0 then
    s.playhead_word_idx = nil
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
  local take = reaper.GetActiveTake(item)
  if not take then return end
  local item_pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION') or 0
  local item_len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
  if t < item_pos or t > item_pos + item_len then return end  -- poza itemem: trzymaj ostatni
  local offs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
  local rate = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1
  if rate <= 0 then rate = 1 end
  local src_t = (t - item_pos) * rate + offs
  for i, w in ipairs(s.words_tbl) do
    local t0, t1 = tonumber(w.start), tonumber(w['end'])
    if t0 and t1 and src_t >= t0 and src_t <= t1 then
      if i ~= s.playhead_word_idx then
        s.playhead_word_idx       = i
        s.playhead_scroll_pending = true
      end
      return
    end
  end
end

----------------------------------------------------------------------------
-- Forward declarations dla funkcji używanych z poziomu detect_selection_change
-- (które resolve'uje upvalues przy compile time, NIE runtime). Per
-- KNOWN-ISSUES.md "Lua lexical scoping" — `local function X` widzi tylko
-- symbole zdefiniowane WCZEŚNIEJ. Decl tutaj + assignment niżej.
----------------------------------------------------------------------------
local start_source_alignment

----------------------------------------------------------------------------
-- NS-G: helper — count unique speakers w diarize transcript. Used dla branch
-- decision: ≥2 = open speaker_picker; 1 = legacy first-item flow.
----------------------------------------------------------------------------
local function count_unique_speakers(diarize_transcript)
  if not diarize_transcript or type(diarize_transcript.words) ~= 'table' then
    return 0
  end
  local seen = {}
  local n = 0
  for _, w in ipairs(diarize_transcript.words) do
    local spk = w.speaker_id or w.speaker
    if spk and not seen[spk] then
      seen[spk] = true
      n = n + 1
    end
  end
  return n
end

----------------------------------------------------------------------------
-- NS-G follow-up: detect legacy pre-diarize STT cache (words bez speaker_id).
-- Auto-invalidate hit gdy ANY word ma speaker info; else legacy cache
-- traktowany jako stale → force re-Transcribe (speaker tabs need diarize).
----------------------------------------------------------------------------
local function transcript_has_speaker_info(t)
  if not t or type(t.words) ~= 'table' then return false end
  for _, w in ipairs(t.words) do
    if w.speaker_id or w.speaker then return true end
  end
  return false
end

----------------------------------------------------------------------------
-- NS-G follow-up: compute speakers list dla Repair transcript tabs.
-- Returns: list of { id, label, word_count } sorted by word_count desc
-- (highest contributor first). Pre-fix cached STT bez speaker_id zwraca {} →
-- caller hides tabs UI.
-- Default label format: "Speaker N" gdzie N = numer w order (1-based; speaker_0 → "Speaker 1").
-- User-renamed: labels_map[sid] overrides default.
----------------------------------------------------------------------------
local function compute_speakers_for_repair(words_tbl, labels_map)
  if not words_tbl then return {} end
  labels_map = labels_map or {}
  local counts = {}
  local order = {}
  for _, e in ipairs(words_tbl) do
    local sid = e.word and (e.word.speaker_id or e.word.speaker)
    if sid and sid ~= '' then
      if not counts[sid] then
        counts[sid] = 0
        order[#order + 1] = sid
      end
      counts[sid] = counts[sid] + 1
    end
  end
  local out = {}
  for _, sid in ipairs(order) do
    local default_label
    local n_match = sid:match('speaker_(%d+)')
    if n_match then
      default_label = 'Speaker ' .. (tonumber(n_match) + 1)
    else
      default_label = sid
    end
    out[#out + 1] = {
      id         = sid,
      label      = (labels_map[sid] ~= nil and labels_map[sid] ~= '') and labels_map[sid] or default_label,
      word_count = counts[sid],
    }
  end
  table.sort(out, function(a, b) return a.word_count > b.word_count end)
  return out
end

----------------------------------------------------------------------------
-- W2 M3.2: Cast Registry ↔ Repair. Kanoniczny klucz materiału BEZ języka
-- (cast_registry.geometry_key) z tych samych pól co STT cache key —
-- s.stt_source_path + s.stt_render_info stashowane przy item load.
----------------------------------------------------------------------------
local function registry_geom_key(s)
  local ri = s.stt_render_info
  if not s.stt_source_path or not ri then return nil end
  return cast_registry.geometry_key(
    s.stt_source_path, ri.item_offs, ri.item_length, ri.playrate)
end

-- Jedyny sid w transkrypcie diarize albo nil gdy ≥2 (Branch B link).
-- Public dla testów headless (pure).
function M.single_speaker_id(t)
  local found
  for _, w in ipairs((t and t.words) or {}) do
    local sp = w.speaker_id or w.speaker
    if sp and sp ~= '' then
      if found and found ~= sp then return nil end
      found = sp
    end
  end
  return found
end

----------------------------------------------------------------------------
-- NS-G: spawn IVC training z explicit sample_path. Helper deduplikuje
-- error handling (3 calls sites: Voice Isolator fast path, single-speaker
-- fallback, speaker_picker on_train callback).
-- W2 M3.2: opts.speaker_id (sid mówcy, którego regiony trenują klon) →
-- snapshot linku do rejestru W MOMENCIE spawnu (klon może skończyć się po
-- item-switchu — s.stt_* wskazywałyby wtedy inny materiał).
----------------------------------------------------------------------------
local function spawn_clone_train(s, track, clean_name, sample_path, opts)
  s.clone_train_track  = track
  s.clone_train_handle = voice_admin.spawn_train(clean_name, sample_path)
  if s.clone_train_handle.status == 'error' then
    s.clone_train_error  = tostring(s.clone_train_handle.error)
    s.clone_train_handle = nil
    s.clone_train_track  = nil
    s.clone_train_registry = nil
    return
  end
  local sid = opts and opts.speaker_id
  s.clone_train_registry = {
    sid      = sid,
    geom_key = registry_geom_key(s),
    label    = (sid and s.speaker_labels and s.speaker_labels[sid]) or nil,
  }
end

----------------------------------------------------------------------------
-- Sid selekcji — wszystkie słowa jednym mówcą, inaczej nil (guard w panelu
-- ostrzega o mieszanej selekcji osobno).
----------------------------------------------------------------------------
local function selection_sid(s)
  if not (s.sel_first and s.sel_last and s.visible_words) then return nil end
  local sid
  for i = s.sel_first, s.sel_last do
    local e = s.visible_words[i]
    local sp = e and e.word and (e.word.speaker_id or e.word.speaker)
    if sp and sp ~= '' then
      if sid and sid ~= sp then return nil end
      sid = sid or sp
    end
  end
  return sid
end

-- Głos kandydat z postaci rejestru: klon osoby > głos języka transkryptu >
-- default/pierwszy (pick_voice). Zwraca (voice_id, voice_name) | nil.
local function character_voice(s, ch)
  if type(ch.ivc_clone_id) == 'string' and ch.ivc_clone_id ~= '' then
    local dv = ch.voices and ch.voices.default
    local vname = (dv and dv.voice_id == ch.ivc_clone_id and dv.voice_name ~= ''
                   and dv.voice_name)
               or ((ch.label or '?') .. ' (clone)')
    return ch.ivc_clone_id, vname
  end
  local lang = util.iso639_1(s.transcript and s.transcript.language_code)
  return cast_registry.pick_voice(ch, lang)
end

----------------------------------------------------------------------------
-- W2 M3.2 (b) + T7 (UX-POLISH): efektywny głos dla selekcji.
-- s.selection_voice (AUTO-użycie): (1) casting per item
-- (s.speaker_voices[sid] — jawne przypisanie usera w Repair) → (2) postać
-- z Cast Registry zlinkowana (geom_key, sid) — nazwana/sklonowana. Oba to
-- JAWNE decyzje usera → aplikujemy bez pytania (linia głosu to pokazuje).
-- s.voice_suggestion (1-klik, NIE auto): fallback label-match — postać o
-- tej samej nazwie z innego trybu, bez linku do materiału (mniej pewna).
-- Cache per sygnatura (item + selekcja + głos tracka + s.cast_rev);
-- sig=nil / cast_rev++ wymusza refresh (assign/rename/clone).
----------------------------------------------------------------------------
local function refresh_selection_voice(s)
  local sig = table.concat({
    s.source_item_guid or '', tostring(s.sel_first), tostring(s.sel_last),
    (s.voice and s.voice.voice_id) or '', tostring(s.cast_rev or 0),
  }, '|')
  if s.voice_suggestion_sig == sig then return end
  s.voice_suggestion_sig = sig
  s.voice_suggestion = nil
  s.selection_voice  = nil
  local sid = selection_sid(s)
  if not sid then return end
  local sp_label
  for _, spk in ipairs(s.speakers or {}) do
    if spk.id == sid then sp_label = spk.label break end
  end
  -- (1) casting per item — najsilniejszy (jawny gest w Repair)
  local pv = s.speaker_voices and s.speaker_voices[sid]
  if pv and pv.voice_id and pv.voice_id ~= '' then
    s.selection_voice = {
      voice_id = pv.voice_id, name = pv.voice_name or '',
      source = 'speaker_cast', sid = sid, speaker_label = sp_label or sid,
    }
    return
  end
  local gk = registry_geom_key(s)
  if not gk then return end
  local ok, res = pcall(function()
    local reg = cast_registry.load()
    if not reg then return nil end
    -- (2) link (geom_key, sid) → auto
    local ch = cast_registry.find_by_link(reg, gk, sid)
    if ch then
      local vid, vname = character_voice(s, ch)
      if vid and vid ~= '' then
        return { kind = 'auto', voice_id = vid, voice_name = vname,
                 label = ch.label or sp_label or sid }
      end
      return nil
    end
    -- (3) label-match bez linku → propozycja 1-klik
    local lbl = s.speaker_labels and s.speaker_labels[sid]
    if lbl and lbl ~= '' then
      ch = cast_registry.find_character(reg, lbl)
      if ch then
        local vid, vname = character_voice(s, ch)
        if vid and vid ~= '' then
          return { kind = 'suggest', voice_id = vid, voice_name = vname,
                   label = ch.label or lbl }
        end
      end
    end
    return nil
  end)
  if not ok or not res then return end
  if res.kind == 'auto' then
    if not (s.voice and s.voice.voice_id == res.voice_id) then
      s.selection_voice = {
        voice_id = res.voice_id, name = res.voice_name or res.label,
        source = 'cast_registry_auto', sid = sid,
        speaker_label = res.label,
      }
    end
  elseif not (s.voice and s.voice.voice_id == res.voice_id) then
    s.voice_suggestion = {
      sid = sid, label = res.label,
      voice_id = res.voice_id, voice_name = res.voice_name or res.label,
    }
  end
end

----------------------------------------------------------------------------
-- T7 (UX-POLISH): przypisanie głosu mówcy (casting). P_EXT itemu (kopie
-- niosą casting) + Cast Registry gdy mówca NAZWANY (cross-mode; unnamed
-- NIE tworzy postaci — auto-label "Speaker 1" merge'owałby się między
-- materiałami). voice_id nil/'' czyści przypisanie.
----------------------------------------------------------------------------
local function assign_speaker_voice(s, sid, voice_id, voice_name)
  if not sid then return end
  s.speaker_voices = s.speaker_voices or {}
  if voice_id and voice_id ~= '' then
    s.speaker_voices[sid] = { voice_id = voice_id, voice_name = voice_name or '' }
  else
    s.speaker_voices[sid] = nil
  end
  local item = helpers.find_item_by_guid(s.source_item_guid)
  if item then stt.write_item_speaker_voices(item, s.speaker_voices) end
  local lbl = s.speaker_labels and s.speaker_labels[sid]
  local gk  = registry_geom_key(s)
  if lbl and lbl ~= '' and gk and voice_id and voice_id ~= '' then
    pcall(function()
      local reg = cast_registry.load_or_create()
      local ch = cast_registry.find_by_link(reg, gk, sid)
      local surv = cast_registry.upsert_character(reg, {
        label       = (ch and ch.label) or lbl,
        voices      = { default = { voice_id = voice_id,
                                    voice_name = voice_name or '' } },
        source_mode = 'repair',
      })
      if surv then
        cast_registry.link_item_speaker(reg, surv, gk, sid)
        cast_registry.save(reg)
      end
    end)
  end
  s.cast_rev = (s.cast_rev or 0) + 1
  s.voice_suggestion_sig = nil
end

-- T7: najdłuższy ciągły fragment mowy mówcy (source-time) — próbka ▶ w
-- modalu castingu; cap 5 s (mirror M4-4 w dubbing speaker_match).
local function speaker_sample_range(s, sid)
  local best_s, best_e, cur_s, cur_e
  for _, e in ipairs(s.words_tbl or {}) do
    local w  = e.word
    local sp = w and (w.speaker_id or w.speaker)
    if sp == sid and w.start and w['end'] then
      if cur_e and (w.start - cur_e) < 0.8 then
        cur_e = w['end']
      else
        cur_s, cur_e = w.start, w['end']
      end
      if not best_s or (cur_e - cur_s) > (best_e - best_s) then
        best_s, best_e = cur_s, cur_e
      end
    elseif sp and sp ~= sid then
      cur_s, cur_e = nil, nil
    end
  end
  if not best_s then return nil end
  return best_s, math.min(best_e, best_s + 5.0)
end

-- T7: ilu mówców bez głosu (casting P_EXT ∨ link rejestru) — gate banneru
-- "Cast voices". Cache per (item, #speakers, cast_rev) — registry czytany
-- tylko przy zmianie.
local function refresh_cast_status(s)
  local sig = table.concat({
    s.source_item_guid or '', tostring(#(s.speakers or {})),
    tostring(s.cast_rev or 0),
  }, '|')
  if s.cast_status_sig == sig then return end
  s.cast_status_sig = sig
  s.cast_uncast_n = 0
  if #(s.speakers or {}) < 2 then return end
  local linked = {}
  local gk = registry_geom_key(s)
  if gk then
    pcall(function()
      local reg = cast_registry.load()
      if not reg then return end
      for sid, ch in pairs(cast_registry.characters_for_material(reg, gk)) do
        local vid = character_voice(s, ch)
        if vid and vid ~= '' then linked[sid] = true end
      end
    end)
  end
  local n = 0
  for _, spk in ipairs(s.speakers) do
    local pv = s.speaker_voices and s.speaker_voices[spk.id]
    if not (pv and pv.voice_id and pv.voice_id ~= '') and not linked[spk.id] then
      n = n + 1
    end
  end
  s.cast_uncast_n = n
end

----------------------------------------------------------------------------
-- Compute stable STT cache key z item geometry (independent od rendered tmp
-- file, survives session restart). Returns: { cache_key, render_info, source_path }
-- lub nil + err. Used przez detect_selection_change dla cache lookup PRZED
-- rendering rejona item'u + by start_stt dla matching cache save.
----------------------------------------------------------------------------
local function compute_stt_cache_key(item)
  if not item then return nil, 'nil item' end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil, 'item has no audio take' end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil, 'take has no source' end
  -- Walk do root source (section/reverse wrappers) — shared helper (M2-2)
  src = helpers.resolve_root_source(src)
  local src_path = reaper.GetMediaSourceFileName(src, '')
  if not src_path or src_path == '' then return nil, 'source has no file path' end
  local render_info = {
    item_offs   = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0,
    item_length = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0,
    playrate    = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1,
    -- I10 (M0): język w seedzie cache key — transcript w innym języku to inny
    -- transcript ('' = auto-detect). Diarize namespace dziedziczy ten sam key
    -- string (stt_diarize_<key>), więc też jest language-aware. UWAGA: flip
    -- 'pl'→'' to one-time cache miss dla istniejących Repair itemów (płatny
    -- re-transcribe) — odnotowane w KNOWN-ISSUES.
    language    = cfg.get_repair_language(),
  }
  if render_info.playrate <= 0 then render_info.playrate = 1 end
  return {
    cache_key   = stt.cache_key(src_path, render_info),
    render_info = render_info,
    source_path = src_path,
  }
end

----------------------------------------------------------------------------
-- Refine word_tbl boundaries z forced_align result.
-- forced_align zwraca exact word.start/end z dokładnością ms.
-- Scribe word boundaries miały ±30-100ms uncertainty → refined boundaries
-- eliminują cut beginnings/ends caused by Scribe imprecision.
----------------------------------------------------------------------------
local function refine_words_with_alignment(words_tbl, alignment)
  if not words_tbl or not alignment or type(alignment.words) ~= 'table' then
    return words_tbl
  end
  -- Live-fix (2026-06-10): forced_align zwraca tokeny WHITESPACE jako osobne
  -- wpisy words[] (['Maybe',' ','a',' ',…]) — match po surowym indeksie
  -- dopasowywał TYLKO słowo 1 (reszta trafiała w spacje → cichy skip,
  -- refinement de facto nie działał), a słowo 1 potrafiło przejąć błędny czas
  -- mis-anchora (live: "Maybe" refined do 2.14s zamiast ~21.6s). Mapujemy
  -- words_tbl na kolejne NON-SPACE wpisy + sanity window 2.0s vs czas Scribe
  -- (outlier alignera, np. loss>3, nie może nadpisać sensownego czasu STT).
  local non_space = {}
  for _, aw in ipairs(alignment.words) do
    if (aw.text or ''):match('%S') then non_space[#non_space + 1] = aw end
  end
  local n_align = #non_space
  local refined = {}
  -- M5-8 (audit 2026-07): wskaźnik KROCZĄCY zamiast matchu pozycyjnego 1:1 —
  -- jeden split/merge tokenu u alignera gubił refinement dla całego ogona.
  -- Szukamy dopasowania tekstowego w oknie do 3 tokenów w przód (+ okno
  -- czasowe 2.0s jak dotąd); match konsumuje tokeny do znalezionego.
  local ai = 1
  for i, entry in ipairs(words_tbl) do
    local r = {
      raw_idx = entry.raw_idx,
      word    = entry.word,
      text    = entry.text,
      start   = entry.start,
      ['end'] = entry['end'],
    }
    local et_text = (entry.text or ''):gsub('^%s+', ''):gsub('%s+$', ''):lower()
    local scribe_start = tonumber(entry.start)
    local found_at = nil
    for k = ai, math.min(ai + 3, n_align) do
      local aw = non_space[k]
      local aw_text = (aw.text or ''):gsub('^%s+', ''):gsub('%s+$', ''):lower()
      if aw_text == et_text and aw.start and aw['end'] then
        local aligned_start = tonumber(aw.start)
        local drift = (scribe_start and aligned_start)
          and math.abs(aligned_start - scribe_start) or math.huge
        if drift <= 2.0 then found_at = k; break end
      end
    end
    if found_at then
      local aw = non_space[found_at]
      r.start   = aw.start
      r['end']  = aw['end']
      r.aligned = true
      ai = found_at + 1
    end
    refined[i] = r
  end
  return refined
end

-- Headless test hook (M5-8: fixture z rozjechaną tokenizacją).
M.refine_words_with_alignment = refine_words_with_alignment

----------------------------------------------------------------------------
-- Detect REAPER item selection change → reset state.
-- Called every frame z M.render. Compares current REAPER selected item GUID
-- z last_seen_item_guid. On change: reset entire pipeline + auto-spawn STT.
----------------------------------------------------------------------------
local function detect_selection_change(s)
  local n_sel = reaper.CountSelectedMediaItems(0)
  if n_sel == 0 then
    -- No selection — clear panel
    if s.last_seen_item_guid ~= nil then
      s.last_seen_item_guid = nil
      s.source_item_guid    = nil
      s.item_label          = nil
      s.track_name          = nil
      s.voice               = nil
      s.transcript          = nil
      s.source_alignment    = nil
      s.words_tbl           = nil
      s.visible_words       = nil
      s.stt_state           = 'idle'
      s.stt_handle          = nil
      s.isolate_handle      = nil
      s.cleaned_audio_path  = nil
      s.align_handle        = nil
      s.sel_first           = nil
      s.sel_last            = nil
      s.scope               = nil
      s.edit_buffer         = ''
      s.cursor_idx          = nil
      s.delete_confirm_pending = false
      s.pending_ctx         = nil
      s.pending_op_mode     = nil
      -- I1 (M0): teardown in-flight regen pipeline — stale TTS/align z
      -- poprzedniej selekcji nie może wkleić się w przyszłą. Curl workers
      -- NIE są zabijane (inv #3 fire-and-forget) — tylko drop handle;
      -- osierocone sentinele sprząta housekeeping sweep.
      s.tts_handle          = nil
      s.align_tts_handle    = nil
      s.tts_audio_path      = nil
      s.align_tts_result    = nil
      s.align_tts_failed    = false
      s.preview_only        = nil    -- M5-5: stale preview nie może przejąć Apply
      s.pending_regen       = false
      s.regen_state         = 'idle'
      s.regen_status_text   = nil
      s.regen_error         = nil
      s.error               = nil
      s.align_warning       = nil
      s.load_source         = nil
      s.load_elapsed        = 0
      s.playhead_word_idx   = nil
      s.last_playhead_t     = nil
    end
    return nil
  end
  if n_sel > 1 then return nil end  -- multi-select — punt (M3 may add multi-region)

  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then return nil end
  local guid = helpers.item_guid(item)
  if guid == s.last_seen_item_guid then return item end

  -- Selection changed — reset + cache lookup (NIE auto-spawn API)
  s.last_seen_item_guid = guid
  s.source_item_guid    = guid
  s.item_label          = get_item_label(item)
  local track = reaper.GetMediaItemTrack(item)
  s.track_name = track and helpers.track_name(track) or ''
  s.voice      = track and vc.resolve_voice_for_track(track) or nil
  -- Reset pipeline state
  s.transcript          = nil
  s.source_alignment    = nil
  s.words_tbl           = nil
  s.visible_words       = nil
  s.stt_state           = 'idle'
  s.stt_handle          = nil
  s.isolate_handle      = nil
  s.cleaned_audio_path  = nil
  s.align_handle        = nil
  s.sel_first           = nil
  s.sel_last            = nil
  s.scope               = nil
  s.edit_buffer         = ''
  s.cursor_idx          = nil
  s.delete_confirm_pending = false
  s.pending_ctx         = nil
  s.pending_op_mode     = nil
  -- I1 (M0): teardown in-flight regen pipeline (mirror bloku n_sel==0 wyżej) —
  -- bez tego TTS wygenerowany dla itemu A spliceował się w item B, gdy user
  -- przełączył selekcję i zrobił nową edycję zanim pipeline A skończył.
  s.tts_handle          = nil
  s.align_tts_handle    = nil
  s.tts_audio_path      = nil
  s.align_tts_result    = nil
  s.align_tts_failed    = false
  s.preview_only        = nil    -- M5-5: stale preview nie może przejąć Apply
  s.pending_regen       = false
  s.regen_state         = 'idle'
  s.regen_status_text   = nil
  s.regen_error         = nil
  s.error               = nil
  s.align_warning       = nil
  s.load_source         = nil
  s.load_elapsed        = 0
  s.playhead_word_idx   = nil
  s.last_playhead_t     = nil
  s.vs_expanded         = false
  s.vs_settings_init    = false
  s.vs_override_active  = false
  s.transcript_search   = ''
  s.voice_suggestion    = nil
  s.voice_suggestion_sig = nil
  s.split_rest_hint     = nil
  -- T7: reset castingu + banneru (per item); casting ładowany z P_EXT niżej
  s.selection_voice         = nil
  s.cast_banner_dismissed   = false
  s.cast_modal_pending_open = false
  s.clone_pref_speaker_sid  = nil
  -- NS-G follow-up: reset speaker tabs state, load user-saved labels z P_EXT
  s.speakers            = {}
  s.active_speaker_tab  = 'all'
  s.speaker_labels      = stt.read_item_speaker_labels(item) or {}
  s.speaker_voices      = stt.read_item_speaker_voices(item) or {}
  s.speaker_rename_pending = nil
  s.legacy_cache_hint   = false

  -- NS-F M2.x cache-aware Transcribe button (user-feedback fix):
  -- 1. Compute geometry-stable cache key (independent od rendered tmp WAV)
  -- 2. Check cache; HIT → load instant + spawn forced_align. MISS → awaiting_user.
  local key_info, kerr = compute_stt_cache_key(item)
  if not key_info then
    s.error     = 'cache key: ' .. tostring(kerr)
    s.stt_state = 'error'
    return item
  end
  s.stt_cache_key   = key_info.cache_key
  s.stt_render_info = key_info.render_info
  s.stt_source_path = key_info.source_path

  -- W2 M3.2 (a): etykiety mówców wracają na innych itemach tego samego
  -- materiału — seed WYŁĄCZNIE brakujących labeli z Cast Registry (nic nie
  -- nadpisujemy; tylko in-memory — P_EXT itemu zapisze się przy najbliższym
  -- rename/splice, pasywny klik w item nie brudzi projektu).
  do
    local gk = registry_geom_key(s)
    if gk then
      pcall(function()
        local reg = cast_registry.load()
        if not reg then return end
        for sid, ch in pairs(cast_registry.characters_for_material(reg, gk)) do
          if (s.speaker_labels[sid] == nil or s.speaker_labels[sid] == '')
             and type(ch.label) == 'string' and ch.label ~= '' then
            s.speaker_labels[sid] = ch.label
          end
        end
      end)
    end
  end

  local cached_transcript, cache_source = stt.check_cache_for_item(item, key_info.cache_key)
  if cached_transcript and not transcript_has_speaker_info(cached_transcript) then
    -- NS-G follow-up: legacy cache bez speaker_id (sprzed diarize=true default).
    -- Don't auto-load — force user re-Transcribe żeby speaker tabs zadziałały.
    -- Set hint widoczny pod button.
    s.stt_state         = 'awaiting_user'
    s.legacy_cache_hint = true
  elseif cached_transcript then
    s.transcript    = cached_transcript
    s.load_source   = cache_source
    s.load_elapsed  = 0
    local bounds = compute_item_bounds(item)
    s.visible_words = transcript.collect_visible_words(s.transcript, bounds)
    s.words_tbl     = transcript.build_word_table(s.transcript, bounds)
    s.speakers      = compute_speakers_for_repair(s.words_tbl, s.speaker_labels)
    -- Forward-declared earlier — works z forward ref pattern (KNOWN-ISSUES.md)
    start_source_alignment(s, item)
  else
    s.stt_state = 'awaiting_user'   -- User must click "Transcribe" button
  end
  return item
end

----------------------------------------------------------------------------
-- start_stt — explicit user-triggered API call: render visible region of item
-- to tmp WAV via prepare_audio_for_api (handles mp4 video, trim, playrate),
-- then spawn worker_stt.sh z geometry-stable cache_key + timestamp_shift_secs
-- (= item_offs). poll_transcribe shifts response timestamps back do source-time
-- po STT done. NS-F M2.x fix dla "STT robi cały plik zamiast item region".
----------------------------------------------------------------------------
local function start_stt(s, item)
  if not item then return end
  s.error = nil   -- clear previous error przed nową próbą

  -- Step 1: Render visible item region do tmp WAV via prepare_audio_for_api.
  -- Handles mp4 video container (no SUPPORTED_EXTS bypass — auto-render via
  -- AudioAccessor) + trim + playrate. Renders TYLKO item bounds (NIE cały
  -- source 1h dla 1min itemu).
  local rendered_path, render_err, render_info = audio_render.prepare_audio_for_api(item)
  if not rendered_path then
    s.error     = 'cannot render audio for STT: ' .. tostring(render_err)
    s.stt_state = 'error'
    return
  end
  -- render_info może być nil dla "simple" items (mp3/wav simple) — wtedy
  -- rendered_path = raw source. Item_offs = 0 (no shift needed) bo cały
  -- source matches item.
  local timestamp_shift = render_info and (render_info.item_offs or 0) or 0

  local opts = {
    -- I10 (M0): '' = auto-detect (Scribe wykrywa język; worker omituje pole).
    -- Global override przez ExtState repair_language (cfg getter) gdy user
    -- chce wymusić konkretny język.
    language_code          = cfg.get_repair_language(),
    -- NS-G follow-up: diarize=true default — gives speaker_id per word, enables
    -- transcript speaker tabs UI + eliminates "Analyzing speakers..." spinner
    -- w clone Train flow (Branch C). Same Scribe cost, slightly different
    -- response shape (words[i].speaker_id field present). Cache invalidation:
    -- pre-fix cached STT bez speaker_id → fallback do plain chip view (no tabs).
    diarize                = true,
    timestamps_granularity = 'word',
    cache_key              = s.stt_cache_key,
    timestamp_shift_secs   = timestamp_shift,
    -- M5-6: bias słownictwa przy Re-transcribe (PL nazwy własne itd.) —
    -- zebrane z poprzedniego transkryptu PRZED resetem (retranscribe handler).
    keyterms               = s.retrans_keyterms,
  }
  s.retrans_keyterms = nil   -- one-shot

  -- NS-C: Voice Isolator opt-in flag. Isolator dostaje RENDERED region (NIE
  -- raw source) — isolate'uje tylko visible audio, oszczędność czasu + cost.
  local track = reaper.GetMediaItemTrack(item)
  local needs_isolate = track and helpers.get_track_isolate_flag(track) or false
  if needs_isolate and not s.cleaned_audio_path then
    local item_len = (render_info and render_info.item_length)
      or reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
    s.isolate_handle = isolator.spawn_isolate(rendered_path, { duration_secs = item_len })
    if s.isolate_handle.status == 'error' then
      s.error     = 'isolate: ' .. tostring(s.isolate_handle.error)
      s.stt_state = 'error'
      s.isolate_handle = nil
      return
    end
    if s.isolate_handle.status == 'skipped' then
      s.isolate_handle = nil
      opts.audio_path = rendered_path
    elseif s.isolate_handle.status == 'done' then
      s.cleaned_audio_path = s.isolate_handle.result
      s.isolate_handle     = nil
      opts.audio_path = s.cleaned_audio_path
    else
      s.stt_state = 'preparing_isolate'
      return
    end
  end
  if s.cleaned_audio_path and s.cleaned_audio_path ~= '' then
    opts.audio_path = s.cleaned_audio_path
  elseif not opts.audio_path then
    opts.audio_path = rendered_path
  end

  s.stt_handle = stt.spawn_transcribe_for_item(item, opts)
  if not s.stt_handle then
    s.error     = 'spawn STT failed'
    s.stt_state = 'error'
    return
  end
  if s.stt_handle.status == 'done' then
    -- Cache hit (rare bo detect_selection_change już sprawdził, ale safety net)
    s.transcript    = s.stt_handle.transcript
    s.load_source   = s.stt_handle.source
    s.load_elapsed  = 0
    local bounds = compute_item_bounds(item)
    s.visible_words = transcript.collect_visible_words(s.transcript, bounds)
    s.words_tbl     = transcript.build_word_table(s.transcript, bounds)
    s.speakers      = compute_speakers_for_repair(s.words_tbl, s.speaker_labels)
    s.stt_handle    = nil
    start_source_alignment(s, item)
    return
  end
  if s.stt_handle.status == 'error' then
    s.error     = s.stt_handle.error or 'STT spawn returned error'
    s.stt_state = 'error'
    return
  end
  s.stt_state = 'transcribing'
end

----------------------------------------------------------------------------
-- Source-side forced alignment — refine word boundaries z ms precision.
-- Per D6: eliminuje Scribe ±30-100ms uncertainty na audio_start/audio_end.
-- Assigned to forward-declared local (defined at top of file).
----------------------------------------------------------------------------
-- Shift alignment times by `shift_secs` (in place). Used when forced_align
-- runs on rendered/cleaned ITEM REGION (0-based times) — bring times into
-- source-file-time space to match words_tbl (which is source-file-time after
-- STT shift). Mirror stt.lua poll_transcribe shift pattern.
local function shift_alignment_times(alignment, shift_secs)
  if not alignment or not shift_secs or shift_secs <= 0.0001 then return end
  if type(alignment.words) == 'table' then
    for _, w in ipairs(alignment.words) do
      if w.start  then w.start  = w.start  + shift_secs end
      if w['end'] then w['end'] = w['end'] + shift_secs end
    end
  end
  if type(alignment.characters) == 'table' then
    for _, c in ipairs(alignment.characters) do
      if c.start  then c.start  = c.start  + shift_secs end
      if c['end'] then c['end'] = c['end'] + shift_secs end
    end
  end
end

start_source_alignment = function(s, item)
  if not s.transcript or not item then return end
  if not s.transcript.text or s.transcript.text == '' then
    -- No text — skip alignment, use raw Scribe boundaries
    s.stt_state = 'ready'
    return
  end
  -- Resolve audio path + compute shift do source-file-time.
  -- cleaned_audio_path = rendered ITEM REGION (0-based) → shift = item_offs.
  -- stt.item_audio_path = FULL source file (source-file-time) → shift = 0.
  -- BUG fix (2026-05-15): without shift, alignment times nie matchują words_tbl
  -- gdy item_offs > 0 → find_aligned_word_by_time fails dla wszystkich słów →
  -- splice fallback do hard cut at ctx.audio_start/end = wide replace.
  local audio_path
  local shift_secs = 0
  if s.cleaned_audio_path then
    audio_path = s.cleaned_audio_path
    local take = reaper.GetActiveTake(item)
    shift_secs = take and (reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0) or 0
  else
    -- Live-fix (2026-06-10): alignment MUSI dostać to samo audio co STT —
    -- wyrenderowany VISIBLE REGION (cache hit z renderu STT), NIE cały plik
    -- źródłowy. Pełny plik + tekst tylko regionu = aligner kotwiczył pierwsze
    -- słowa regionu w nieopisanym wstępie (live: "Maybe a" @2.1s zamiast
    -- @21.6s przy itemie z D_STARTOFFS≈21.6 i 21s wstępu w pliku; loss 3.27)
    -- → lookup słów failował, a blend points liczyły się z błędnych czasów.
    -- Simple items (untrimmed): prepare zwraca raw source + item_offs=0 →
    -- zachowanie i klucze cache alignmentu jak dotąd.
    local rendered_path, _, render_info = audio_render.prepare_audio_for_api(item)
    if rendered_path then
      audio_path = rendered_path
      shift_secs = render_info and (render_info.item_offs or 0) or 0
    else
      audio_path = stt.item_audio_path(item)   -- render fail → poprzednie zachowanie
    end
  end
  if not audio_path then
    s.stt_state = 'ready'
    return
  end
  s.align_handle = forced_align.spawn(audio_path, s.transcript.text)
  s.align_shift_secs = shift_secs   -- carried do poll for shift po cache miss
  if s.align_handle.status == 'done' then
    -- Cache hit instant
    shift_alignment_times(s.align_handle.result, shift_secs)
    s.source_alignment = s.align_handle.result
    local bounds = compute_item_bounds(item)
    -- Re-build words_tbl with refined boundaries
    local raw_tbl = transcript.build_word_table(s.transcript, bounds)
    s.words_tbl = refine_words_with_alignment(raw_tbl, s.source_alignment)
    s.speakers  = compute_speakers_for_repair(s.words_tbl, s.speaker_labels)
    s.visible_words = transcript.collect_visible_words(s.transcript, bounds)
    s.align_handle = nil
    s.stt_state = 'ready'
    return
  end
  if s.align_handle.status == 'error' then
    -- Alignment failed — proceed z raw Scribe boundaries (fallback).
    -- M1-4a (audit 2026-06-10): fallback był CICHY — user nie wiedział, że
    -- precyzja splice spadła. Teraz amber warning w panel headerze.
    s.align_warning = 'Word alignment unavailable — splice precision reduced (raw STT boundaries)'
    s.align_handle = nil
    s.stt_state = 'ready'
    return
  end
  s.stt_state = 'aligning_source'
end

----------------------------------------------------------------------------
-- Poll handlers (called every frame from M.render)
----------------------------------------------------------------------------
local function poll_isolate(s)
  if s.stt_state ~= 'preparing_isolate' or not s.isolate_handle then return end
  isolator.poll(s.isolate_handle)
  async_op.force_error_if_stale(s.isolate_handle, 'Voice Isolator')
  if s.isolate_handle.status == 'done' then
    s.cleaned_audio_path = s.isolate_handle.result
    s.isolate_handle     = nil
    local item = helpers.find_item_by_guid(s.source_item_guid)
    if item then start_stt(s, item) end
  elseif s.isolate_handle.status == 'error' then
    s.error          = 'isolate: ' .. tostring(s.isolate_handle.error)
    s.stt_state      = 'error'
    s.isolate_handle = nil
  end
end

local function poll_stt(s)
  if s.stt_state ~= 'transcribing' or not s.stt_handle then return end
  stt.poll_transcribe(s.stt_handle)
  async_op.force_error_if_stale(s.stt_handle, 'STT')
  if s.stt_handle.status == 'done' then
    local item = helpers.find_item_by_guid(s.source_item_guid)
    if not item then
      s.error = 'item disappeared during STT'
      s.stt_state = 'error'
      return
    end
    s.transcript    = s.stt_handle.transcript
    s.load_source   = s.stt_handle.source
    s.load_elapsed  = util.now() - (s.stt_handle.started_at or util.now())
    local bounds = compute_item_bounds(item)
    s.visible_words = transcript.collect_visible_words(s.transcript, bounds)
    s.words_tbl     = transcript.build_word_table(s.transcript, bounds)
    s.speakers      = compute_speakers_for_repair(s.words_tbl, s.speaker_labels)
    s.stt_handle    = nil
    start_source_alignment(s, item)
  elseif s.stt_handle.status == 'error' then
    s.error     = s.stt_handle.error or 'STT failed'
    s.stt_state = 'error'
  end
end

local function poll_source_alignment(s)
  if s.stt_state ~= 'aligning_source' or not s.align_handle then return end
  forced_align.poll(s.align_handle)
  async_op.force_error_if_stale(s.align_handle, 'Source alignment')
  if s.align_handle.status == 'done' then
    -- Apply shift (gdy alignment ran on rendered/cleaned 0-based audio).
    shift_alignment_times(s.align_handle.result, s.align_shift_secs or 0)
    s.source_alignment = s.align_handle.result
    local item = helpers.find_item_by_guid(s.source_item_guid)
    if item then
      local bounds = compute_item_bounds(item)
      local raw_tbl = transcript.build_word_table(s.transcript, bounds)
      s.words_tbl = refine_words_with_alignment(raw_tbl, s.source_alignment)
    s.speakers  = compute_speakers_for_repair(s.words_tbl, s.speaker_labels)
      s.visible_words = transcript.collect_visible_words(s.transcript, bounds)
    end
    s.align_handle = nil
    s.stt_state = 'ready'
  elseif s.align_handle.status == 'error' then
    -- Alignment failed — proceed z raw Scribe boundaries (fallback per AD8).
    -- M1-4a: surface degradacji zamiast cichego fallbacku.
    s.align_warning = 'Word alignment unavailable — splice precision reduced (raw STT boundaries)'
    s.align_handle = nil
    s.stt_state = 'ready'
  end
end

----------------------------------------------------------------------------
-- Recompute scope (selection + context window).
-- Mirror Phase 11 pattern z transcript.compute_scope.
----------------------------------------------------------------------------
local function recompute_scope(s, reset_edit_buffer)
  if not s.words_tbl or not s.sel_first then
    s.scope = nil
    if reset_edit_buffer then s.edit_buffer = '' end
    return
  end
  -- M5-4: compute_scope = bounds selekcji + audio range (okno scope wycięte).
  s.scope = transcript.compute_scope(s.words_tbl,
    s.sel_first, s.sel_last or s.sel_first)
  if s.scope and reset_edit_buffer then
    s.edit_buffer = s.scope.selected_text
  end
end

----------------------------------------------------------------------------
-- M2 helpers: cursor_idx → source-time mapping + 30-word context window.
----------------------------------------------------------------------------
local function word_field(w, key)
  if not w then return nil end
  local v = w[key]
  if v ~= nil then return v end
  if w.word then return w.word[key] end
  return nil
end

-- compute_cursor_audio_time USUNIĘTE M5-9a (2026-07-11, user OK) — zero
-- callerów od M2 v2 (splice liczy czasy z alignmentu); git history zachowuje.

----------------------------------------------------------------------------
-- compute_context_range(s, mode) — M2 v2 unified context regen helper.
--
-- Per spec post-v1: Replace, Insert, Delete WSZYSTKIE generują TTS dla okolicy
-- (CONTEXT_N=2 words przed + 2 words po) wraz z zmianą, aby prosody (intonacja
-- + dynamika + pauzy) płynnie blendowała ze zewnętrznym oryginałem. Splice
-- zastępuje rozszerzony fragment (kontekst-przed + zmiana + kontekst-po)
-- całym TTS audio.
--
-- Returns nil, err on validation failure (e.g., no selection / no cursor),
-- else table:
--   {
--     audio_start          — source-time secs (start of extended splice range)
--     audio_end            — source-time secs (end of extended splice range)
--     tts_text             — full text to generate (context_before + change + context_after)
--     prev_text            — extra context BEYOND context_before (TTS prosody hint, 30 words)
--     next_text            — extra context BEYOND context_after  (TTS prosody hint, 30 words)
--     change_first_idx     — first word index of CHANGE (selection / cursor+1)
--     change_last_idx      — last word index of CHANGE (Insert: change_first-1 = empty range)
--     context_before_lo    — first word index in left context (>=1)
--     context_before_hi    — last word index in left context (change_first_idx - 1)
--     context_after_lo     — first word index in right context (change_last_idx + 1)
--     context_after_hi     — last word index in right context (<= n)
--     inserted_text        — replacement / inserted text (empty for Delete)
--     from_text            — original text being replaced/deleted (selected_text, empty for Insert)
--   }
----------------------------------------------------------------------------
local CONTEXT_N_WORDS    = 3   -- bumped 2 → 3 (2026-05-15 PM late):
                                -- daje letter mode access do dalszych ctx words
                                -- (np. /s/ w "this" gdy "a" / "is" już są w 2-word
                                -- ctx ale lepszy sibilant dalej). Plus więcej
                                -- prosody context dla TTS. Trade-off: +40% TTS tokens.
M.CONTEXT_N_WORDS = CONTEXT_N_WORDS   -- M5-4: panel czyta do opisów+highlightu
local PROSODY_HINT_WORDS = 100   -- ElevenLabs previous_text/next_text hint
                                 -- (NIE generowane jako audio, tylko prosody context).
                                 -- 100 słów ≈ 500-600 znaków — bezpiecznie poniżej caps:
                                 -- v3 3k chars/req, Multilingual v2 10k, Flash 40k.
                                 -- Zero cost overhead — context params nie liczą się
                                 -- do TTS char billing.

-- Diagnostic flag — flip ON dla zbierania danych przy "za wolne / za szybkie
-- na auto pace" reportach. Dwa console line per edit:
--   TEMPO/apply  source_pace + baseline + matched_speed (+CLAMPED jeśli przy 0.7/1.2)
--   TEMPO/EMA    observed_pace + applied_speed + observed_baseline + before→after
-- Off by default (zero overhead). Toggle ręcznie w pliku.
-- M0-3 (audit 2026-07): config-gated (Settings → General → "Diagnostic
-- logging", default OFF); odczyt per edit (event-driven), nie per frame.
local function TEMPO_DEBUG() return cfg.get_debug_logging() end

-- W1.2 auto-korekta tempa (2026-06-10, user OK): odchył tempa wstawki vs
-- źródło powyżej tolerancji → JEDEN re-render ze skorygowanym speedem.
-- Predict-ahead chybia o ±25%, bo naturalny pace renderu ElevenLabs skacze
-- per fraza (live-test: 18→23.6 u jednego głosu) — pętla domyka się dopiero
-- pomiarem PO renderze (forced_align i tak już mamy).
local TEMPO_RERENDER_TOLERANCE = 0.12

----------------------------------------------------------------------------
-- M2 v3.1 tempo match: compute_source_pace(s, ctx)
--
-- Mierzy pace speakera w SLOWACH KONTEKSTU (immediate left + right context
-- blocks). Excludes change word(s) — mogą być atypically emphasized lub
-- absent (Insert/Delete).
--
-- Zwraca SYLABY/sec (od 2026-06-10 W1.2 — chars/sec było złym perceptual
-- proxy, patrz tempo_math.syllable_count) lub nil gdy brak meaningful
-- context (np. selection przy start/end transcript bez context).
----------------------------------------------------------------------------
local function compute_source_pace(s, ctx)
  if not s.words_tbl or not ctx then return nil end
  local total_syl = 0
  local total_dur = 0

  -- Left context block
  if ctx.context_before_hi and ctx.context_before_lo
     and ctx.context_before_hi >= ctx.context_before_lo then
    local first = s.words_tbl[ctx.context_before_lo]
    local last  = s.words_tbl[ctx.context_before_hi]
    if first and last and first.start and last['end'] then
      local dur = last['end'] - first.start
      if dur > 0 then
        total_dur = total_dur + dur
        for i = ctx.context_before_lo, ctx.context_before_hi do
          local w = s.words_tbl[i]
          if w and w.text then total_syl = total_syl + tempo_math.syllable_count(w.text) end
        end
      end
    end
  end

  -- Right context block
  if ctx.context_after_hi and ctx.context_after_lo
     and ctx.context_after_hi >= ctx.context_after_lo then
    local first = s.words_tbl[ctx.context_after_lo]
    local last  = s.words_tbl[ctx.context_after_hi]
    if first and last and first.start and last['end'] then
      local dur = last['end'] - first.start
      if dur > 0 then
        total_dur = total_dur + dur
        for i = ctx.context_after_lo, ctx.context_after_hi do
          local w = s.words_tbl[i]
          if w and w.text then total_syl = total_syl + tempo_math.syllable_count(w.text) end
        end
      end
    end
  end

  if total_dur <= 0 or total_syl == 0 then return nil end
  return total_syl / total_dur
end

----------------------------------------------------------------------------
-- compute_tempo_matched_speed(voice_id, source_pace) → speed (clamped 0.7-1.2)
--
-- ElevenLabs semantyka: speed=K → TTS plays K× faster than baseline.
--   effective_TTS_rate = baseline × speed
-- Chcemy: effective_TTS_rate == source_pace, czyli:
--   speed = source_pace / baseline
--
-- Direction sanity check:
--   - source mówi SZYBCIEJ niż baseline (np. 18 vs 14) → speed > 1.0 (mów szybciej)
--   - source mówi WOLNIEJ niż baseline (np. 10 vs 14) → speed < 1.0 (mów wolniej)
--
-- Clamp [0.7, 1.2] z reguł safe zone ElevenLabs (poza tym quality drops).
----------------------------------------------------------------------------
local function compute_tempo_matched_speed(voice_id, source_pace)
  -- Formuła + clamp w modules/tempo_math.lua (headless-testowane — chroni
  -- przed regresją odwróconego wzoru z PM10).
  local baseline = helpers.get_voice_tempo_baseline(voice_id)
  return tempo_math.matched_speed(source_pace, baseline)
end

----------------------------------------------------------------------------
-- compute_tts_observed_pace(tts_alignment, ctx) → syl/sec at applied speed
--                                                  (+ mode, + mid_pace)
--
-- 2026-05-16 (C fix per live-test data): added ctx param. Mierzymy pace
-- TYLKO nad context tokens (skip change words w środku TTS) — mirror
-- compute_source_pace methodology → apples-to-apples observed_baseline.
--
-- Rationale: ElevenLabs TTS renderuje krótkie phrase'y inherently szybciej
-- niż long-form speech. Mierzenie WSZYSTKICH TTS words (incl. change word w
-- środku) over-estimated voice baseline (observed_pace ≈ 17-21 cps obs vs
-- real source ~12-14 cps) → EMA drift'uje baseline UP → future edits clamp
-- do 0.7 floor → "za wolne" reports.
--
-- Context-only measurement: weź first n_before tokens + last n_after tokens
-- (ctx.context_before_hi-lo+1 + ctx.context_after_hi-lo+1), compute pace
-- over each block, sum chars + dur. Skip change tokens w środku → eliminuje
-- short-word-render-bias.
--
-- Fallback do legacy (all-tokens) gdy:
--   - ctx nil (backward compat)
--   - token count mismatch z expected (forced_align tokenization quirk)
--   - both context blocks empty (change at start AND end of transcript)
--
-- Returns nil if alignment insufficient.
----------------------------------------------------------------------------
local function count_text_words(s)
  if not s or s == '' then return 0 end
  local trimmed = s:gsub('^%s+', ''):gsub('%s+$', '')
  if trimmed == '' then return 0 end
  local n = 1
  for _ in trimmed:gmatch('%s+') do n = n + 1 end
  return n
end

local function compute_tts_observed_pace(tts_alignment, ctx)
  if not tts_alignment or type(tts_alignment.words) ~= 'table' then return nil end
  local raw_words = tts_alignment.words

  -- Filter non-whitespace tokens (mirror tts_nth_nonspace pattern — alignment
  -- może zawierać " " whitespace tokens distorting positional lookup).
  local toks = {}
  for _, w in ipairs(raw_words) do
    local txt = (type(w.text) == 'string') and w.text or ''
    if txt:match('%S') then toks[#toks + 1] = w end
  end
  if #toks < 1 then return nil end

  -- Context-aware path (preferred — apples-to-apples z source_pace)
  if ctx then
    local n_before = 0
    if ctx.context_before_hi and ctx.context_before_lo
       and ctx.context_before_hi >= ctx.context_before_lo then
      n_before = ctx.context_before_hi - ctx.context_before_lo + 1
    end
    local n_change = count_text_words(ctx.inserted_text)
    local n_after = 0
    if ctx.context_after_hi and ctx.context_after_lo
       and ctx.context_after_hi >= ctx.context_after_lo then
      n_after = ctx.context_after_hi - ctx.context_after_lo + 1
    end
    local expected = n_before + n_change + n_after

    -- Sanity: TTS token count should ≈ expected (forced_align tokenization
    -- może occasionally split/merge punctuation; tolerance ±1 token).
    if math.abs(#toks - expected) <= 1 and (n_before > 0 or n_after > 0) then
      local total_syl, total_dur = 0, 0

      -- Left context: first n_before tokens
      if n_before > 0 and n_before <= #toks then
        local first = toks[1]
        local last  = toks[n_before]
        if first and last and first.start and last['end'] then
          local dur = last['end'] - first.start
          if dur > 0 then
            total_dur = total_dur + dur
            for i = 1, n_before do
              total_syl = total_syl + tempo_math.syllable_count(toks[i].text)
            end
          end
        end
      end

      -- Right context: last n_after tokens
      if n_after > 0 and n_after <= #toks then
        local start_idx = #toks - n_after + 1
        local first = toks[start_idx]
        local last  = toks[#toks]
        if first and last and first.start and last['end'] then
          local dur = last['end'] - first.start
          if dur > 0 then
            total_dur = total_dur + dur
            for i = start_idx, #toks do
              total_syl = total_syl + tempo_math.syllable_count(toks[i].text)
            end
          end
        end
      end

      if total_dur > 0 and total_syl > 0 then
        -- W1.2 diagnostic (2026-06-10): pace ŚRODKA (change words) — ctx
        -- measurement jest blind na wstawkę, a to ją user słyszy ("za wolno"
        -- przy idealnym ctx match). Logged w TEMPO/EMA; nie karmi baseline'u.
        local mid_pace
        if n_change > 0 then
          local lo, hi = n_before + 1, #toks - n_after
          if hi >= lo and toks[lo] and toks[hi]
             and toks[lo].start and toks[hi]['end'] then
            local mid_dur = toks[hi]['end'] - toks[lo].start
            if mid_dur > 0 then
              local mid_syl = 0
              for i = lo, hi do mid_syl = mid_syl + tempo_math.syllable_count(toks[i].text) end
              if mid_syl > 0 then mid_pace = mid_syl / mid_dur end
            end
          end
        end
        return total_syl / total_dur, 'ctx', mid_pace
      end
    end
  end

  -- Legacy fallback: pace over ALL TTS words (biased dla short phrases —
  -- preserved tylko gdy ctx-path failed). Drugi return 'legacy' → widoczny
  -- w TEMPO/EMA trace (W1.2: jak często fallback firuje).
  local first = toks[1]
  local last  = toks[#toks]
  if not first.start or not last['end'] then return nil end
  local dur = last['end'] - first.start
  if dur <= 0 then return nil end
  local total_syl = 0
  for _, w in ipairs(toks) do
    if w.text then total_syl = total_syl + tempo_math.syllable_count(w.text) end
  end
  if total_syl == 0 then return nil end
  return total_syl / dur, 'legacy'
end

----------------------------------------------------------------------------
-- W1 stretch fix (2026-06-10, live-evidence): voiced-only pace dla I9-narrow.
-- Block pace (compute_source_pace / mid_pace) liczy czas od początku
-- pierwszego do końca ostatniego słowa — ZAWIERA pauzy. Wolna narracja jest
-- wolna PAUZAMI, nie fonemami: porównanie block pace źródła z word-internal
-- pace wstawki przeciągnęło słowa TTS ("informacje" +16% → user "strasznie
-- wolno"). Stretch porównuje tempo SAMYCH SŁÓW po obu stronach
-- (tempo_math.voiced_pace — suma sylab / suma trwań słów).
----------------------------------------------------------------------------
local function source_ctx_voiced_pace(s, ctx)
  if not s.words_tbl or not ctx then return nil end
  local words = {}
  local function add_range(lo, hi)
    if not (lo and hi) then return end
    for i = lo, hi do
      local w = s.words_tbl[i]
      if w then words[#words + 1] = w end
    end
  end
  add_range(ctx.context_before_lo, ctx.context_before_hi)
  add_range(ctx.context_after_lo, ctx.context_after_hi)
  return tempo_math.voiced_pace(words)
end

-- Tempo samych słów WSTAWKI w TTS (tokeny środka po odjęciu ctx; mirror
-- tokenization compute_tts_observed_pace — whitespace filter + sanity ±1).
-- nil gdy tokenization mismatch (fail-safe: bez stretchu).
local function tts_change_voiced_pace(tts_alignment, ctx)
  if not tts_alignment or type(tts_alignment.words) ~= 'table' or not ctx then
    return nil
  end
  local toks = {}
  for _, w in ipairs(tts_alignment.words) do
    local txt = (type(w.text) == 'string') and w.text or ''
    if txt:match('%S') then toks[#toks + 1] = w end
  end
  local n_before = 0
  if ctx.context_before_hi and ctx.context_before_lo
     and ctx.context_before_hi >= ctx.context_before_lo then
    n_before = ctx.context_before_hi - ctx.context_before_lo + 1
  end
  local n_after = 0
  if ctx.context_after_hi and ctx.context_after_lo
     and ctx.context_after_hi >= ctx.context_after_lo then
    n_after = ctx.context_after_hi - ctx.context_after_lo + 1
  end
  local n_change = count_text_words(ctx.inserted_text)
  if n_change < 1 then return nil end
  if math.abs(#toks - (n_before + n_change + n_after)) > 1 then return nil end
  local lo, hi = n_before + 1, #toks - n_after
  if hi < lo then return nil end
  local words = {}
  for i = lo, hi do words[#words + 1] = toks[i] end
  return tempo_math.voiced_pace(words)
end

local function compute_context_range(s, mode)
  local words = s.words_tbl
  if not words or #words == 0 then return nil, 'no words_tbl' end
  local n = #words

  local change_first_idx, change_last_idx, inserted_text, from_text

  if mode == 'replace' then
    if not s.sel_first or not s.sel_last then return nil, 'no selection' end
    change_first_idx = s.sel_first
    change_last_idx  = s.sel_last
    inserted_text    = s.edit_buffer or ''
    from_text        = (s.scope and s.scope.selected_text) or ''
  elseif mode == 'insert' then
    if s.cursor_idx == nil then return nil, 'no cursor' end
    -- Cursor sits w gap między words[cursor_idx] i words[cursor_idx+1].
    -- "Change" range jest pusty: change_first > change_last. Splice nadal działa
    -- (no original audio between context_before.end i context_after.start beyond
    -- inter-word silence, ale rozszerzona splice range zawiera context word audio).
    change_first_idx = s.cursor_idx + 1   -- first word AFTER cursor (chce go w context_after)
    change_last_idx  = s.cursor_idx       -- last word BEFORE cursor (w context_before)
    inserted_text    = s.edit_buffer or ''
    from_text        = ''
  elseif mode == 'delete' then
    if not s.sel_first or not s.sel_last then return nil, 'no selection' end
    change_first_idx = s.sel_first
    change_last_idx  = s.sel_last
    inserted_text    = ''   -- delete = empty replacement
    from_text        = (s.scope and s.scope.selected_text) or ''
  else
    return nil, 'unknown mode: ' .. tostring(mode)
  end

  -- Context indices (clamped to bounds). Empty if range degenerate (change at boundary).
  local ctx_before_lo = math.max(1, change_first_idx - CONTEXT_N_WORDS)
  local ctx_before_hi = change_first_idx - 1
  local ctx_after_lo  = change_last_idx + 1
  local ctx_after_hi  = math.min(n, change_last_idx + CONTEXT_N_WORDS)

  -- Determine audio_start (start of extended splice range)
  local audio_start
  if ctx_before_hi >= ctx_before_lo then
    -- Have left context
    audio_start = tonumber(word_field(words[ctx_before_lo], 'start'))
  else
    -- No left context (change at very start of transcript)
    if mode == 'insert' then
      -- Cursor at idx 0 → no word before. Use words[1].start as splice anchor.
      audio_start = tonumber(word_field(words[1], 'start'))
    else
      -- Replace/Delete with selection starting at word 1
      audio_start = tonumber(word_field(words[change_first_idx], 'start'))
    end
  end

  -- Determine audio_end (end of extended splice range)
  local audio_end
  if ctx_after_hi >= ctx_after_lo then
    audio_end = tonumber(word_field(words[ctx_after_hi], 'end'))
  else
    -- No right context (change at very end of transcript)
    if mode == 'insert' then
      audio_end = tonumber(word_field(words[n], 'end'))
    else
      audio_end = tonumber(word_field(words[change_last_idx], 'end'))
    end
  end

  if not audio_start or not audio_end or audio_end <= audio_start then
    return nil, ('invalid extended audio range [%s..%s] — words missing timing?'):format(
      tostring(audio_start), tostring(audio_end))
  end

  -- Build TTS text: <context_before> <change> <context_after>
  local parts = {}
  for i = ctx_before_lo, ctx_before_hi do
    local t = word_field(words[i], 'text') or ''
    if t ~= '' then parts[#parts + 1] = t end
  end
  if inserted_text and inserted_text ~= '' then
    -- Trim whitespace żeby nie generować double spaces przy concat
    local trimmed = inserted_text:gsub('^%s+', ''):gsub('%s+$', '')
    if trimmed ~= '' then parts[#parts + 1] = trimmed end
  end
  for i = ctx_after_lo, ctx_after_hi do
    local t = word_field(words[i], 'text') or ''
    if t ~= '' then parts[#parts + 1] = t end
  end
  local tts_text = table.concat(parts, ' ')

  if tts_text == '' then
    return nil, 'empty TTS text (no context + no change)'
  end

  -- I2 (M0): długość zmienianego span'u źródła (Delete toast "removed N.NNs";
  -- wcześniej pole czytane w consume_signals, nigdy nie pisane → zawsze 0.00s).
  -- Insert ma degenerate range (first > last) → 0.
  local deleted_len_secs = 0
  if change_last_idx >= change_first_idx then
    local t0 = tonumber(word_field(words[change_first_idx], 'start'))
    local t1 = tonumber(word_field(words[change_last_idx], 'end'))
    if t0 and t1 and t1 > t0 then deleted_len_secs = t1 - t0 end
  end

  -- Build prev_text / next_text (TTS prosody hint — words BEYOND context window)
  local prev_parts = {}
  local prev_lo = math.max(1, ctx_before_lo - PROSODY_HINT_WORDS)
  for i = prev_lo, ctx_before_lo - 1 do
    local t = word_field(words[i], 'text') or ''
    if t ~= '' then prev_parts[#prev_parts + 1] = t end
  end
  local next_parts = {}
  local next_hi = math.min(n, ctx_after_hi + PROSODY_HINT_WORDS)
  for i = ctx_after_hi + 1, next_hi do
    local t = word_field(words[i], 'text') or ''
    if t ~= '' then next_parts[#next_parts + 1] = t end
  end

  return {
    audio_start          = audio_start,
    audio_end            = audio_end,
    tts_text             = tts_text,
    prev_text            = table.concat(prev_parts, ' '),
    next_text            = table.concat(next_parts, ' '),
    change_first_idx     = change_first_idx,
    change_last_idx      = change_last_idx,
    context_before_lo    = ctx_before_lo,
    context_before_hi    = ctx_before_hi,
    context_after_lo     = ctx_after_lo,
    context_after_hi     = ctx_after_hi,
    inserted_text        = inserted_text,
    from_text            = from_text,
    deleted_len_secs     = deleted_len_secs,
  }
end

----------------------------------------------------------------------------
-- M2 v2: unified perform_op(s, mode) — context regen pattern across 3 modes.
--
-- Wszystkie 3 mody (Replace, Insert, Delete) używają identycznego pipeline'u:
--   1. Validate (voice / change input)
--   2. compute_context_range(s, mode) → extended audio range + TTS text including
--      2 words context on each side (CONTEXT_N_WORDS = 2)
--   3. Spawn TTS for `<context_before> <change> <context_after>` (Delete: change='')
--   4. Forced align TTS (per-word boundaries)
--   5. splice_phrase(item, tts, ctx.audio_start, ctx.audio_end, alignment, opts) —
--      replaces EXTENDED span (kontekst + zmiana) z TTS audio. Outer crossfade
--      do otaczającego oryginalnego audio. Prosody continuity preserved bo
--      kontekstowe słowa są wygenerowane RAZEM z TTS — natural intonation flow.
--   6. Shift right_item + downstream items by (TTS phrase_len - ctx span). Positive
--      shift dla Insert (TTS longer than original gap), negative dla Delete
--      (TTS shorter — closes the gap). splice_phrase M2 v2 supports both directions.
--
-- Async snapshot pattern: pending_ctx + pending_op_mode preserved across TTS + align
-- waits, żeby mode switch lub state change mid-flight nie corruptował aktywnego op.
----------------------------------------------------------------------------
local function perform_op(s, mode)
  s.regen_error       = nil
  if s.regen_state ~= 'tts' and s.regen_state ~= 'aligning_tts' and s.regen_state ~= 'splicing' then
    s.regen_state = 'idle'
  end

  -- I1 (M0): GUID-drift gate (backstop) — ctx snapshot z INNEGO itemu nigdy
  -- nie może wykonać splice'a na aktualnym. Reset-block w
  -- detect_selection_change czyści pipeline na switch, ale gate broni
  -- one-frame windows (np. pending_ctx świadomie preserved przez
  -- clone-confirm flow, retrigger po async clone/TTS done).
  if s.pending_ctx and s.pending_ctx.op_item_guid
     and s.pending_ctx.op_item_guid ~= s.source_item_guid then
    s.regen_error      = 'Edit cancelled — item selection changed during processing'
    s.regen_state      = 'error'
    s.pending_ctx      = nil
    s.pending_op_mode  = nil
    s.tts_audio_path   = nil
    s.align_tts_result = nil
    s.align_tts_failed = false
    s.tts_handle       = nil
    s.align_tts_handle = nil
    return
  end

  local item = helpers.find_item_by_guid(s.source_item_guid)
  if not item then
    s.regen_error      = 'item disappeared (deleted?)'
    s.regen_state      = 'error'
    s.pending_ctx      = nil
    s.pending_op_mode  = nil
    return
  end
  local track = reaper.GetMediaItemTrack(item)
  if not track then
    s.regen_error      = 'item has no track'
    s.regen_state      = 'error'
    s.pending_ctx      = nil
    s.pending_op_mode  = nil
    return
  end

  -- Voice resolution (all 3 modes need TTS, so voice required).
  -- T7 (UX-POLISH): głos edycji = selection_voice (casting mówcy /
  -- zlinkowana postać rejestru — jawne decyzje usera, auto-użycie) →
  -- track voice. Snapshot w ctx.edit_voice — retrigger pass (TTS/align
  -- done → re-enter) MUSI użyć tego samego głosu, nawet gdy user zmienił
  -- selekcję w międzyczasie.
  refresh_selection_voice(s)
  local edit_voice = (s.pending_ctx and s.pending_ctx.edit_voice)
                  or s.selection_voice or s.voice
  if not edit_voice or not edit_voice.voice_id or edit_voice.voice_id == '' then
    local default_name = helpers.track_name(track) or ''
    default_name = default_name:gsub('[%c]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if default_name == '' then default_name = 'Voice' end
    s.clone_confirm_name         = default_name
    s.clone_train_error          = nil
    s.clone_confirm_pending_open = true
    s.regen_state                = 'idle'
    s.regen_status_text          = nil
    -- Don't clear pending_ctx — preserve dla retrigger po clone done.
    -- pending_op_mode też zostaje (clone done → pending_regen retriggers z saved mode).
    s.pending_op_mode = mode
    return
  end

  -- Compute / re-use ctx (snapshot for async durability)
  local ctx = s.pending_ctx
  if not ctx then
    local err
    ctx, err = compute_context_range(s, mode)
    if not ctx then
      s.regen_error      = err or 'context computation failed'
      s.regen_state      = 'error'
      s.pending_ctx      = nil
      s.pending_op_mode  = nil
      return
    end
    -- Per-mode input validation
    if (mode == 'replace' or mode == 'insert') and
       (not ctx.inserted_text or ctx.inserted_text == '') then
      s.regen_error      = (mode == 'replace' and 'replacement' or 'inserted') .. ' text is empty'
      s.regen_state      = 'error'
      s.pending_ctx      = nil
      s.pending_op_mode  = nil
      return
    end
    ctx.op_mode      = mode
    ctx.op_item_guid = s.source_item_guid   -- I1: snapshot dla GUID-drift gate
    ctx.edit_voice   = edit_voice           -- T7: głos edycji zamrożony w ctx
    s.pending_ctx     = ctx
    s.pending_op_mode = mode
    -- M0-1: świeży op = świeża szansa dla alignmentu (flaga dotyczy
    -- pojedynczego pipeline'u, nie sesji).
    s.align_tts_failed = false
  end

  -- Effective voice settings (per-repair override or track defaults)
  local effective_settings = s.vs_override_active and {
    stability         = s.vs_settings.stability,
    similarity_boost  = s.vs_settings.similarity_boost,
    style             = s.vs_settings.style,
    use_speaker_boost = s.vs_settings.use_speaker_boost,
    speed             = s.vs_settings.speed or 1.0,
  } or helpers.effective_voice_settings(track)

  -- M2 v3.1 tempo match: override speed dla TTS call gdy match_pace ON.
  -- Slider value w UI ignorowany — auto-calc z source pace + per-voice baseline.
  -- After forced_align (step 2), observed pace updates baseline EMA.
  -- Odczyt configu raz per perform_op entry (2026-06-10 — flaga w ExtState,
  -- default OFF; ctx.tempo_match_* snapshots chronią spójność mid-pipeline).
  local match_pace = cfg.get_repair_match_pace()
  if match_pace and ctx and ctx.tempo_match_applied_speed then
    -- Retrigger pass (TTS/align done → perform_op re-enter): TTS już
    -- wygenerowany ze speedem z pierwszego przebiegu. Re-compute mógłby
    -- rozjechać stamp vs faktyczny render (i spamował TEMPO/apply ×3 per
    -- edit — W1.2 live-test finding 2026-06-10). Reuse snapshot.
    effective_settings.speed = ctx.tempo_match_applied_speed
  elseif match_pace and ctx then
    local source_pace = compute_source_pace(s, ctx)
    if source_pace and source_pace > 0 then
      local matched_speed = compute_tempo_matched_speed(edit_voice.voice_id, source_pace)
      effective_settings.speed   = matched_speed
      s.last_applied_pace_speed  = matched_speed
      -- Stash dla baseline update po forced_align done
      ctx.tempo_match_applied_speed = matched_speed
      ctx.tempo_match_source_pace   = source_pace
      -- I7 partial (W1.2): clamp surfaced w toast — user widzi bez konsoli,
      -- że tempo mogło nie trafić z przyczyn fizycznych (podłoga/sufit speed).
      ctx.tempo_clamped = (matched_speed == tempo_math.SPEED_MIN
                        or matched_speed == tempo_math.SPEED_MAX) or nil
      if TEMPO_DEBUG() then
        local baseline = helpers.get_voice_tempo_baseline(edit_voice.voice_id)
        local clamp_hint = ''
        if matched_speed == tempo_math.SPEED_MIN then
          clamp_hint = (' [CLAMPED min — source slower than %.1f×baseline]'):format(tempo_math.SPEED_MIN)
        elseif matched_speed == tempo_math.SPEED_MAX then
          clamp_hint = (' [CLAMPED max — source faster than %.1f×baseline]'):format(tempo_math.SPEED_MAX)
        end
        reaper.ShowConsoleMsg(('[Reasonate] TEMPO/apply voice=%s · source_pace=%.2f syl/s · baseline=%.2f syl/s · matched_speed=%.3f%s\n')
          :format(tostring(edit_voice.voice_id):sub(1, 8),
                  source_pace, baseline, matched_speed, clamp_hint))
      end
    elseif TEMPO_DEBUG() then
      reaper.ShowConsoleMsg('[Reasonate] TEMPO/apply source_pace=nil (no measurable context — match_pace skipped, slider speed used)\n')
    end
  end

  -- Step 1: Spawn TTS for FULL extended text (context_before + change + context_after)
  if not s.tts_audio_path then
    s.regen_state       = 'tts'
    s.regen_status_text = 'Generating TTS (with prosody context)…'
    -- Opts w localu + snapshot na handle (_spawn_opts) — M1-3: respawn przy
    -- retry-on-429 w poll_regen_handles (mirror tts.lua pattern).
    local tts_opts = {
      voice_id       = edit_voice.voice_id,
      text           = ctx.tts_text,
      prev_text      = ctx.prev_text,
      next_text      = ctx.next_text,
      voice_settings = effective_settings,
      -- M5-1: alignment znakowy w odpowiedzi TTS — 1 request zamiast
      -- TTS + forced-alignment; strukturalnie eliminuje klasę pętli M0-1.
      with_timestamps = cfg.get_repair_tts_timestamps(),
      -- M5-3 + HOTFIX 2026-07-11: język z transkryptu Scribe, ZNORMALIZOWANY
      -- do ISO 639-1 (Scribe zwraca 639-3 'eng' → TTS 400; live-caught).
      -- Normalizacja też w spawn_tts (defensywnie), ale tu u źródła —
      -- klucz cache TTS widzi ten sam kod co request.
      language_code  = util.iso639_1(s.transcript and s.transcript.language_code)
                       or cfg.get_repair_language(),
    }
    s.tts_handle = voice_admin.spawn_tts(tts_opts)
    s.tts_handle._spawn_opts = tts_opts
    if s.tts_handle.status == 'error' then
      s.regen_error      = 'TTS: ' .. tostring(s.tts_handle.error)
      s.regen_state      = 'error'
      s.tts_handle       = nil
      s.pending_ctx      = nil
      s.pending_op_mode  = nil
      return
    end
    if s.tts_handle.status == 'done' then
      s.tts_audio_path = s.tts_handle.result
      if s.tts_handle.alignment then
        s.align_tts_result = s.tts_handle.alignment   -- M5-1: Step 2 zbędny
      end
      s.tts_elapsed    = 0
      s.tts_handle     = nil
    else
      return  -- async; poll → pending_regen retriggers
    end
  end

  -- Step 2: Forced-align TTS audio (per-word boundaries).
  -- M0-1: bramka align_tts_failed — po async erroze NIE respawnujemy
  -- (pętla płatnych requestów); lecimy dalej do splice fallback.
  if M.should_spawn_tts_align(s) then
    s.regen_state       = 'aligning_tts'
    s.regen_status_text = 'Aligning TTS…'
    s.align_tts_handle = forced_align.spawn(s.tts_audio_path, ctx.tts_text)
    if s.align_tts_handle.status == 'error' then
      s.align_tts_handle = nil
      s.align_tts_result = nil  -- splicer fallback do 20ms anti-click crossfade (AD8)
    elseif s.align_tts_handle.status == 'done' then
      s.align_tts_result = s.align_tts_handle.result
      s.align_tts_handle = nil
    else
      return
    end
  end

  -- M2 v3.1 tempo match: baseline EMA update z observed TTS pace.
  -- Liczymy raz per pipeline (przed splice — splice może retriggerować perform_op
  -- ale tempo_match_applied_speed jest cleaned po pierwszym update via _consumed flag).
  if match_pace and s.align_tts_result
     and ctx.tempo_match_applied_speed and not ctx.tempo_match_baseline_consumed then
    local observed_pace, observed_mode, observed_mid_pace =
      compute_tts_observed_pace(s.align_tts_result, ctx)
    if observed_pace and observed_pace > 0 then
      -- Normalize do baseline (speed=1.0): observed = applied * baseline → baseline = observed / applied
      local observed_baseline = observed_pace / ctx.tempo_match_applied_speed
      -- T7: baseline per GLOS EDYCJI (casting moze byc inny niz track voice)
      local ev = ctx.edit_voice or s.voice
      local before = helpers.get_voice_tempo_baseline(ev.voice_id)

      -- Outlier rejection: skip baseline update gdy observed differs >50%
      -- od current. Defends against forced_align mis-measurement (very short
      -- TTS, edge case tokenization) z corrupted EMA accumulation.
      -- Logika w tempo_math.is_outlier (headless-testowana).
      local outlier_reject, outlier_reason = tempo_math.is_outlier(observed_baseline, before)
      -- W1.2 (live-test 2026-06-10, edit #4): pomiar 'legacy' liczy pace po
      -- WSZYSTKICH tokenach TTS (w tym change words) — biased dla krótkich
      -- renderów (to był historyczny driver "za wolno"). Baseline karmimy
      -- WYŁĄCZNIE pomiarem ctx (apples-to-apples z compute_source_pace).
      local legacy_skip = (observed_mode ~= 'ctx')

      if not outlier_reject and not legacy_skip then
        helpers.update_voice_tempo_baseline(ev.voice_id, observed_baseline)
      end

      if TEMPO_DEBUG() then
        local after = helpers.get_voice_tempo_baseline(ev.voice_id)
        local hint = outlier_reject and (' [REJECTED — ' .. outlier_reason .. ']')
          or (legacy_skip and ' [SKIPPED — legacy measurement, baseline NOT updated]')
          or ''
        reaper.ShowConsoleMsg(('[Reasonate] TEMPO/EMA observed_pace=%.2f syl/s (mode=%s) · mid_pace=%s · applied_speed=%.3f · observed_baseline=%.2f syl/s%s · baseline %.2f → %.2f (alpha=0.3)\n')
          :format(observed_pace, tostring(observed_mode or '?'),
                  observed_mid_pace and ('%.2f syl/s'):format(observed_mid_pace) or 'n/a',
                  ctx.tempo_match_applied_speed, observed_baseline,
                  hint, before, after))
      end
    elseif TEMPO_DEBUG() then
      reaper.ShowConsoleMsg('[Reasonate] TEMPO/EMA observed_pace=nil (forced_align result insufficient — baseline NOT updated)\n')
    end
    ctx.tempo_match_baseline_consumed = true   -- idempotent per pipeline
  end

  -- W1.2 auto-korekta tempa (2026-06-10, user OK): po alignmencie znamy
  -- FAKTYCZNE tempo wstawki (mid_pace; fallback pace ctx). Odchylenie od
  -- source_pace > TEMPO_RERENDER_TOLERANCE → JEDEN re-render ze speedem
  -- skorygowanym proporcjonalnie (corrected = applied × target/measured).
  -- One-shot przez ctx.tempo_correction_done — 2. render spliceuje się
  -- niezależnie od wyniku (best effort, bez pętli). Pomiar 'legacy'
  -- (tokenization mismatch) NIE koryguje — zawiera change words (biased).
  if match_pace and s.align_tts_result and ctx.tempo_match_applied_speed
     and ctx.tempo_match_source_pace and not ctx.tempo_correction_done then
    local obs_pace, obs_mode, obs_mid = compute_tts_observed_pace(s.align_tts_result, ctx)
    local measured = obs_mid or (obs_mode == 'ctx' and obs_pace) or nil
    local target   = ctx.tempo_match_source_pace
    if measured and measured > 0 and target > 0 then
      local dev = measured / target
      ctx.tempo_correction_done = true
      if dev > (1 + TEMPO_RERENDER_TOLERANCE) or dev < (1 - TEMPO_RERENDER_TOLERANCE) then
        local corrected = ctx.tempo_match_applied_speed * (target / measured)
        if corrected < tempo_math.SPEED_MIN then corrected = tempo_math.SPEED_MIN end
        if corrected > tempo_math.SPEED_MAX then corrected = tempo_math.SPEED_MAX end
        -- Clamp może pojawić się dopiero na korekcie — odśwież flagę (toast
        -- + warunek I9-narrow stretch przy splice).
        if corrected == tempo_math.SPEED_MIN or corrected == tempo_math.SPEED_MAX then
          ctx.tempo_clamped = true
        end
        if math.abs(corrected - ctx.tempo_match_applied_speed) > 0.01 then
          if TEMPO_DEBUG() then
            reaper.ShowConsoleMsg(('[Reasonate] TEMPO/RERENDER measured=%.2f syl/s vs target=%.2f (dev %+.0f%%) · speed %.3f → %.3f — regenerating once\n')
              :format(measured, target, (dev - 1) * 100,
                      ctx.tempo_match_applied_speed, corrected))
          end
          -- Best-of-two (live-test edit 11: +22% → -12%): zachowaj 1. render;
          -- po 2. renderze spliceujemy ten, który bliżej celu (2. to nowy
          -- los aktuatora — bywa gorszy). Cache path + align table przeżywają.
          ctx.tempo_first_render = {
            audio_path = s.tts_audio_path,
            align      = s.align_tts_result,
            dev        = dev,
          }
          ctx.tempo_match_applied_speed = corrected
          s.last_applied_pace_speed     = corrected
          s.tts_audio_path   = nil
          s.align_tts_result = nil
          s.regen_state       = 'tts'
          s.regen_status_text = 'Adjusting tempo (one-time regenerate)…'
          s.pending_regen     = true
          return
        elseif TEMPO_DEBUG() then
          reaper.ShowConsoleMsg(('[Reasonate] TEMPO/RERENDER skipped — corrected speed clamped to current (%.3f), splicing as-is\n')
            :format(ctx.tempo_match_applied_speed))
        end
      elseif TEMPO_DEBUG() then
        reaper.ShowConsoleMsg(('[Reasonate] TEMPO/VERIFY measured=%.2f syl/s vs target=%.2f (dev %+.0f%%) — within tolerance, splicing\n')
          :format(measured, target, (dev - 1) * 100))
      end
    end
  elseif match_pace and s.align_tts_result and ctx.tempo_correction_done
     and not ctx.tempo_verify_logged then
    ctx.tempo_verify_logged = true
    local obs_pace2, _, obs_mid2 = compute_tts_observed_pace(s.align_tts_result, ctx)
    local measured2 = obs_mid2 or obs_pace2
    local target    = ctx.tempo_match_source_pace
    if measured2 and measured2 > 0 and target and target > 0 then
      local dev2 = measured2 / target
      local fr = ctx.tempo_first_render
      if fr and fr.dev and fr.audio_path and fr.align
         and math.abs(fr.dev - 1) < math.abs(dev2 - 1) then
        -- Best-of-two: 1. render był bliżej celu — spliceuj JEGO.
        s.tts_audio_path   = fr.audio_path
        s.align_tts_result = fr.align
        if TEMPO_DEBUG() then
          reaper.ShowConsoleMsg(('[Reasonate] TEMPO/RERENDER-RESULT measured=%.2f syl/s (dev %+.0f%%) WORSE than 1st render (dev %+.0f%%) — splicing FIRST render\n')
            :format(measured2, (dev2 - 1) * 100, (fr.dev - 1) * 100))
        end
      elseif TEMPO_DEBUG() then
        reaper.ShowConsoleMsg(('[Reasonate] TEMPO/RERENDER-RESULT measured=%.2f syl/s vs target=%.2f (dev %+.0f%%) — splicing\n')
          :format(measured2, target, (dev2 - 1) * 100))
      end
    end
  end

  -- I9-narrow (W1 sesja 2, USER-APPROVED — DEVIATIONS 2026-06-10): clamp-floor
  -- wall. Przy podłodze speed (0.7) aktuator ElevenLabs nie zwolni renderu do
  -- tempa wolnej narracji — domykamy po stronie REAPER łagodnym élastique
  -- stretchem wklejki (D_PLAYRATE < 1, pitch preserved). Scope gate: TYLKO
  -- output item (source nietknięty, inv #2), TYLKO przy clampie na podłodze,
  -- TYLKO gdy resztkowy odchył > tolerancja (tempo_math.stretch_playrate).
  local stretch_playrate = nil
  if match_pace and s.align_tts_result
     and ctx.tempo_match_applied_speed == tempo_math.SPEED_MIN
     and ctx.tempo_match_source_pace then
    -- Rama pomiaru: VOICED-ONLY po obu stronach (W1 fix po live-evidence
    -- "informacje" — block pace z pauzami jako target przeciągał słowa).
    local src_voiced = source_ctx_voiced_pace(s, ctx)
    local tts_voiced = tts_change_voiced_pace(s.align_tts_result, ctx)
    stretch_playrate = tempo_math.stretch_playrate(tts_voiced, src_voiced,
      TEMPO_RERENDER_TOLERANCE)
    if TEMPO_DEBUG() then
      if stretch_playrate then
        reaper.ShowConsoleMsg(('[Reasonate] TEMPO/STRETCH clamp-floor: words-only tts=%.2f vs src=%.2f syl/s — item playrate %.3f (élastique, pitch preserved)\n')
          :format(tts_voiced, src_voiced, stretch_playrate))
      else
        reaper.ShowConsoleMsg(('[Reasonate] TEMPO/STRETCH skipped — words-only tts=%s vs src=%s syl/s (within tolerance or slower)\n')
          :format(tts_voiced and ('%.2f'):format(tts_voiced) or 'n/a',
                  src_voiced and ('%.2f'):format(src_voiced) or 'n/a'))
      end
    end
  end

  -- M5-5: tryb Preview — odsłuch wygenerowanej poprawki BEZ splice'a.
  -- Apply po odsłuchu re-startuje pipeline od zera: przy NIEZMIENIONYM
  -- tekście spawn_tts to cache hit (koszt 0, instant); przy zmienionym —
  -- świeży render (stare audio NIE może się wkleić — dlatego czyścimy
  -- tts_audio_path zamiast go reużyć).
  if s.preview_only then
    s.preview_only = nil
    require('modules.preview').play_file(s.tts_audio_path, 'rep_tts_preview')
    s.regen_state       = 'idle'
    s.regen_status_text = 'Preview playing — Apply reuses this take from cache (no extra cost).'
    s.tts_audio_path    = nil
    s.align_tts_result  = nil
    s.align_tts_failed  = nil
    s.pending_ctx       = nil
    s.pending_op_mode   = nil
    return
  end

  -- Step 3: Splice. M2 v3 default: letter-aligned blended splice (crossfade
  -- na konkretnej literze immediate context word — outer context words zostają
  -- oryginalne, TTS używane NARROW). Fallback do splice_phrase (M2 v2 wide
  -- replace) gdy: brak source_alignment lub blend points niemożliwe (np.
  -- letter mismatch po edge case'ach).
  s.regen_state       = 'splicing'
  s.regen_status_text = 'Splicing…'

  local repair_metadata = {
    phrase_text  = ctx.tts_text,
    from_text    = ctx.from_text,
    voice_id     = (ctx.edit_voice or s.voice).voice_id,
    voice_source = (ctx.edit_voice or s.voice).source,
    seed         = 0,
  }

  local result = nil
  local blended_attempted = false
  if s.align_tts_result and s.source_alignment and s.words_tbl then
    blended_attempted = true
    result = repair_splicer.splice_phrase_blended(item, s.tts_audio_path, ctx,
      s.align_tts_result, s.source_alignment, s.words_tbl, {
        crossfade_secs   = 0.040,
        shift_downstream = true,
        repair_mode      = mode,
        repair_metadata  = repair_metadata,
        stretch_playrate = stretch_playrate,
      })
    if not result.ok and result.fallback_recommended then
      -- Blend points failed (np. context word text mismatch) — fallback do
      -- M2 v2 wide splice z diagnostic info.
      result = nil
    end
  end
  if not result then
    result = repair_splicer.splice_phrase(item, s.tts_audio_path,
      ctx.audio_start, ctx.audio_end, s.align_tts_result, {
        fallback_crossfade_secs = 0.020,
        shift_downstream        = true,
        repair_mode             = mode,
        repair_metadata         = repair_metadata,
        stretch_playrate        = stretch_playrate,
      })
  end

  if not result.ok then
    s.regen_error      = 'Splice: ' .. tostring(result.err)
    s.regen_state      = 'error'
    s.pending_ctx      = nil
    s.pending_op_mode  = nil
    s.tts_audio_path   = nil
    s.align_tts_result = nil
    s.align_tts_failed = false
    return
  end

  -- Success — emit toast + history per mode
  local _, new_guid = reaper.GetSetMediaItemInfo_String(result.new_item, 'GUID', '', false)
  local ctx_before_n = math.max(0, ctx.context_before_hi - ctx.context_before_lo + 1)
  local ctx_after_n  = math.max(0, ctx.context_after_hi  - ctx.context_after_lo  + 1)

  -- NS-G follow-up: propagate transcript cache + speaker_labels do left_item +
  -- right_item children powstałych z splice. Bez tego user klika sąsiedni
  -- fragment → cache miss (different geometry-stable key) → musi re-Transcribe
  -- mimo że to ten sam source. Po splice oba children mają SAME source-time
  -- words, więc original transcript covers ich nowe item bounds.
  local function propagate_cache_to(target_item)
    if not target_item then return end
    local key_info = compute_stt_cache_key(target_item)
    if not key_info or not key_info.cache_key then return end
    -- Regular STT cache (P_EXT + file)
    local _, encoded = pcall(require('modules.lib.json').encode, s.transcript)
    if encoded then
      stt.write_item_cache(target_item, encoded, key_info.cache_key)
      stt.save_file_cache_by_key(key_info.cache_key, s.transcript)
    end
    -- Speaker labels (per-item P_EXT — copy user's renames "Mati"/"Host")
    if s.speaker_labels and next(s.speaker_labels) then
      stt.write_item_speaker_labels(target_item, s.speaker_labels)
    end
  end
  propagate_cache_to(result.left_item)
  propagate_cache_to(result.right_item)

  s.last_result = {
    ok                   = true,
    op                   = mode,
    new_item_guid        = new_guid,
    edit_text            = ctx.inserted_text,
    from_text            = ctx.from_text,
    audio_start          = ctx.audio_start,
    audio_end            = ctx.audio_end,
    tts_elapsed          = s.tts_elapsed or 0,
    phrase_len           = result.phrase_len,
    shifted_secs         = result.shifted_secs,
    voice_source         = (ctx.edit_voice or s.voice).source,
    volume_gain_db       = result.volume_gain_db,
    volume_match_applied = result.volume_match_applied,
    context_before_n     = ctx_before_n,
    context_after_n      = ctx_after_n,
    deleted_len_secs     = ctx.deleted_len_secs,   -- I2: czytane w Delete toast
    tempo_clamped        = ctx.tempo_clamped,      -- I7 partial: toast suffix
    tempo_stretch_playrate = result.stretch_playrate, -- I9-narrow: toast suffix
  }
  s.history[#s.history + 1] = {
    op                = mode,
    timestamp         = os.time(),
    from_text         = ctx.from_text,
    to_text           = ctx.inserted_text,
    audio_start       = ctx.audio_start,
    audio_end         = ctx.audio_end,
    context_before_n  = ctx_before_n,
    context_after_n   = ctx_after_n,
    voice_id          = (ctx.edit_voice or s.voice).voice_id,
    new_item_guid     = new_guid,
  }
  -- Reset op state
  s.regen_state       = 'idle'
  s.regen_status_text = nil
  s.regen_error       = nil
  s.tts_audio_path    = nil
  s.align_tts_result  = nil
  s.align_tts_failed  = false
  s.pending_ctx       = nil
  s.pending_op_mode   = nil
  -- Reset edit state per mode
  if mode == 'insert' then
    s.cursor_idx = nil
  else
    s.sel_first = nil
    s.sel_last  = nil
    s.scope     = nil
  end
  s.edit_buffer = ''
  -- W3 Pakiet B: stamp własnej zmiany projektu — detektor zewnętrznego undo
  -- nie może wziąć naszego świeżego splice'a za cofnięcie/redo usera.
  s.own_proj_change_count = reaper.GetProjectStateChangeCount(0)
end

----------------------------------------------------------------------------
-- Dispatcher — calls perform_op z current edit_mode (or saved pending mode jeśli
-- async retrigger).
----------------------------------------------------------------------------
local function perform_regenerate(s)
  -- W async retrigger: użyj saved pending_op_mode (preserves intent gdyby user
  -- przełączył mode mid-flight). Pierwszy call: użyj s.edit_mode.
  local mode = s.pending_op_mode or s.edit_mode or 'replace'
  perform_op(s, mode)
end

----------------------------------------------------------------------------
-- Async TTS / align poll w M.render (callbacks retrigger perform_regenerate)
----------------------------------------------------------------------------
local function poll_regen_handles(s)
  if s.tts_handle then
    local h = s.tts_handle
    if h._retry_at then
      -- M1-3 (audit 2026-06-10): retry-on-429 — Repair był JEDYNYM mode bez
      -- retry (VR/TTS/Dubbing mają od dawna); rate-limit ubijał edit od razu.
      if util.now() >= h._retry_at then
        h._retry_at = nil
        local nh = voice_admin.spawn_tts(h._spawn_opts)
        if nh.status == 'error' then
          s.regen_error = 'TTS retry failed: ' .. tostring(nh.error)
          s.regen_state = 'error'
          s.tts_handle  = nil
        else
          nh._spawn_opts  = h._spawn_opts
          nh._retry_count = h._retry_count
          s.tts_handle    = nh
          s.regen_status_text = ('Generating TTS (retry %d/%d)…')
            :format(h._retry_count, async_op.MAX_RETRIES)
        end
      end
    else
      voice_admin.poll(h)
      if h.status == 'running' then async_op.force_error_if_stale(h, 'Repair TTS') end
      if h.status == 'done' then
        s.tts_audio_path = h.result
        if h.alignment then
          s.align_tts_result = h.alignment   -- M5-1: 1 request, Step 2 zbędny
        end
        s.tts_elapsed    = h.elapsed or 0
        s.tts_handle     = nil
        s.pending_regen  = true
      elseif h.status == 'error' then
        if async_op.schedule_retry_429(h) then
          s.regen_status_text = ('Rate limited — retry %d/%d…')
            :format(h._retry_count, async_op.MAX_RETRIES)
        else
          s.regen_error = 'TTS: ' .. tostring(h.error)
          s.regen_state = 'error'
          s.tts_handle  = nil
        end
      end
    end
  end
  if s.align_tts_handle then
    forced_align.poll(s.align_tts_handle)
    async_op.force_error_if_stale(s.align_tts_handle, 'TTS alignment')
    if s.align_tts_handle.status == 'done' then
      s.align_tts_result  = s.align_tts_handle.result
      s.align_tts_handle  = nil
      s.pending_regen     = true
    elseif s.align_tts_handle.status == 'error' then
      -- Fallback: proceed bez alignment z heuristic. M1-4a: surface
      -- degradacji (splicer użyje 20ms anti-click crossfade per AD8).
      -- M0-1: align_tts_failed blokuje respawn przy re-entry perform_op
      -- (trwały błąd 402/422/5xx = pętla płatnych wywołań bez tej flagi).
      s.align_warning     = 'TTS alignment failed — blend used fallback crossfade (reduced precision)'
      s.align_tts_handle  = nil
      s.align_tts_result  = nil
      s.align_tts_failed  = true
      s.pending_regen     = true
    end
  end
end

----------------------------------------------------------------------------
-- Cycle edit_mode (Tab w/ wrap): replace → insert → delete → replace.
-- Mirror on_mode_change callback semantics (cross-mode state cleanup).
----------------------------------------------------------------------------
local function cycle_edit_mode(s)
  local order = { replace = 'insert', insert = 'delete', delete = 'replace' }
  local new_mode = order[s.edit_mode] or 'replace'
  if new_mode == s.edit_mode then return end
  s.edit_mode   = new_mode
  s.edit_buffer = ''
  if new_mode == 'insert' then
    s.sel_first = nil
    s.sel_last  = nil
    s.scope     = nil
  else
    s.cursor_idx = nil
    if s.sel_first then recompute_scope(s, new_mode == 'replace') end
  end
end

----------------------------------------------------------------------------
-- Keyboard shortcuts:
--   ⌘+Enter / Ctrl+Enter — trigger regen (per current mode)
--   Esc                  — unselect / clear cursor
--   Tab                  — cycle edit modes (Replace → Insert → Delete)
--   ← / →                — Insert mode: move cursor word-by-word
--   Backspace / Delete   — Delete mode: trigger confirm modal
----------------------------------------------------------------------------
local function process_shortcuts(ctx, s)
  if not reaper.ImGui_GetCurrentContext then return end
  local mod_super = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Super())
                 or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
  local enter_pressed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false)

  -- Skip większości shortcuts jeśli ImGui widget aktywnie focused (input boxes).
  -- Wyjątek: Cmd+Enter ZAWSZE działa (pozwala submit z InputText).
  if reaper.ImGui_IsAnyItemActive(ctx) then
    if mod_super and enter_pressed then
      if s.edit_mode == 'delete' then
        if s.scope then s.delete_confirm_pending = true end
      else
        s.pending_regen = true
      end
    end
    return
  end

  local esc_pressed     = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(),    false)
  local tab_pressed     = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Tab(),       false)
  local left_pressed    = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_LeftArrow(), true)
  local right_pressed   = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_RightArrow(),true)
  local bspace_pressed  = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Backspace(), false)
  local del_pressed     = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Delete(),    false)

  if mod_super and enter_pressed then
    if s.edit_mode == 'delete' then
      if s.scope then s.delete_confirm_pending = true end
    else
      s.pending_regen = true
    end
    return
  end

  if esc_pressed then
    s.sel_first   = nil
    s.sel_last    = nil
    s.scope       = nil
    s.cursor_idx  = nil
    s.edit_buffer = ''
    return
  end

  if tab_pressed then
    cycle_edit_mode(s)
    return
  end

  -- Insert mode arrow keys: move cursor word-by-word
  if s.edit_mode == 'insert' and (left_pressed or right_pressed) then
    local words = s.words_tbl or s.visible_words
    local n = words and #words or 0
    if n > 0 then
      local cur = s.cursor_idx or 0
      if left_pressed then
        s.cursor_idx = math.max(0, cur - 1)
      elseif right_pressed then
        s.cursor_idx = math.min(n, cur + 1)
      end
    end
    return
  end

  -- Delete mode Backspace/Delete → trigger confirm modal
  if s.edit_mode == 'delete' and (bspace_pressed or del_pressed) then
    if s.scope then s.delete_confirm_pending = true end
    return
  end
end

----------------------------------------------------------------------------
-- 2026-07-11 (user-caught: chip "Repair · aligning words" wisiał w stopce
-- w innym trybie): pompa TŁA — poll'uje async handle (isolate/STT/alignment/
-- TTS) gdy Repair NIE jest aktywnym trybem, żeby in-flight praca kończyła
-- się zamiast zamarzać. ZERO akcji na timeline: splice (perform_regenerate)
-- odpala się wyłącznie w M.render aktywnego trybu — pending_regen czeka.
-- Wołane z reasonate.lua co klatkę dla nieaktywnego Repair.
----------------------------------------------------------------------------
function M.pump_background(st)
  local s = st.modes and st.modes.repair
  if not s or not s.source_item_guid then return end
  poll_isolate(s)
  poll_stt(s)
  poll_source_alignment(s)
  poll_regen_handles(s)
end

----------------------------------------------------------------------------
-- Public M.render — main mode panel.
----------------------------------------------------------------------------
function M.render(ctx, st, deps)
  local s = state.mode_state('repair')
  init_state(s)

  -- W3 Pakiet B: zewnętrzny undo/redo edycji Repair (Cmd+Z w REAPER) musi
  -- wymusić przeładowanie transkryptu ZANIM user zrobi kolejną edycję.
  detect_external_undo(s)

  -- Detect REAPER selection change → check cache (auto-load if hit) or wait
  -- for explicit user "Transcribe" button click (cache miss → stt_state='awaiting_user').
  local item = detect_selection_change(s)

  -- W3 Pakiet B+: playhead → word chip sync (marker + one-shot scroll)
  sync_playhead_word(s, item)
  -- NIE auto-spawn API call. User decides kiedy uruchomić STT (per user feedback
  -- 2026-05-14: auto-spawn = waste czasu/pieniędzy gdy user tylko explore tracks).

  -- Poll async handles
  poll_isolate(s)
  poll_stt(s)
  poll_source_alignment(s)
  poll_regen_handles(s)

  -- W2 M3.2 (b) + T7: efektywny głos selekcji + status castingu (cached)
  refresh_selection_voice(s)
  refresh_cast_status(s)

  -- Delegate full render to gui/repair_panel
  repair_panel.render(ctx, s, deps, {
    -- M5-4: JEDNO źródło rozmiaru okna kontekstu (opisy + highlight w
    -- panelu = dokładnie to, co pipeline regeneruje).
    context_n_words = CONTEXT_N_WORDS,
    on_transcribe_click = function()
      -- Explicit user-triggered STT spawn (replaces auto-spawn on item select).
      -- Per user feedback: long files marnują czas/cost na auto API call.
      local cur_item = helpers.find_item_by_guid(s.source_item_guid)
      if cur_item and s.stt_state == 'awaiting_user' then
        s.legacy_cache_hint = false
        start_stt(s, cur_item)
      end
    end,
    on_retranscribe_click = function()
      -- NS-G follow-up: force re-Transcribe — clears cache (P_EXT + file
      -- geometry-stable + file legacy + diarize) i spawns fresh STT. Used dla:
      -- (a) legacy cache bez speaker_id → re-run z diarize=true.
      -- (b) user just wants fresh transcript dla jakichkolwiek powodów.
      local cur_item = helpers.find_item_by_guid(s.source_item_guid)
      if not cur_item then return end
      -- M5-6: keyterms z DOTYCHCZASOWEGO transkryptu (bias na słownictwo —
      -- nazwy własne, terminy) zebrane PRZED resetem stanu; unikalne,
      -- ≥4 znaki (krótkie słowa nie potrzebują biasu), cap 100.
      do
        local seen, terms = {}, {}
        for _, entry in ipairs(s.words_tbl or {}) do
          local t = (entry.text or ''):gsub('^%s+', ''):gsub('%s+$', '')
          local key = t:lower()
          if utf8.len(t) and (utf8.len(t) or 0) >= 4 and not seen[key] then
            seen[key] = true
            terms[#terms + 1] = t
            if #terms >= 100 then break end
          end
        end
        s.retrans_keyterms = #terms > 0 and terms or nil
      end
      stt.clear_cache_for_item(cur_item, s.stt_cache_key)
      -- Plus diarize namespace
      if s.stt_cache_key then
        local dp = stt.cache_path_for_diarize_key(s.stt_cache_key)
        if dp and util.file_exists(dp) then os.remove(dp) end
      end
      reaper.GetSetMediaItemInfo_String(cur_item,
        'P_EXT:Reasonate.diarize_transcript_hash', '', true)
      reaper.GetSetMediaItemInfo_String(cur_item,
        'P_EXT:Reasonate.diarize_transcript_json', '', true)
      -- Reset transcript state + spawn fresh
      s.transcript        = nil
      s.words_tbl         = nil
      s.visible_words     = nil
      s.speakers          = {}
      s.active_speaker_tab = 'all'
      s.legacy_cache_hint = false
      s.stt_state         = 'idle'
      start_stt(s, cur_item)
    end,
    on_search_change = function(text)
      s.transcript_search = text or ''
    end,
    on_speaker_tab_change = function(sid)
      -- 'all' lub speaker_id string. Reset edit selection żeby nie zostawić
      -- zaznaczonego słowa z ukrytego speakera.
      s.active_speaker_tab = sid or 'all'
      s.sel_first  = nil
      s.sel_last   = nil
      s.cursor_idx = nil
      s.scope      = nil
    end,
    on_rename_speaker = function(sid, new_label)
      -- Save w P_EXT (per-item) i lokalnie. Recompute s.speakers żeby nowy
      -- label pojawił się na zakładce immediate.
      if not sid then return end
      s.speaker_labels = s.speaker_labels or {}
      local trimmed = (new_label or ''):gsub('^%s+', ''):gsub('%s+$', '')
      if trimmed == '' then
        s.speaker_labels[sid] = nil   -- empty → revert do default 'Speaker N'
      else
        s.speaker_labels[sid] = trimmed
      end
      local item = helpers.find_item_by_guid(s.source_item_guid)
      if item then stt.write_item_speaker_labels(item, s.speaker_labels) end
      s.speakers = compute_speakers_for_repair(s.words_tbl, s.speaker_labels)
      -- W2 M3.2 (a): nazwanie mówcy = tożsamość postaci w Cast Registry.
      -- Zlinkowana → relabel/merge (cleanup duplikatów po labelu); nowa →
      -- upsert + link (geom_key, sid). Wyczyszczenie labela → unlink (postać
      -- zostaje w rejestrze — mogła przyjść z dubbingu / mieć klon).
      local gk = registry_geom_key(s)
      if gk then
        pcall(function()
          local reg = cast_registry.load_or_create()
          if trimmed == '' then
            if cast_registry.unlink_item_speaker(reg, gk, sid) then
              cast_registry.save(reg)
            end
            return
          end
          local ch = cast_registry.find_by_link(reg, gk, sid)
          local surv
          if ch then
            surv = cast_registry.rename_character(reg, ch, trimmed)
          else
            surv = cast_registry.upsert_character(reg,
              { label = trimmed, source_mode = 'repair' })
          end
          if surv then
            cast_registry.link_item_speaker(reg, surv, gk, sid)
            cast_registry.save(reg)
          end
        end)
        s.voice_suggestion_sig = nil   -- rejestr się zmienił → refresh propozycji
      end
    end,
    on_use_suggested_voice = function()
      -- W2 M3.2 (b) + T7: 1-klik "użyj głosu tego mówcy" — od T7 zapisuje
      -- się jako CASTING mówcy (P_EXT + registry gdy nazwany): kolejne
      -- edycje tego mówcy dostają głos automatycznie.
      local sug = s.voice_suggestion
      if not sug then return end
      assign_speaker_voice(s, sug.sid, sug.voice_id, sug.voice_name)
    end,
    on_assign_voice_click = function(sid)
      -- T7: Assign voice… (zakładka mówcy / modal castingu) — voice_picker
      -- w trybie callback; P_EXT tracka nietknięty.
      if not sid then return end
      local cur = s.speaker_voices and s.speaker_voices[sid]
      voice_picker.open({
        state            = st,
        current_voice_id = cur and cur.voice_id or nil,
        allow_clear      = true,
        on_pick          = function(voice_id, voice_name)
          assign_speaker_voice(s, sid, voice_id, voice_name)
          -- Modal castingu zamknął się przed pickerem (zagnieżdżony modal
          -- blokowałby input) — wróć do niego po wyborze.
          if s.cast_modal_reopen_after_pick then
            s.cast_modal_reopen_after_pick = nil
            s.cast_modal_pending_open = true
          end
        end,
      })
    end,
    on_clear_speaker_voice = function(sid)
      assign_speaker_voice(s, sid, nil, nil)
    end,
    on_train_clone_speaker = function(sid)
      -- T7: Train clone… z zakładki/modala — clone confirm z prefill nazwy
      -- (label mówcy) + preferowany sid dla speaker_pickera.
      if not sid then return end
      local lbl = s.speaker_labels and s.speaker_labels[sid]
      local item2  = helpers.find_item_by_guid(s.source_item_guid)
      local track2 = item2 and reaper.GetMediaItemTrack(item2)
      local default_name = (lbl and lbl ~= '' and lbl)
        or (track2 and helpers.track_name(track2)) or 'Voice'
      s.clone_confirm_name         = default_name
      s.clone_train_error          = nil
      s.clone_pref_speaker_sid     = sid
      s.clone_confirm_pending_open = true
      s.cast_modal_pending_open    = false
    end,
    on_open_cast_modal = function()
      s.cast_modal_pending_open = true
    end,
    on_dismiss_cast_banner = function()
      s.cast_banner_dismissed = true
    end,
    speaker_sample_range = function(sid)
      return speaker_sample_range(s, sid)
    end,
    on_split_selection_at_speaker = function()
      -- W2 M3 (c-lite, user decision 2026-07-11 nocna): przytnij selekcję
      -- do ciągłego runu PIERWSZEGO mówcy; resztę user edytuje osobno —
      -- auto-selekcja reszty po splice byłaby krucha (3-item split zmienia
      -- GUID-y i indeksy). Hint pod selekcją mówi, co zostało.
      if not (s.sel_first and s.sel_last and s.visible_words) then return end
      local first_sid, cut, rest_sid
      for i = s.sel_first, s.sel_last do
        local e = s.visible_words[i]
        local sp = e and e.word and (e.word.speaker_id or e.word.speaker)
        if sp and sp ~= '' then
          if not first_sid then
            first_sid = sp
          elseif sp ~= first_sid then
            cut, rest_sid = i - 1, sp
            break
          end
        end
      end
      if not cut or cut < s.sel_first then return end
      s.sel_last = cut
      local function label_of(sid2)
        for _, spk in ipairs(s.speakers or {}) do
          if spk.id == sid2 then return spk.label end
        end
        return sid2
      end
      s.split_rest_hint = { first = label_of(first_sid), rest = label_of(rest_sid) }
      recompute_scope(s, s.edit_mode == 'replace')
    end,
    on_select_word    = function(idx, extend)
      s.split_rest_hint = nil   -- ręczna zmiana selekcji = user działa dalej
      -- Dispatch per edit_mode: Insert places cursor BEFORE that chip;
      -- Replace + Delete use selection range.
      if s.edit_mode == 'insert' then
        -- Cursor_idx = i - 1 (0-indexed gap przed chipem i; shift+click = po chipie)
        if extend then
          s.cursor_idx = idx     -- cursor AFTER chip idx (shift+click)
        else
          s.cursor_idx = idx - 1  -- cursor BEFORE chip idx
        end
        return
      end
      -- Replace + Delete: selection range
      if extend and s.sel_first then
        local new_lo = math.min(s.sel_first, idx)
        local new_hi = math.max(s.sel_first, idx)
        s.sel_first  = new_lo
        s.sel_last   = new_hi
      else
        s.sel_first = idx
        s.sel_last  = idx
      end
      -- recompute_scope reset edit_buffer dla Replace (po nowej selekcji);
      -- dla Delete edit_buffer nie jest używany.
      local reset = (s.edit_mode == 'replace')
      recompute_scope(s, reset)
    end,
    on_set_cursor_end = function()
      -- Insert mode "↑ Insert at end" button — cursor po ostatnim word.
      if s.edit_mode ~= 'insert' then return end
      local words = s.words_tbl or s.visible_words
      s.cursor_idx = words and #words or 0
    end,
    on_mode_change   = function(new_mode)
      if new_mode ~= 'replace' and new_mode ~= 'insert' and new_mode ~= 'delete' then
        return
      end
      if new_mode == s.edit_mode then return end
      s.edit_mode   = new_mode
      s.edit_buffer = ''
      if new_mode == 'insert' then
        -- Insert mode: ignore selection, use cursor_idx
        s.sel_first = nil
        s.sel_last  = nil
        s.scope     = nil
      else
        -- Replace / Delete: ignore cursor
        s.cursor_idx = nil
        if new_mode == 'replace' and s.sel_first then
          recompute_scope(s, true)
        elseif new_mode == 'delete' and s.sel_first then
          recompute_scope(s, false)
        end
      end
    end,
    on_unselect      = function()
      s.sel_first   = nil
      s.sel_last    = nil
      s.scope       = nil
      s.cursor_idx  = nil
      s.edit_buffer = ''
    end,
    on_undo_click    = function()
      -- W3 Pakiet B: natywny undo REAPER (splice w Undo block per inv #4) +
      -- wymuszony resync panelu w jednym kliku. Gate na etykiecie — przycisk
      -- nie może cofnąć cudzej akcji (np. move itemu zrobionego po edycji).
      if not M.is_repair_undo_label(reaper.Undo_CanUndo2(0)) then return end
      reaper.Undo_DoUndo2(0)
      force_timeline_resync(s)
      s.own_proj_change_count = reaper.GetProjectStateChangeCount(0)
      s.undo_notice = 'Last edit undone — timeline restored.'
    end,
    on_edit_change   = function(text)
      s.edit_buffer = text
    end,
    on_regen_click   = function()
      -- Delete mode: ⌘+Enter / button → confirm modal (no automatic action).
      -- Replace + Insert: spawn regen pipeline.
      if s.edit_mode == 'delete' then
        if s.scope then s.delete_confirm_pending = true end
      else
        s.pending_regen = true
      end
    end,
    on_preview_click = function()
      -- M5-5: pełny pipeline TTS (z tempo/align) BEZ splice'a — perform_op
      -- kończy odsłuchem; Apply potem reużywa cache (patrz preview_only).
      if s.edit_mode == 'delete' then return end
      s.preview_only  = true
      s.pending_regen = true
    end,
    on_reset_voice_settings = function()
      s.vs_override_active = false
      s.vs_settings_init   = false
    end,
    on_change_voice_click = function()
      -- M1.5b: otwiera Voice Picker, ustawia track_voice na pick.
      local item = helpers.find_item_by_guid(s.source_item_guid)
      if not item then return end
      local track = reaper.GetMediaItemTrack(item)
      if not track then return end
      local cur_voice_id = s.voice and s.voice.voice_id
      voice_picker.open({
        state            = st,
        track_guid       = helpers.track_guid(track),
        current_voice_id = cur_voice_id,
        allow_clear      = true,
        on_pick          = function(voice_id, voice_name)
          if voice_id and voice_id ~= '' then
            helpers.set_track_voice(track, voice_id, voice_name)
          else
            helpers.clear_track_voice(track)
          end
          -- Re-resolve voice z fresh track state
          s.voice = vc.resolve_voice_for_track(track)
        end,
      })
    end,
    on_reclone_click = function()
      -- M1.5b: kasuje cached clone + manual track voice → opens clone confirm modal.
      local item = helpers.find_item_by_guid(s.source_item_guid)
      if not item then return end
      local track = reaper.GetMediaItemTrack(item)
      if not track then return end
      helpers.clear_track_voice_clone(track)
      helpers.clear_track_voice(track)
      s.voice = vc.resolve_voice_for_track(track)
      local default_name = helpers.track_name(track) or 'Voice'
      default_name = default_name:gsub('[%c]', ''):gsub('^%s+', ''):gsub('%s+$', '')
      if default_name == '' then default_name = 'Voice' end
      s.clone_confirm_name         = default_name
      s.clone_train_error          = nil
      s.clone_confirm_pending_open = true
    end,
  })

  -- Keyboard shortcuts (after panel renders — żeby input fields nie consumed pierwsze)
  process_shortcuts(ctx, s)

  -- Pending regen trigger (one-shot from shortcut or button).
  -- M1-4d guard (audit 2026-06-10): NIE startuj gdy pipeline ma handle in
  -- flight — async retrigger ustawia pending_regen dopiero PO wyzerowaniu
  -- handle'a, więc guard blokuje wyłącznie podwójny user-trigger
  -- (⌘+Enter ×2 mid-flight = drugi spawn TTS = podwójny koszt + osierocony
  -- handle). UI i tak pokazuje spinner przez regen_state.
  if s.pending_regen then
    s.pending_regen = false
    if not (s.tts_handle or s.align_tts_handle) then
      perform_regenerate(s)
    end
  end
end

----------------------------------------------------------------------------
-- Delete confirm modal (M2 v2). Triggered when s.delete_confirm_pending=true
-- (set przez on_regen_click w Delete mode OR Backspace/Delete shortcut).
-- Confirm → s.pending_regen=true → perform_op('delete') async pipeline (TTS
-- regenerates context for smooth prosody blending). Cancel → clear flag.
----------------------------------------------------------------------------
local DELETE_POPUP_ID = 'Delete words?##repair_delete'

local function render_delete_confirm_modal(ctx, s)
  if s.delete_confirm_pending then
    reaper.ImGui_OpenPopup(ctx, DELETE_POPUP_ID)
    s.delete_confirm_pending = false
  end

  theme.center_next_modal(ctx, 480, 0)
  theme.popup_keep_top(ctx, DELETE_POPUP_ID)
  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, DELETE_POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if not visible then return end
  if not p_open then reaper.ImGui_CloseCurrentPopup(ctx) end

  local sc = s.scope
  if not sc then
    reaper.ImGui_TextDisabled(ctx, '(selection cleared)')
    if reaper.ImGui_Button(ctx, 'Close##rdc_close') then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
    return
  end

  local n_sel = sc.sel_last - sc.sel_first + 1
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    ('Permanently delete %d word%s? Audio gap will close (30 ms crossfade ' ..
     'between left+right items, downstream items shift left).'):format(
       n_sel, n_sel == 1 and '' or 's'))
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Text(ctx, 'Text to remove:')
  reaper.ImGui_TextWrapped(ctx, '"' .. (sc.selected_text or '') .. '"')
  theme.push_caption(ctx)
  reaper.ImGui_TextDisabled(ctx, ('Range: %.3f s — %.3f s  ·  duration %.3f s'):format(
    sc.audio_start or 0, sc.audio_end or 0,
    (sc.audio_end or 0) - (sc.audio_start or 0)))
  theme.pop_caption(ctx)

  reaper.ImGui_Spacing(ctx)

  -- Danger-styled Delete primary button
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        theme.COLORS.danger)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), theme.COLORS.danger_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  theme.COLORS.danger_active)
  if reaper.ImGui_Button(ctx, ('Delete %d word%s##rdc_confirm'):format(
       n_sel, n_sel == 1 and '' or 's'), 220, 0) then
    reaper.ImGui_CloseCurrentPopup(ctx)
    -- M2 v2: Delete now uses async TTS pipeline (context regen). Trigger via
    -- pending_regen flag (perform_regenerate dispatcher routes do perform_op('delete')).
    s.pending_op_mode = 'delete'
    s.pending_regen   = true
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if theme.button_neutral(ctx, 'Cancel##rdc_cancel', 100, 0) then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

----------------------------------------------------------------------------
-- M.render_modals — delete confirm + clone confirm (Phase 11 reuse).
----------------------------------------------------------------------------
function M.render_modals(ctx, st, deps)
  local s = state.mode_state('repair')
  init_state(s)

  -- Delete confirm (M2) — rendered BEFORE clone confirm (clone returns early on
  -- non-visible, so delete must come first or wrap in if-guard).
  render_delete_confirm_modal(ctx, s)

  ----------------------------------------------------------------------------
  -- NS-G: poll diarize handle (spawned from clone confirm modal Train click
  -- when no cached diarize available). On done: branch by speaker count.
  ----------------------------------------------------------------------------
  if s.clone_diarize_handle then
    stt.poll_transcribe(s.clone_diarize_handle)
    async_op.force_error_if_stale(s.clone_diarize_handle, 'Speaker analysis')
    if s.clone_diarize_handle.status == 'done' then
      local transcript = s.clone_diarize_handle.transcript
      local pending    = s.clone_diarize_pending
      s.clone_diarize_handle  = nil
      s.clone_diarize_pending = nil
      if pending then
        local n_spk = count_unique_speakers(transcript)
        if n_spk >= 2 then
          -- Multi-speaker → schedule speaker_picker open + close clone modal
          s.clone_picker_request = {
            clean_name         = pending.clean_name,
            track              = pending.track,
            item               = pending.item,
            diarize_transcript = transcript,
            suggested_sid      = pending.suggested_sid,
          }
          -- Trigger clone modal close via flag — ImGui won't close from outside
          -- a popup directly, ale clone_confirm_pending_open=false + brak
          -- OpenPopup retrigger sprawia że modal nie pojawi się next frame.
          -- Plus user already clicked Train, modal can self-close via
          -- p_open=false path. Simplest: emulate Cancel button without setting
          -- regen_error (bo to nie cancel, to async flow continuation).
          s.clone_confirm_pending_open = false
          s.clone_confirm_close_request = true
        else
          -- Single speaker → legacy first-item flow + close clone modal
          local sample_path, ferr = vc.find_sample_audio_for_track(pending.track)
          if not sample_path then
            s.clone_train_error = ferr or 'no sample audio'
          else
            spawn_clone_train(s, pending.track, pending.clean_name, sample_path,
              { speaker_id = M.single_speaker_id(transcript) })
          end
        end
      end
    elseif s.clone_diarize_handle.status == 'error' then
      s.clone_train_error     = 'diarize: ' .. tostring(s.clone_diarize_handle.error)
      s.clone_diarize_handle  = nil
      s.clone_diarize_pending = nil
    end
  end

  ----------------------------------------------------------------------------
  -- NS-G: speaker_picker dispatch when clone_picker_request set
  ----------------------------------------------------------------------------
  if s.clone_picker_request then
    local req = s.clone_picker_request
    s.clone_picker_request = nil
    speaker_picker.open({
      diarize_transcript = req.diarize_transcript,
      source_item        = req.item,
      -- T7: "Train clone…" z zakładki/modala castingu pre-selectuje mówcę
      suggested_speaker_id = req.suggested_sid,
      on_train = function(speaker_id, regions)
        -- Build IVC sample via audio_concat (passed through voice_clone opts)
        local sample_path, ferr = vc.find_sample_audio_for_track(req.track, {
          regions     = regions,
          source_item = req.item,
        })
        if not sample_path then
          s.clone_train_error = 'concat: ' .. tostring(ferr or 'unknown')
          return
        end
        spawn_clone_train(s, req.track, req.clean_name, sample_path,
          { speaker_id = speaker_id })
      end,
      on_cancel = function()
        s.regen_error = 'Speaker picker cancelled — no clone trained.'
      end,
    })
  end

  -- Clone confirm modal (mirror Phase 11)
  -- Poll IVC training handle
  if s.clone_train_handle then
    voice_admin.poll(s.clone_train_handle)
    async_op.force_error_if_stale(s.clone_train_handle, 'Clone training')
    if s.clone_train_handle.status == 'done' then
      local voice_id = s.clone_train_handle.result
      local clean_name = s.clone_train_handle.args.name
      if s.clone_train_track then
        helpers.set_track_voice_clone(s.clone_train_track, voice_id,
          s.clone_train_handle.args.sample_path)
      end
      -- W2 M3.2 (a): klon → Cast Registry. Postać dostaje ivc_clone_id +
      -- klon jako głos 'default' (IVC jest multilingual) + link
      -- (geom_key, sid) ze snapshotu spawnu — dzięki temu drugi mówca na
      -- tym samym tracku nie "gubi" klonu pierwszego (P_EXT tracka trzyma
      -- tylko ostatni). pcall: registry nigdy nie blokuje pipeline'u.
      do
        local snap = s.clone_train_registry
        pcall(function()
          local reg = cast_registry.load_or_create()
          local label = (snap and snap.label) or clean_name
          local ch = snap and snap.sid and snap.geom_key
            and cast_registry.find_by_link(reg, snap.geom_key, snap.sid) or nil
          if ch and cast_registry.normalize_label(ch.label)
                 ~= cast_registry.normalize_label(label) then
            ch = cast_registry.rename_character(reg, ch, label) or ch
          end
          local surv = cast_registry.upsert_character(reg, {
            label        = (ch and ch.label) or label,
            ivc_clone_id = voice_id,
            voices       = { default = { voice_id = voice_id,
                                         voice_name = clean_name } },
            source_mode  = 'repair',
          })
          if surv and snap and snap.sid and snap.geom_key then
            cast_registry.link_item_speaker(reg, surv, snap.geom_key, snap.sid)
          end
          if surv then cast_registry.save(reg) end
        end)
        -- T7: klon = casting mówcy także w P_EXT itemu (kopie niosą
        -- casting), o ile user nadal jest na TYM materiale (geom match).
        if snap and snap.sid and snap.geom_key
           and snap.geom_key == registry_geom_key(s) then
          s.speaker_voices = s.speaker_voices or {}
          s.speaker_voices[snap.sid] = { voice_id = voice_id,
                                         voice_name = clean_name }
          local it2 = helpers.find_item_by_guid(s.source_item_guid)
          if it2 then stt.write_item_speaker_voices(it2, s.speaker_voices) end
          s.cast_rev = (s.cast_rev or 0) + 1
        end
        s.clone_train_registry = nil
        s.voice_suggestion_sig = nil   -- nowy klon w rejestrze → refresh
      end
      -- I1 (M0): retrigger pipeline tylko gdy user nadal jest na tracku, dla
      -- którego klon trenował. Po item-switchu klon zostaje zapisany na tracku
      -- (P_EXT wyżej), ale nie nadpisujemy s.voice ani nie wznawiamy edycji
      -- innego itemu (unrequested edit = ta sama klasa race co GUID gate).
      local cur_item  = helpers.find_item_by_guid(s.source_item_guid)
      local cur_track = cur_item and reaper.GetMediaItemTrack(cur_item)
      local resume_repair = (cur_track ~= nil and cur_track == s.clone_train_track)
      if resume_repair then
        s.voice         = { voice_id = voice_id, source = 'created', name = clean_name }
        s.pending_regen = true
      end
      s.clone_train_handle = nil
      s.clone_train_track  = nil
      -- Auto-close clone modal — user dostaje silent success + splice pipeline
      -- retriggers via pending_regen. Bez tego modal zostaje otwarty bez spinnera
      -- (handle nil → busy=false → spinner znika) + brak feedback że klon gotowy.
      s.clone_confirm_close_request = true
      s.clone_train_done_toast = resume_repair
        and ('Voice cloned · "%s" · continuing repair…'):format(clean_name)
        or  ('Voice cloned · "%s" · saved on track'):format(clean_name)
    elseif s.clone_train_handle.status == 'error' then
      s.clone_train_error  = tostring(s.clone_train_handle.error)
      s.clone_train_handle = nil
      s.clone_train_track  = nil
      s.clone_train_registry = nil
    end
  end

  if s.clone_confirm_pending_open then
    reaper.ImGui_OpenPopup(ctx, 'Train voice clone##repair_clone')
    s.clone_confirm_pending_open = false
  end

  -- NS-G: async close request po diarize multi-speaker decision (modal cedes
  -- control do speaker_picker). Realizujemy przez SetNextWindowFocus + close
  -- side-effect — actually najprostsze: pominąć Begin call, popup pozostanie
  -- otwarty internally ale nie renderuje. Lepiej: close via CloseCurrentPopup
  -- inside BeginPopupModal block (gdy visible=true). Set flag tutaj, react below.
  local force_close_clone_modal = s.clone_confirm_close_request == true
  s.clone_confirm_close_request = false

  theme.center_next_modal(ctx, 480, 0)
  theme.popup_keep_top(ctx, 'Train voice clone##repair_clone')
  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx,
    'Train voice clone##repair_clone', true,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if not visible then return end
  if not p_open then
    -- Don't emit "Cancelled" toast gdy:
    --   - clone_train_handle / clone_diarize_handle active (training w toku)
    --   - clone_picker_request set (NS-G async transition do speaker_picker)
    if not s.clone_train_handle
      and not s.clone_diarize_handle
      and not s.clone_picker_request
    then
      s.regen_error = 'Cancelled — no voice available for repair.'
    end
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  -- NS-G: async-triggered close (po multi-speaker diarize decision).
  -- Cleanly EndPopup + return — speaker_picker takes over (już openTriggered).
  if force_close_clone_modal then
    reaper.ImGui_CloseCurrentPopup(ctx)
    reaper.ImGui_EndPopup(ctx)
    return
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  -- M5-7: "Free on every plan" było NIEPRAWDĄ — IVC wymaga Starter+
  -- (zweryfikowane elevenlabs.io/pricing 2026-07-11; Free = zero cloning).
  reaper.ImGui_TextWrapped(ctx,
    'This track has no voice assigned. Train an instant voice clone (IVC) ' ..
    'from ~30s of sample audio? Requires the Starter plan or higher. ' ..
    'Upload + processing typically 10-15 seconds.')
  reaper.ImGui_PopStyleColor(ctx, 1)

  local training = s.clone_train_handle ~= nil
  local diarizing = s.clone_diarize_handle ~= nil
  local busy = training or diarizing

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Text(ctx, 'Clone name (visible in ElevenLabs):')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  reaper.ImGui_BeginDisabled(ctx, busy)
  local rv, new_name = reaper.ImGui_InputText(ctx, '##rc_clone_name', s.clone_confirm_name)
  if rv then s.clone_confirm_name = new_name end
  reaper.ImGui_EndDisabled(ctx)

  if training then
    reaper.ImGui_Spacing(ctx)
    local elapsed = util.now() - s.clone_train_handle.started_at
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xF59E0BFF)
    reaper.ImGui_Text(ctx, ('Training %s  %.1fs'):format(voice_admin.spinner_glyph(), elapsed))
    reaper.ImGui_PopStyleColor(ctx, 1)
  elseif diarizing then
    reaper.ImGui_Spacing(ctx)
    local elapsed = util.now() - s.clone_diarize_handle.started_at
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xF59E0BFF)
    reaper.ImGui_Text(ctx, ('Analyzing speakers %s  %.1fs')
      :format(voice_admin.spinner_glyph(), elapsed))
    reaper.ImGui_PopStyleColor(ctx, 1)
  elseif s.clone_train_error then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF8888FF)
    reaper.ImGui_TextWrapped(ctx, 'Error: ' .. tostring(s.clone_train_error))
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_Spacing(ctx)

  local clean_name = (s.clone_confirm_name or ''):gsub('[%c]', '')
                                                 :gsub('^%s+', ''):gsub('%s+$', '')
  reaper.ImGui_BeginDisabled(ctx, clean_name == '' or busy)
  if theme.button_primary(ctx, 'Train clone##rc_train') then
    s.clone_train_error = nil
    local item  = helpers.find_item_by_guid(s.source_item_guid)
    local track = item and reaper.GetMediaItemTrack(item)
    if not track then
      s.clone_train_error = 'item / track not found'
    elseif s.cleaned_audio_path and util.file_exists and util.file_exists(s.cleaned_audio_path) then
      -- Voice Isolator fast path: cleaned audio jest single-speaker by
      -- construction (isolator emit single voice). Skip speaker_picker.
      -- W2 M3.2: link do rejestru tylko gdy materiał ma dokładnie 1 mówcę
      -- (isolator scala głosy — przy ≥2 nie wiemy, kogo klonujemy).
      spawn_clone_train(s, track, clean_name, s.cleaned_audio_path,
        { speaker_id = (#s.speakers == 1) and s.speakers[1].id or nil })
    else
      -- NS-G: detect multi-speaker via diarize. Branch:
      --   A) Cached diarize + ≥2 speakers → close modal + open speaker_picker
      --   B) Cached diarize + 1 speaker → legacy first-item flow
      --   C) No cache → spawn diarize async, branch w consume_signals
      local ck = compute_stt_cache_key(item)
      local diarize_transcript
      if ck and ck.cache_key then
        diarize_transcript = stt.check_diarize_cache_for_item(item, ck.cache_key)
      end
      if diarize_transcript then
        local n_spk = count_unique_speakers(diarize_transcript)
        if n_spk >= 2 then
          -- Branch A: open speaker_picker post-close (T7: preferowany sid
          -- z "Train clone…" zakładki/modala castingu — one-shot)
          s.clone_picker_request = {
            clean_name         = clean_name,
            track              = track,
            item               = item,
            diarize_transcript = diarize_transcript,
            suggested_sid      = s.clone_pref_speaker_sid,
          }
          s.clone_pref_speaker_sid = nil
          reaper.ImGui_CloseCurrentPopup(ctx)
        else
          -- Branch B: legacy first-item flow (single speaker)
          local sample_path, ferr = vc.find_sample_audio_for_track(track)
          if not sample_path then
            s.clone_train_error = ferr or 'no sample audio'
          else
            spawn_clone_train(s, track, clean_name, sample_path,
              { speaker_id = M.single_speaker_id(diarize_transcript) })
          end
        end
      else
        -- Branch C: spawn diarize, wait dla consume_signals do dispatch
        local rendered_path, render_err, render_info =
          audio_render.prepare_audio_for_api(item)
        if not rendered_path then
          s.clone_train_error =
            'cannot render audio for speaker analysis: ' .. tostring(render_err)
        else
          local shift = (render_info and render_info.item_offs) or 0
          s.clone_diarize_handle = stt.spawn_diarize_for_item(item, {
            audio_path           = rendered_path,
            cache_key            = ck and ck.cache_key,
            timestamp_shift_secs = shift,
            language_code        = cfg.get_repair_language(),   -- I10: '' = auto
          })
          if s.clone_diarize_handle.status == 'error' then
            s.clone_train_error    = 'diarize: ' .. tostring(s.clone_diarize_handle.error)
            s.clone_diarize_handle = nil
          else
            s.clone_diarize_pending = {
              clean_name    = clean_name,
              track         = track,
              item          = item,
              suggested_sid = s.clone_pref_speaker_sid,
            }
            s.clone_pref_speaker_sid = nil
          end
        end
      end
    end
  end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_BeginDisabled(ctx, busy)
  if theme.button_neutral(ctx, 'Pick existing voice…##rc_pick') then
    -- Open voice_picker (existing library voices). On pick: set track voice,
    -- close clone modal, trigger pending_regen (TTS retriggers z nowym voice).
    local item = helpers.find_item_by_guid(s.source_item_guid)
    local track = item and reaper.GetMediaItemTrack(item)
    if track then
      voice_picker.open({
        state            = st,
        track_guid       = helpers.track_guid(track),
        current_voice_id = nil,
        allow_clear      = false,
        on_pick          = function(voice_id, voice_name)
          if voice_id and voice_id ~= '' then
            helpers.set_track_voice(track, voice_id, voice_name)
            s.voice         = vc.resolve_voice_for_track(track)
            s.pending_regen = true
          end
        end,
      })
      -- Close clone modal (picker opens separately; pending_regen retriggers
      -- pipeline po wybraniu).
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
  end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_BeginDisabled(ctx, busy)
  if theme.button_neutral(ctx, 'Cancel##rc_cancel') then
    s.regen_error = 'Cancelled — no voice available for repair.'
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_EndPopup(ctx)
end

----------------------------------------------------------------------------
-- M.consume_signals — emit results to reasonate.lua dla footer toast.
----------------------------------------------------------------------------
function M.consume_signals(st, deps)
  local s = state.mode_state('repair')
  init_state(s)

  -- Footer toast po successful splice (per op type)
  if s.last_result and s.last_result.ok then
    local r = s.last_result
    local op = r.op or 'replace'
    local toast
    if op == 'insert' then
      toast = ('Inserted · "%s" · TTS %.1fs · shifted %.2fs · %s'):format(
        (r.edit_text or ''):sub(1, 40),
        r.tts_elapsed or 0,
        r.shifted_secs or 0,
        r.voice_source or '?')
      if r.volume_match_applied and r.volume_gain_db and math.abs(r.volume_gain_db) >= 0.5 then
        toast = toast .. (' · vol %s%.1fdB'):format(
          r.volume_gain_db >= 0 and '+' or '', r.volume_gain_db)
      end
      if r.tempo_clamped then toast = toast .. ' · tempo clamped' end
      if r.tempo_stretch_playrate then
        toast = toast .. (' · stretched +%d%%'):format(
          math.floor((1 / r.tempo_stretch_playrate - 1) * 100 + 0.5))
      end
    elseif op == 'delete' then
      toast = ('Deleted · "%s" · removed %.2fs (30 ms crossfade)'):format(
        (r.from_text or ''):sub(1, 40),
        r.deleted_len_secs or 0)
    else  -- replace
      toast = ('Repaired · "%s" → "%s" · TTS %.1fs · %s'):format(
        (r.from_text or ''):sub(1, 30),
        (r.edit_text or ''):sub(1, 30),
        r.tts_elapsed or 0,
        r.voice_source or '?')
      if r.volume_match_applied and r.volume_gain_db and math.abs(r.volume_gain_db) >= 0.5 then
        toast = toast .. (' · vol %s%.1fdB'):format(
          r.volume_gain_db >= 0 and '+' or '', r.volume_gain_db)
      end
      if r.tempo_clamped then toast = toast .. ' · tempo clamped' end
      if r.tempo_stretch_playrate then
        toast = toast .. (' · stretched +%d%%'):format(
          math.floor((1 / r.tempo_stretch_playrate - 1) * 100 + 0.5))
      end
    end
    deps.action_msg_setter(toast, theme.COLORS.status_done)
    s.last_result = nil
    if st and st.refresh then st.refresh(true) end
  end

  -- Surface regen_error jako toast po failure
  if s.regen_error and s.regen_state == 'error' then
    deps.action_msg_setter('Repair failed: ' .. tostring(s.regen_error),
      theme.COLORS.status_error)
    s.regen_error = nil
    s.regen_state = 'idle'
  end

  -- Surface clone training success toast (modal auto-closes, user otherwise
  -- has no feedback that training completed)
  if s.clone_train_done_toast then
    deps.action_msg_setter(s.clone_train_done_toast, theme.COLORS.status_done)
    s.clone_train_done_toast = nil
  end
end

----------------------------------------------------------------------------
-- M.shutdown — cleanup atexit (no-op w M1; M4 may persist handles cleanup)
----------------------------------------------------------------------------
function M.shutdown(st)
  -- No-op w M1. Async handles cleaned przez worker scripts' own atexit.
end

return M
