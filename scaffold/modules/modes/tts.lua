-- modules/modes/tts.lua
--
-- NS-2b (M1): TTS mode real implementation — Studio-w-DAW core flow.
--
-- Workflow: text editor → voice picker → model + voice settings → Generate →
-- async TTS (voice_admin.spawn_tts) → audio item na wybranej trasie w pozycji
-- kursora edycji. Per-item P_EXT (is_tts_output, tts_text, tts_voice_id,
-- tts_model_id, tts_voice_settings, tts_generated_at) → M3 doda listę
-- wygenerowanych items + take cycling + lock + regen.
--
-- M1 scope (in this file):
--   - Multi-line text editor + character counter per-model limit
--   - Voice picker reuse (callback mode — opts.on_pick)
--   - Model selector: v3 / Multilingual v2 / Turbo v2.5 / Flash v2.5
--   - v3 stability: 3 discrete modes (Creative / Natural / Robust)
--   - Other models: stability slider 0-1
--   - Similarity / Style / Speed sliders
--   - Speaker boost checkbox (disabled w v3)
--   - Target track dropdown + "Stwórz nową trasę TTS"
--   - Generate (Cmd+Enter) → spawn_tts → import audio item
--   - Cursor advance after Generate (config option)
--
-- M2 will add: audio tags palette (right sidebar with categories).
-- M3 will add: per-item history list on target track.

local helpers      = require 'modules.reaper_helpers'
local theme        = require 'modules.theme'
local cfg          = require 'modules.config'
local util         = require 'modules.util'
local voice_admin  = require 'modules.voice_admin'
local audio_tags   = require 'modules.audio_tags'
local tts_enhance  = require 'modules.tts_enhance' -- Enhance: prompty + walidator (pure)
local dialogue_script = require 'modules.dialogue_script' -- import skryptu txt/md (pure)
local voice_picker = require 'modules.gui.voice_picker'
local preview      = require 'modules.preview'
local stt          = require 'modules.stt'         -- NS-2d: dialogue split diarize
local json         = require 'modules.lib.json'
local async_op     = require 'modules.async_op'    -- audit M1-2/M2-2: stale + retry consts

local M = {}
M.NAME        = 'tts'
M.LABEL       = 'TTS'
M.DESCRIPTION = 'Text-to-speech generation'
M.DISABLED    = false

----------------------------------------------------------------------------
-- Model definitions (per ElevenLabs docs/models 2026-05).
-- Char limits per docs; "audio_tags" flag = inline [tag] support; "speaker_boost"
-- = whether use_speaker_boost field accepted (false → omit z voice_settings).
----------------------------------------------------------------------------
local MODELS = {
  {
    id                     = 'eleven_v3',
    label                  = 'v3',
    char_limit             = 5000,
    audio_tags             = true,
    supports_speaker_boost = false,
    tooltip                = 'Latest (GA March 2026). Inline audio tags (emotion, SFX, accent). 70+ languages. 5000 char limit.',
  },
  {
    id                     = 'eleven_multilingual_v2',
    label                  = 'Multilingual v2',
    char_limit             = 10000,
    audio_tags             = false,
    supports_speaker_boost = true,
    tooltip                = 'Production-tested. 29 languages. 10000 chars. Speaker boost supported.',
  },
  -- M7: Flash PRZED Turbo (oficjalne docs: "use Flash in all use cases";
  -- turbo deprecated — zostaje na końcu dla starych projektów).
  {
    id                     = 'eleven_flash_v2_5',
    label                  = 'Flash v2.5',
    char_limit             = 40000,
    audio_tags             = false,
    supports_speaker_boost = true,
    tooltip                = 'Fast + 50% cheaper per char. 32 languages. 40000 chars (long texts).',
  },
  {
    id                     = 'eleven_turbo_v2_5',
    label                  = 'Turbo v2.5 (legacy)',
    char_limit             = 40000,
    audio_tags             = false,
    supports_speaker_boost = true,
    tooltip                = 'Deprecated — ElevenLabs recommends Flash v2.5 for all use cases. Kept for old projects.',
  },
}

-- v3 stability is discretized into 3 modes (per ElevenLabs docs).
local V3_STABILITY_MODES = {
  { id = 'creative', label = 'Creative', value = 0.0,
    tooltip = 'Max expression + audio tags. Hallucination risk.' },
  { id = 'natural',  label = 'Natural',  value = 0.5,
    tooltip = 'Balanced (default). Responds to audio tags.' },
  { id = 'robust',   label = 'Robust',   value = 1.0,
    tooltip = 'Most stable. Ignores most audio tags.' },
}

-- Output format read live from config (Settings → TTS mode). Default
-- mp3_44100_192 (Creator+ tier). User can switch to mp3_44100_128 (free) or
-- pcm_44100 (Pro+, uncompressed). Read at each spawn — value can change
-- mid-session without restart.

-- Validation / retry constants.
-- MIN_TEXT_CHARS: ElevenLabs TTS may reject or produce degenerate audio for
-- inputs under 3 non-whitespace chars; pre-validate before spawn.
-- TTS_RETRY_BACKOFF: mirror job_manager S2S retry (429 is typically transient
-- Eleven concurrency throttling — exponential backoff resolves).
local MIN_TEXT_CHARS    = 3
-- Retry constants: wspólne źródło w modules/async_op.lua (audit M2-2).
-- Lokalna schedule_retry zostaje (szersze matchowanie błędów rate-limit +
-- respawn z _spawn_opts — specyfika TTS), ale wartości są współdzielone.
local MAX_TTS_RETRIES   = async_op.MAX_RETRIES
local TTS_RETRY_BACKOFF = async_op.RETRY_BACKOFF

local function is_rate_limit_error(err)
  if not err then return false end
  local lower = tostring(err):lower()
  return (lower:find('429', 1, true) ~= nil)
      or (lower:find('rate limit', 1, true) ~= nil)
      or (lower:find('rate_limit', 1, true) ~= nil)
      or (lower:find('too many', 1, true) ~= nil)
end

-- Schedule a retry on the handle if error is 429-class and budget remains.
-- Returns true if scheduled (caller keeps handle, sets status text);
-- false if final (caller clears handle + shows error).
local function schedule_retry(handle)
  if not is_rate_limit_error(handle.error) then return false end
  if not handle._spawn_opts then return false end
  local next_count = (handle._retry_count or 0) + 1
  if next_count > MAX_TTS_RETRIES then return false end
  local backoff = TTS_RETRY_BACKOFF[next_count] or 4
  handle._retry_at    = util.now() + backoff
  handle._retry_count = next_count
  return true
end

local function find_model(id)
  for _, m in ipairs(MODELS) do
    if m.id == id then return m end
  end
  return MODELS[1]  -- fallback to v3
end

-- mark_dirty defined up here (before EEL callbacks + request_insert_at_cursor
-- which use it) due to Lua lexical scoping: a local function only sees symbols
-- declared above it. Other persistence helpers (serialize/save/load) sit near
-- init_state since they're only called from there.
local function mark_dirty(s)
  s._dirty    = true
  s._dirty_at = util.now()
end

----------------------------------------------------------------------------
-- EEL callback dla InputTextMultiline — eksponuje cursor position do Lua
-- (cursor_pos slot, R) i pozwala przesunąć kursor po Lua-side text mutation
-- (set_cursor flag + target_cursor slot). Numeric-only approach unika
-- niepewnego ImGui_Function_SetValue_String (może nie być Lua-exposed) —
-- używamy WYŁĄCZNIE Function_GetValue / SetValue które są 100% Lua-supported.
--
-- Pattern: na każdą klatkę gdy InputText focused → EEL CallbackAlways fires
-- → cursor_pos := CursorPos (Lua reads via GetValue). Lua-side tag click:
-- (1) read cursor_pos, (2) mutate s.text_buffer (insert at cursor), (3) set
-- target_cursor + set_cursor flag, (4) set pending_focus_input. Next frame:
-- SetKeyboardFocusHere → InputText focused → EEL fires → CursorPos :=
-- target_cursor → caret jumps past insertion. No EEL string passing needed.
----------------------------------------------------------------------------
local EEL_INPUT_CALLBACK = [[
  EventFlag == ITF_callback_always ? (
    cursor_pos = CursorPos;
    set_cursor > 0 ? (
      CursorPos = target_cursor;
      set_cursor = 0;
    );
  );
]]

local _input_cb = nil

local function get_input_callback(ctx)
  if _input_cb then return _input_cb end
  if not reaper.ImGui_CreateFunctionFromEEL then return nil end
  local ok, cb = pcall(reaper.ImGui_CreateFunctionFromEEL, EEL_INPUT_CALLBACK)
  if not ok or not cb then return nil end
  pcall(reaper.ImGui_Function_SetValue, cb, 'ITF_callback_always',
    reaper.ImGui_InputTextFlags_CallbackAlways())
  pcall(reaper.ImGui_Function_SetValue, cb, 'set_cursor',    0)
  pcall(reaper.ImGui_Function_SetValue, cb, 'cursor_pos',    0)
  pcall(reaper.ImGui_Function_SetValue, cb, 'target_cursor', 0)
  pcall(reaper.ImGui_Attach, ctx, cb)
  _input_cb = cb
  return cb
end

-- Request insertion of `text_to_insert` at current cursor position.
-- Reads cursor from EEL (last value when InputText was focused) → mutates
-- s.text_buffer in Lua at that position → tells EEL to move CursorPos past
-- the inserted text on next focus. Returns true on success.
local function request_insert_at_cursor(cb, text_to_insert, s)
  if not cb or not text_to_insert or text_to_insert == '' then return false end
  local ok_get, cursor = pcall(reaper.ImGui_Function_GetValue, cb, 'cursor_pos')
  if not ok_get then return false end
  cursor = math.floor(cursor or 0)
  local txt = s.text_buffer or ''
  if cursor < 0 then cursor = 0 end
  if cursor > #txt then cursor = #txt end
  s.text_buffer = txt:sub(1, cursor) .. text_to_insert .. txt:sub(cursor + 1)
  pcall(reaper.ImGui_Function_SetValue, cb, 'target_cursor', cursor + #text_to_insert)
  pcall(reaper.ImGui_Function_SetValue, cb, 'set_cursor',    1)
  s.pending_focus_input = true
  mark_dirty(s)
  return true
end

----------------------------------------------------------------------------
-- State persistence (NS-2b polish): editor + voice + settings survive .rpp
-- save/load and REAPER restart via ProjExtState. Save debounced
-- DIRTY_DEBOUNCE_S after last mutation; load once per session in init_state.
-- Only durable fields persisted (no handles / status / row_handles).
----------------------------------------------------------------------------
local DIRTY_DEBOUNCE_S   = 0.5
local PROJ_KEY_TTS_STATE = 'tts_state'

-- (mark_dirty defined earlier — before EEL block which references it.)

local function serialize_state(s)
  return json.encode({
    -- Single TTS mode (existing — NS-2b)
    text_buffer       = s.text_buffer or '',
    selected_voice    = s.selected_voice,
    model_id          = s.model_id,
    v3_stability      = s.v3_stability,
    stability         = s.stability,
    similarity        = s.similarity,
    style             = s.style,
    speed             = s.speed,
    speaker_boost     = s.speaker_boost,
    target_track_guid = s.target_track_guid,
    -- NS-2c: sub-mode toggle + dialogue durable state
    sub_mode             = s.sub_mode or 'single',
    dialogue_speakers    = s.dialogue_speakers or {},
    dialogue_lines       = s.dialogue_lines or {},
    dialogue_v3_stability = s.dialogue_v3_stability or 'natural',
    dialogue_seed        = s.dialogue_seed or 0,
    -- Enhance: durable ustawienia (oba sub-mode'y współdzielą)
    enhance_intensity    = s.enhance_intensity or 'standard',
    enhance_note         = s.enhance_note or '',
    enhance_punct        = s.enhance_punct or false,
    palette_hidden       = s.palette_hidden or false,
    patch_split_mode     = s.patch_split_mode or false,
  })
end

local function save_state_to_proj(s, proj)
  local ok, payload = pcall(serialize_state, s)
  if not ok or type(payload) ~= 'string' then return end
  reaper.SetProjExtState(proj or 0, 'Reasonate', PROJ_KEY_TTS_STATE, payload)
end

-- Restore individual fields with type guards — partial-corrupt payload still
-- loads valid fields and falls back to defaults for invalid/missing ones.
local function load_state_from_proj(s, proj)
  local rv, payload = reaper.GetProjExtState(proj or 0, 'Reasonate', PROJ_KEY_TTS_STATE)
  if rv ~= 1 or payload == nil or payload == '' then return false end
  local ok, decoded = pcall(json.decode, payload)
  if not ok or type(decoded) ~= 'table' then return false end
  if type(decoded.text_buffer) == 'string' then s.text_buffer = decoded.text_buffer end
  if type(decoded.selected_voice) == 'table'
     and type(decoded.selected_voice.voice_id) == 'string'
     and decoded.selected_voice.voice_id ~= '' then
    s.selected_voice = {
      voice_id = decoded.selected_voice.voice_id,
      name     = decoded.selected_voice.name or '',
    }
  end
  if type(decoded.model_id) == 'string'         then s.model_id = decoded.model_id end
  if type(decoded.v3_stability) == 'string'     then s.v3_stability = decoded.v3_stability end
  if type(decoded.stability) == 'number'        then s.stability = decoded.stability end
  if type(decoded.similarity) == 'number'       then s.similarity = decoded.similarity end
  if type(decoded.style) == 'number'            then s.style = decoded.style end
  if type(decoded.speed) == 'number'            then s.speed = decoded.speed end
  if type(decoded.speaker_boost) == 'boolean'   then s.speaker_boost = decoded.speaker_boost end
  if type(decoded.target_track_guid) == 'string' then s.target_track_guid = decoded.target_track_guid end
  -- NS-2c: dialogue state extends
  if type(decoded.sub_mode) == 'string' and
     (decoded.sub_mode == 'single' or decoded.sub_mode == 'dialogue') then
    s.sub_mode = decoded.sub_mode
  end
  if type(decoded.dialogue_speakers) == 'table' then
    local out = {}
    for _, sp in ipairs(decoded.dialogue_speakers) do
      if type(sp) == 'table' and type(sp.id) == 'string' and type(sp.label) == 'string' then
        -- normalize_speaker_voice_settings is defined w dialogue helpers block
        -- (poniżej apply_durable_defaults / load_state_from_proj). Inline normalize
        -- helper jest niezbędny — używamy default + type-checked fields tutaj.
        local vs_raw = sp.voice_settings
        local vs_out = {
          stability        = 0.5,
          similarity_boost = 0.75,
          style            = 0.0,
          speed            = 1.0,
          speaker_boost    = true,
        }
        if type(vs_raw) == 'table' then
          if type(vs_raw.stability)        == 'number'  then vs_out.stability        = vs_raw.stability end
          if type(vs_raw.similarity_boost) == 'number'  then vs_out.similarity_boost = vs_raw.similarity_boost end
          if type(vs_raw.style)            == 'number'  then vs_out.style            = vs_raw.style end
          if type(vs_raw.speed)            == 'number'  then vs_out.speed            = vs_raw.speed end
          if type(vs_raw.speaker_boost)    == 'boolean' then vs_out.speaker_boost    = vs_raw.speaker_boost end
        end
        out[#out + 1] = {
          id             = sp.id,
          label          = sp.label,
          voice_id       = (type(sp.voice_id)   == 'string') and sp.voice_id   or '',
          voice_name     = (type(sp.voice_name) == 'string') and sp.voice_name or '',
          voice_settings = vs_out,
          description    = (type(sp.description) == 'string' and sp.description ~= '')
                             and sp.description or nil,
        }
      end
    end
    s.dialogue_speakers = out
  end
  if type(decoded.dialogue_lines) == 'table' then
    local out = {}
    for _, ln in ipairs(decoded.dialogue_lines) do
      if type(ln) == 'table' and type(ln.id) == 'string' and type(ln.speaker_id) == 'string' then
        out[#out + 1] = {
          id         = ln.id,
          speaker_id = ln.speaker_id,
          text       = (type(ln.text) == 'string') and ln.text or '',
        }
      end
    end
    s.dialogue_lines = out
  end
  if type(decoded.dialogue_v3_stability) == 'string' then
    s.dialogue_v3_stability = decoded.dialogue_v3_stability
  end
  if type(decoded.dialogue_seed) == 'number' then
    s.dialogue_seed = decoded.dialogue_seed
  end
  if type(decoded.enhance_intensity) == 'string'
     and tts_enhance.find_intensity(decoded.enhance_intensity).id == decoded.enhance_intensity then
    s.enhance_intensity = decoded.enhance_intensity
  end
  if type(decoded.enhance_note) == 'string' then
    s.enhance_note = decoded.enhance_note
  end
  if type(decoded.enhance_punct) == 'boolean' then
    s.enhance_punct = decoded.enhance_punct
  end
  if type(decoded.palette_hidden) == 'boolean' then
    s.palette_hidden = decoded.palette_hidden
  end
  if type(decoded.patch_split_mode) == 'boolean' then
    s.patch_split_mode = decoded.patch_split_mode
  end
  return true
end

-- Durable fields (persisted to ProjExtState). Reset to defaults before each
-- (re)load — handles fresh project with no payload AND project switch where
-- old project's values must not leak through.
local function apply_durable_defaults(s)
  s.text_buffer       = ''
  s.selected_voice    = nil
  s.model_id          = 'eleven_v3'
  s.v3_stability      = 'natural'
  s.stability         = 0.5
  s.similarity        = 0.75
  s.style             = 0.0
  s.speed             = 1.0
  s.speaker_boost     = true
  s.target_track_guid = nil
  -- NS-2c: dialogue defaults
  s.sub_mode              = 'single'
  s.dialogue_speakers     = {}
  s.dialogue_lines        = {}
  s.dialogue_v3_stability = 'natural'
  s.dialogue_seed         = 0
  -- Enhance defaults (punct = opt-in "pauses & emphasis": …/CAPS od LLM)
  s.enhance_intensity     = 'standard'
  s.enhance_note          = ''
  s.enhance_punct         = false
  -- Paleta tagów: chowana na życzenie (W3 2026-06-11), durable per projekt
  s.palette_hidden        = false
  -- Line patch: false (default) = dialog zostaje JEDNYM plikiem, regen linii
  -- ląduje na tracku POD dialogiem; true = pierwsze [Re-gen] tnie na klocki
  -- per kwestia (user decision 2026-06-11, druga iteracja po live-tescie)
  s.patch_split_mode      = false
end

-- Transient fields (NOT persisted; in-memory only). Cleared on project switch
-- because handles + GUIDs point into the old project's tracks/items.
local function clear_transient(s)
  s.gen_handle             = nil
  s.gen_status_text        = nil
  s.gen_status_color       = nil
  s.gen_target_track       = nil
  s.gen_voice_meta         = nil
  s.gen_append_to_guid     = nil
  s.row_handles            = {}
  s.selected_tts_guid      = nil
  s.tag_cat_collapsed      = {}
  s.pending_focus_input    = false
  -- Variants flow (B#1): N concurrent-by-sequence; first variant creates item
  -- (or uses append target), subsequent variants append takes to that item
  -- via force_append_to_guid override.
  s.variants_remaining     = 0
  s.force_append_to_guid   = nil
  s.variant_respawn_pending = false
  -- Voice presets (B#6): "Save as…" modal name buffer.
  s.preset_save_name       = ''
  -- NS-2c: dialogue transient state
  s.dialogue_gen_handle             = nil
  s.dialogue_gen_status_text        = nil
  s.dialogue_gen_status_color       = nil
  s.dialogue_gen_target_track       = nil
  s.dialogue_gen_append_to_guid     = nil
  s.dialogue_solo_handles           = {}     -- M2 per-line preview handles
  s.dialogue_force_append_to_guid   = nil    -- Re-gen whole take (s4) append override
  s.dialogue_focused_line_id        = nil    -- last clicked line input (palette target)
  s.cast_preset_save_name           = ''     -- M3 cast preset modal buffer
  s.dialogue_row_handles            = {}     -- M3 per-row dialogue regen handles
  -- NS-2d: dialogue split per speaker (diarize STT → split master mp3)
  s.dialogue_split_handle              = nil  -- STT diarize handle
  s.dialogue_split_master_guid         = nil  -- master item guid we'll split
  s.dialogue_split_master_position     = nil  -- D_POSITION of master (timeline-time)
  s.dialogue_split_master_audio_path   = nil  -- audio file path for new items
  s.dialogue_split_speakers_chronological = nil  -- our speakers in inputs order
  -- NS-2e Phase A: per-speaker voice settings popup state
  s._open_speaker_settings_pending  = nil    -- defer flag — set in context menu, opened next frame
  s._editing_speaker_voice_settings_id = nil -- speaker id whose settings popup is active
  -- NS-2e Phase B: per-region regen handles (split items)
  s.dialogue_split_regen_handles    = {}     -- { [split_item_guid]: voice_admin handle }
  -- Enhance: handle + snapshot do Revert (wskazują w teksty bieżącego projektu)
  s.enhance_handle                  = nil
  s.enhance_revert                  = nil
  -- Per-line playback z take'a (forced alignment, lazy + cache per audio)
  s.take_align_handle               = nil
  s.take_align_path                 = nil   -- audio, do którego pasują words
  s.take_align_words                = nil   -- non-space tokeny {text,start,end}
  s.take_align_pending              = nil   -- {input_index, line_id} po done
  s.take_play_line_id               = nil   -- linia grana przez ▶ (shared play_id)
  -- Playhead → podświetlenie aktywnej kwestii (mirror Dubbing/Repair W3 s3)
  s.playhead_line_id                = nil
  s.dialogue_scroll_line_id         = nil   -- one-shot scroll przy odtwarzaniu
end

----------------------------------------------------------------------------
-- Lazy state init. state.mode_state('tts') returns the persisted-in-memory
-- table; we set defaults on first access. Survives mode switches in-session.
-- Detects project switch by comparing active proj handle — on switch, flushes
-- dirty state to old project and reloads from new project.
----------------------------------------------------------------------------
local function init_state(state)
  local s = state.mode_state('tts')
  local current_proj = reaper.EnumProjects(-1)

  if s._initialized and s._loaded_proj == current_proj then
    return s
  end

  -- Project switch (or first init). Flush dirty state to OLD project handle
  -- before reloading from new project (in-memory handle stays valid as long
  -- as old project is still loaded in another REAPER tab).
  if s._initialized and s._dirty and s._loaded_proj then
    pcall(save_state_to_proj, s, s._loaded_proj)
  end

  apply_durable_defaults(s)
  clear_transient(s)
  load_state_from_proj(s, current_proj)
  s._loaded_proj = current_proj
  s._dirty       = false
  s._dirty_at    = 0
  s._initialized = true
  return s
end

----------------------------------------------------------------------------
-- Build voice_settings table dla spawn_tts opts. v3 uses discretized stability;
-- non-v3 uses slider value. use_speaker_boost omitted dla v3.
----------------------------------------------------------------------------
local function build_voice_settings(s, model)
  local stability_value = s.stability
  if model.id == 'eleven_v3' then
    for _, mode in ipairs(V3_STABILITY_MODES) do
      if mode.id == s.v3_stability then
        stability_value = mode.value
        break
      end
    end
  end
  local vs = {
    stability        = stability_value,
    similarity_boost = s.similarity,
    style            = s.style,
    speed            = s.speed,
  }
  if model.supports_speaker_boost then
    vs.use_speaker_boost = s.speaker_boost
  end
  return vs
end

----------------------------------------------------------------------------
-- Per-track TTS defaults (B#5). Each Generate auto-saves the current voice +
-- model + voice_settings as P_EXT on the target track. Selecting a track in
-- the dropdown loads those saved defaults (no-op if track has none).
-- For v3 stability, the discretized numeric value round-trips through
-- v3_stability_from_value into the matching mode id.
----------------------------------------------------------------------------
local function v3_stability_from_value(val)
  if type(val) ~= 'number' then return 'natural' end
  local best_id  = 'natural'
  local best_dst = math.huge
  for _, mode in ipairs(V3_STABILITY_MODES) do
    local d = math.abs((mode.value or 0.5) - val)
    if d < best_dst then best_dst = d; best_id = mode.id end
  end
  return best_id
end

local function save_track_tts_defaults(tr, voice_id, voice_name, model_id, vs_json)
  if not tr then return end
  helpers.pext_track_set(tr, 'tts_default_voice_id',      voice_id   or '')
  helpers.pext_track_set(tr, 'tts_default_voice_name',    voice_name or '')
  helpers.pext_track_set(tr, 'tts_default_model_id',      model_id   or '')
  helpers.pext_track_set(tr, 'tts_default_voice_settings', vs_json   or '')
end

-- B#6: build a preset record from current state (named save target).
local function build_current_preset(s)
  return {
    voice_id      = s.selected_voice and s.selected_voice.voice_id or '',
    voice_name    = s.selected_voice and s.selected_voice.name or '',
    model_id      = s.model_id,
    v3_stability  = s.v3_stability,
    stability     = s.stability,
    similarity    = s.similarity,
    style         = s.style,
    speed         = s.speed,
    speaker_boost = s.speaker_boost,
  }
end

-- B#6: apply a stored preset to current state. Missing fields keep current
-- values (forward-compat with future preset shape additions).
local function apply_preset(s, preset)
  if type(preset) ~= 'table' then return end
  if type(preset.voice_id) == 'string' and preset.voice_id ~= '' then
    s.selected_voice = { voice_id = preset.voice_id, name = preset.voice_name or '' }
  end
  if type(preset.model_id) == 'string'         then s.model_id = preset.model_id end
  if type(preset.v3_stability) == 'string'     then s.v3_stability = preset.v3_stability end
  if type(preset.stability) == 'number'        then s.stability = preset.stability end
  if type(preset.similarity) == 'number'       then s.similarity = preset.similarity end
  if type(preset.style) == 'number'            then s.style = preset.style end
  if type(preset.speed) == 'number'            then s.speed = preset.speed end
  if type(preset.speaker_boost) == 'boolean'   then s.speaker_boost = preset.speaker_boost end
  mark_dirty(s)
end

local function apply_track_tts_defaults(s, tr)
  if not tr then return false end
  local v_id   = helpers.pext_track_get(tr, 'tts_default_voice_id')
  if not v_id or v_id == '' then return false end
  local v_name = helpers.pext_track_get(tr, 'tts_default_voice_name')
  local m_id   = helpers.pext_track_get(tr, 'tts_default_model_id')
  local vs_raw = helpers.pext_track_get(tr, 'tts_default_voice_settings')

  s.selected_voice = { voice_id = v_id, name = v_name or '' }
  if m_id and m_id ~= '' then s.model_id = m_id end
  if vs_raw and vs_raw ~= '' then
    local ok, vs = pcall(json.decode, vs_raw)
    if ok and type(vs) == 'table' then
      if type(vs.stability) == 'number' then
        s.stability = vs.stability
        if s.model_id == 'eleven_v3' then
          s.v3_stability = v3_stability_from_value(vs.stability)
        end
      end
      if type(vs.similarity_boost) == 'number'   then s.similarity = vs.similarity_boost end
      if type(vs.style) == 'number'              then s.style = vs.style end
      if type(vs.speed) == 'number'              then s.speed = vs.speed end
      if type(vs.use_speaker_boost) == 'boolean' then s.speaker_boost = vs.use_speaker_boost end
    end
  end
  mark_dirty(s)
  return true
end

----------------------------------------------------------------------------
-- Resolve target track: jeśli s.target_track_guid wskazuje na istniejący
-- track → użyj; inaczej fallback do pierwszego tracka lub stwórz nowy "TTS".
----------------------------------------------------------------------------
local function ensure_target_track(s)
  if s.target_track_guid and s.target_track_guid ~= '' then
    local tr = helpers.find_track_by_guid(s.target_track_guid)
    if tr then return tr end
  end
  if reaper.CountTracks(0) > 0 then
    local tr = reaper.GetTrack(0, 0)
    s.target_track_guid = reaper.GetTrackGUID(tr)
    mark_dirty(s)
    return tr
  end
  -- Brak żadnego tracka — stwórz nowy "TTS"
  reaper.InsertTrackAtIndex(0, true)
  local tr = reaper.GetTrack(0, 0)
  reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', 'TTS', true)
  s.target_track_guid = reaper.GetTrackGUID(tr)
  mark_dirty(s)
  return tr
end

local function list_tracks_for_dropdown()
  local out = {}
  for tr in helpers.iter_tracks() do
    out[#out + 1] = {
      guid = reaper.GetTrackGUID(tr),
      name = helpers.track_name(tr) or '',
      idx  = helpers.track_index(tr),
    }
  end
  return out
end

----------------------------------------------------------------------------
-- Random seed dla TTS regen (NS-2b). Defined here (before spawn_generate)
-- żeby spawn_generate widziało symbol w upvalue scope; Lua locals są lexical,
-- a M3 block helpers definiowane są poniżej spawn_generate.
----------------------------------------------------------------------------
local function random_seed()
  return math.random(1, 2147483647)
end

----------------------------------------------------------------------------
-- Detect "append-take target": single TTS item selected on target track →
-- spawn_generate appends take instead of creating new item (per locked
-- design "history-first" when user edits text of selected row and clicks
-- Generate). Returns item_guid or nil.
----------------------------------------------------------------------------
local function detect_append_target(target_track, force_guid)
  -- Variants flow override: pin to the item that received the previous take.
  if force_guid and target_track then
    local item = helpers.find_item_by_guid(force_guid)
    if item and reaper.GetMediaItemTrack(item) == target_track then
      return force_guid
    end
  end
  if not target_track then return nil end
  if reaper.CountSelectedMediaItems(0) ~= 1 then return nil end
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then return nil end
  if reaper.GetMediaItemTrack(item) ~= target_track then return nil end
  if helpers.pext_item_get(item, 'is_tts_output') ~= '1' then return nil end
  return helpers.item_guid(item)
end

----------------------------------------------------------------------------
-- Spawn generate: walidacja → ustal voice_settings → spawn_tts handle.
----------------------------------------------------------------------------
local function spawn_generate(s, deps)
  if not s.selected_voice then
    s.gen_status_text  = 'Pick a voice before generating.'
    s.gen_status_color = theme.COLORS.status_stale
    return
  end
  if s.text_buffer == nil or s.text_buffer == '' then
    s.gen_status_text  = 'Type text to generate.'
    s.gen_status_color = theme.COLORS.status_stale
    return
  end

  local stripped = s.text_buffer:gsub('%s+', '')
  if util.utf8_len(stripped) < MIN_TEXT_CHARS then
    s.gen_status_text  = ('Text too short (need at least %d non-whitespace characters).'):format(MIN_TEXT_CHARS)
    s.gen_status_color = theme.COLORS.status_stale
    return
  end

  local model = find_model(s.model_id)
  local char_count = util.utf8_len(s.text_buffer)
  if char_count > model.char_limit then
    s.gen_status_text  = ('Text exceeds %s model limit (%d > %d chars).'):format(
      model.label, char_count, model.char_limit)
    s.gen_status_color = theme.COLORS.status_error
    return
  end

  local voice_settings = build_voice_settings(s, model)
  local target_track   = ensure_target_track(s)

  -- M3: gdy zaznaczony pojedynczy TTS item na target track → append take
  -- do tego itemu (history-first); inaczej nowy item w pozycji kursora.
  -- B#1: force_append_to_guid (variants flow) overrides selection-based detect.
  local append_guid = detect_append_target(target_track, s.force_append_to_guid)

  s.gen_target_track    = target_track
  s.gen_append_to_guid  = append_guid
  s.gen_voice_meta = {
    voice_id   = s.selected_voice.voice_id,
    voice_name = s.selected_voice.name,
    model_id   = model.id,
  }

  local seed = random_seed()
  local spawn_opts = {
    voice_id       = s.selected_voice.voice_id,
    text           = s.text_buffer,
    model_id       = model.id,
    voice_settings = voice_settings,
    output_format  = cfg.get_tts_output_format(),
    seed           = seed,
  }
  local handle = voice_admin.spawn_tts(spawn_opts)

  if handle.status == 'error' then
    s.gen_status_text   = 'Error: ' .. tostring(handle.error or 'unknown')
    s.gen_status_color  = theme.COLORS.status_error
    s.gen_target_track  = nil
    s.gen_voice_meta    = nil
    s.gen_append_to_guid = nil
    return
  end

  handle._spawn_opts  = spawn_opts
  handle._retry_count = 0
  s.gen_handle       = handle
  local total_variants = s.variants_remaining or 0
  if total_variants > 1 then
    -- Mid-batch progress: total - remaining + 1 = current index, total is "n to go"
    s.gen_status_text = ('Variant %d/%d · %d chars…'):format(
      (s._variants_initial or total_variants) - total_variants + 1,
      (s._variants_initial or total_variants),
      char_count)
  else
    s.gen_status_text  = append_guid
      and ('Appending take to selected item · %d chars…'):format(char_count)
      or  ('Generating %d chars…'):format(char_count)
  end
  s.gen_status_color = theme.COLORS.text_dim
  if deps and deps.action_msg_setter then
    deps.action_msg_setter(
      ('TTS: generating %d chars with voice %s'):format(char_count,
        s.selected_voice.name or '?'),
      theme.COLORS.text_dim)
  end
end

----------------------------------------------------------------------------
-- Variants flow (B#1): generate N takes (N=3 default) with different seeds,
-- all appended to a single item. First variant creates the item (or uses
-- append target if user selected one); subsequent variants pin to that item
-- via force_append_to_guid. Sequential — each spawn_generate fires from the
-- previous variant's import done in consume_signals.
----------------------------------------------------------------------------
local function spawn_variants(s, deps, n)
  if s.gen_handle then return end
  if (s.variants_remaining or 0) > 0 then return end
  n = math.max(2, math.min(10, n or 3))
  s.variants_remaining  = n
  s._variants_initial   = n           -- for "Variant X/Y" status display
  spawn_generate(s, deps)
  -- If spawn_generate failed validation (empty text / no voice / over limit),
  -- gen_handle stays nil. Reset variants state.
  if not s.gen_handle then
    s.variants_remaining = 0
    s._variants_initial  = nil
  end
end

-- Finalize variant flow after a successful import. item_guid = the item that
-- just received a take (created or appended-to). If more variants remain,
-- pin force_append_to_guid + flag respawn for consume_signals.
local function finalize_variants(s, item_guid)
  if (s.variants_remaining or 0) <= 1 then
    s.variants_remaining     = 0
    s._variants_initial      = nil
    s.force_append_to_guid   = nil
    s.variant_respawn_pending = false
    return
  end
  s.variants_remaining       = s.variants_remaining - 1
  s.force_append_to_guid     = item_guid
  s.variant_respawn_pending  = true
end

-- Cancel active Generate / Variants flow. Per invariant #7 (CLAUDE.md) we
-- don't kill the external worker.sh — it finishes naturally and leaves an
-- orphan sentinel that the next REAPER session cleans up. Stopping polling
-- and clearing state is enough for the UI.
local function cancel_generation(s)
  s.gen_handle              = nil
  s.gen_target_track        = nil
  s.gen_voice_meta          = nil
  s.gen_append_to_guid      = nil
  s.variants_remaining      = 0
  s._variants_initial       = nil
  s.force_append_to_guid    = nil
  s.variant_respawn_pending = false
  s.gen_status_text         = 'Cancelled.'
  s.gen_status_color        = theme.COLORS.text_dim
end

----------------------------------------------------------------------------
-- On TTS done: utwórz audio item na target track w pozycji edit cursora.
-- Item dostaje pełne metadane (P_EXT) — M3 użyje do per-item history list.
-- Cursor advance (config opt-out): edit_cursor → cursor_pos + item_length.
----------------------------------------------------------------------------
local function build_peaks(source_obj)
  if reaper.PCM_Source_BuildPeaks(source_obj, 0) > 0 then
    local safety = 1000
    while reaper.PCM_Source_BuildPeaks(source_obj, 1) > 0 and safety > 0 do
      safety = safety - 1
    end
    reaper.PCM_Source_BuildPeaks(source_obj, 2)
  end
end

-- Take name format: "Take N · HH:MM:SS · Voice · seed=XXXXXXXX · "excerpt""
-- N + seed make sibling takes distinguishable when excerpt collides; timestamp
-- gives quick chronology in REAPER's take strip / take history menu.
local function take_name_for(voice_name, text, take_num, seed)
  local cleaned = (text or ''):gsub('[\r\n\t]', ' ')
  local excerpt = cleaned
  if util.utf8_len(cleaned) > 25 then
    excerpt = cleaned:sub(1, (utf8.offset(cleaned, 26) or (#cleaned + 1)) - 1) .. '…'
  end
  local prefix = take_num and ('Take %d · '):format(take_num) or ''
  local seed_str = ''
  if seed and tonumber(seed) and seed > 0 then
    seed_str = (' · seed=%08x'):format(math.floor(seed))
  end
  return ('%s%s · %s%s · "%s"'):format(
    prefix, os.date('%H:%M:%S'), voice_name or '?', seed_str, excerpt)
end

local function import_tts_result(s, deps)
  local handle = s.gen_handle
  if not handle or handle.status ~= 'done' then return end

  local audio_path     = handle.result
  local target_track   = s.gen_target_track
  local append_to_guid = s.gen_append_to_guid
  local meta           = s.gen_voice_meta or {}

  local function reset_gen()
    s.gen_handle         = nil
    s.gen_target_track   = nil
    s.gen_voice_meta     = nil
    s.gen_append_to_guid = nil
  end

  if not audio_path or not util.file_exists(audio_path) then
    s.gen_status_text  = 'Error: no audio file after generation.'
    s.gen_status_color = theme.COLORS.status_error
    reset_gen()
    return
  end
  if not target_track then
    s.gen_status_text  = 'Error: target track gone before import.'
    s.gen_status_color = theme.COLORS.status_error
    reset_gen()
    return
  end

  local source_obj = reaper.PCM_Source_CreateFromFile(audio_path)
  if not source_obj then
    s.gen_status_text  = 'Error: PCM_Source_CreateFromFile returned nil for ' .. audio_path
    s.gen_status_color = theme.COLORS.status_error
    reset_gen()
    return
  end

  local src_len = reaper.GetMediaSourceLength(source_obj) or 0
  local ok_vs, vs_json = pcall(json.encode,
    (handle.args and handle.args.voice_settings) or {})

  -- M3: append-take mode — dopisz take do zaznaczonego itemu zamiast nowego.
  local append_item = append_to_guid and helpers.find_item_by_guid(append_to_guid) or nil
  if append_item then
    reaper.Undo_BeginBlock()
    local new_take = reaper.AddTakeToMediaItem(append_item)
    reaper.SetMediaItemTake_Source(new_take, source_obj)
    build_peaks(source_obj)
    local take_idx = reaper.CountTakes(append_item)
    local take_seed = handle.args and handle.args.seed
    reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME',
      take_name_for(meta.voice_name, s.text_buffer, take_idx, take_seed), true)
    reaper.SetActiveTake(new_take)

    -- Extend item length jeśli new take dłuższy (TTS +/- 20% przy nowym seedzie).
    local cur_len = reaper.GetMediaItemInfo_Value(append_item, 'D_LENGTH') or 0
    if src_len > cur_len then
      reaper.SetMediaItemLength(append_item, src_len, false)
    end

    -- Update P_EXT do najnowszego tekstu/voice/settings (♻ regen weźmie z tego).
    helpers.pext_item_set(append_item, 'tts_text',          s.text_buffer or '')
    helpers.pext_item_set(append_item, 'tts_voice_id',      meta.voice_id   or '')
    helpers.pext_item_set(append_item, 'tts_voice_name',    meta.voice_name or '')
    helpers.pext_item_set(append_item, 'tts_model_id',      meta.model_id   or '')
    helpers.pext_item_set(append_item, 'tts_voice_settings', ok_vs and vs_json or '')
    helpers.pext_item_set(append_item, 'tts_generated_at',  tostring(os.time()))

    reaper.UpdateItemInProject(append_item)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock('Reasonate: TTS append take', -1)

    save_track_tts_defaults(target_track, meta.voice_id, meta.voice_name,
                             meta.model_id, ok_vs and vs_json or '')

    if not handle.from_cache then
      cfg.add_tts_chars_used(handle.character_cost or util.utf8_len(handle.args and handle.args.text or ''))
    end

    s.gen_status_text  = ('Take appended · %.1fs · take %d')
      :format(src_len, reaper.CountTakes(append_item))
    s.gen_status_color = theme.COLORS.status_done
    reset_gen()
    finalize_variants(s, append_to_guid)
    if deps and deps.action_msg_setter then
      deps.action_msg_setter(
        ('TTS take appended · %.1fs · %s'):format(src_len, meta.voice_name or '?'),
        theme.COLORS.status_done)
    end
    return
  end

  -- Fresh item path (no append target).
  local cursor_pos = reaper.GetCursorPosition() or 0

  reaper.Undo_BeginBlock()
  local new_item = reaper.AddMediaItemToTrack(target_track)
  local new_take = reaper.AddTakeToMediaItem(new_item)
  reaper.SetMediaItemTake_Source(new_take, source_obj)
  reaper.SetMediaItemPosition(new_item, cursor_pos, false)
  reaper.SetMediaItemLength(new_item, src_len, false)
  build_peaks(source_obj)
  local fresh_seed = handle.args and handle.args.seed
  reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME',
    take_name_for(meta.voice_name, s.text_buffer, 1, fresh_seed), true)

  -- P_EXT metadata (M3 list rendering scan reads these).
  helpers.pext_item_set(new_item, 'is_tts_output',     '1')
  helpers.pext_item_set(new_item, 'tts_text',          s.text_buffer or '')
  helpers.pext_item_set(new_item, 'tts_voice_id',      meta.voice_id   or '')
  helpers.pext_item_set(new_item, 'tts_voice_name',    meta.voice_name or '')
  helpers.pext_item_set(new_item, 'tts_model_id',      meta.model_id   or '')
  helpers.pext_item_set(new_item, 'tts_voice_settings', ok_vs and vs_json or '')
  helpers.pext_item_set(new_item, 'tts_generated_at',  tostring(os.time()))

  reaper.UpdateItemInProject(new_item)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Reasonate: TTS Generate', -1)

  save_track_tts_defaults(target_track, meta.voice_id, meta.voice_name,
                           meta.model_id, ok_vs and vs_json or '')

  if not handle.from_cache then
    cfg.add_tts_chars_used(handle.character_cost or util.utf8_len(handle.args and handle.args.text or ''))
  end

  if cfg.get_tts_advance_cursor() then
    reaper.SetEditCurPos(cursor_pos + src_len, false, false)
  end

  s.gen_status_text  = ('Done · %.1fs · track %s'):format(
    src_len, helpers.track_name(target_track) or '?')
  s.gen_status_color = theme.COLORS.status_done
  reset_gen()
  finalize_variants(s, helpers.item_guid(new_item))

  if deps and deps.action_msg_setter then
    deps.action_msg_setter(
      ('TTS done · %.1fs · %s'):format(src_len, meta.voice_name or '?'),
      theme.COLORS.status_done)
  end
end

----------------------------------------------------------------------------
-- NS-2c: Dialogue helpers + spawn + import.
--
-- Architecture: sub-mode w TTS panel (s.sub_mode='dialogue'). Sekcja Mówcy
-- u góry (named cast A/B/C…) + lista linii turn-by-turn (line.speaker_id +
-- line.text). Generate buduje inputs[] z linii i wywołuje voice_admin.spawn_dialogue
-- → POST /v1/text-to-dialogue → binary mp3 → audio item z P_EXT.is_tts_dialogue_output.
----------------------------------------------------------------------------

local DIALOGUE_MAX_SPEAKERS = 10    -- API limit unique voice_ids
local DIALOGUE_MAX_CHARS    = 2000  -- API soft limit ('reliable generation')
local DIALOGUE_LIMIT_AMBER  = 1500
local DIALOGUE_LIMIT_SOFT   = 500

-- NS-2d: padding wokół każdego split region. Word-level timestamps z Scribe
-- diarization mark moment artykulacji słowa, NIE pełny attack/decay envelope
-- (~50-150ms naturalnie). Bez padding split items urywają się tuż za końcem
-- słowa → audio brzmi clipped vs continuous master. 120ms pad każda strona
-- = pokrywa typical phonetic release + STT timing inaccuracy.
--
-- NS-2e fix (2026-05-12): pad clamped przez **half-gap** do adjacent regions —
-- żaden speaker NIE wchodzi w teren drugiego. Fair split between neighbors:
-- jeśli gap między region N a N+1 wynosi G, każdy dostaje min(PAD, G/2).
-- Przy G >= 2*PAD każdy dostaje pełen PAD (free pad zone). Przy G < 2*PAD
-- meet w środku silence (no overlap, no gap). Edge regions (first/last):
-- pre/post clamped przez 0 / master_len (no phantom neighbor).
local DIALOGUE_SPLIT_PAD_S  = 0.12

-- ID generator — stable, unique within session. os.time() seconds + 16-bit
-- random. Collision unlikely w human-pace user interactions; ID nigdy nie
-- pojawia się user-side (label A/B/C jest dla user).
local function gen_dialogue_id(prefix)
  return string.format('%s%x_%x', prefix or 'x',
    math.floor(os.time()) % 0xffffffff, math.random(0, 0xffff))
end

local function next_speaker_label(s)
  local used = {}
  for _, sp in ipairs(s.dialogue_speakers or {}) do used[sp.label] = true end
  for i = 0, 25 do
    local letter = string.char(65 + i)
    if not used[letter] then return letter end
  end
  return ('Speaker %d'):format(#(s.dialogue_speakers or {}) + 1)
end

local function find_speaker_by_id(s, speaker_id)
  if not speaker_id or speaker_id == '' then return nil end
  for _, sp in ipairs(s.dialogue_speakers or {}) do
    if sp.id == speaker_id then return sp end
  end
  return nil
end

-- NS-2e: per-speaker voice_settings — used przez SOLO preview + per-region
-- regen. Dialogue endpoint NIE supports per-input voice_settings (jeden global
-- stability per request — API ograniczenie), więc te settings używane TYLKO
-- dla single-voice TTS calls (SOLO + per-region regen). v3 model honors
-- głównie stability; pozostałe pola dla future non-v3 use.
local function default_speaker_voice_settings()
  return {
    stability        = 0.5,
    similarity_boost = 0.75,
    style            = 0.0,
    speed            = 1.0,
    speaker_boost    = true,
  }
end

-- Normalize partial / corrupted voice_settings z legacy state lub user JSON.
-- Each field validated z fallback do default.
local function normalize_speaker_voice_settings(vs)
  local d = default_speaker_voice_settings()
  if type(vs) ~= 'table' then return d end
  local out = {}
  out.stability        = (type(vs.stability)        == 'number') and vs.stability        or d.stability
  out.similarity_boost = (type(vs.similarity_boost) == 'number') and vs.similarity_boost or d.similarity_boost
  out.style            = (type(vs.style)            == 'number') and vs.style            or d.style
  out.speed            = (type(vs.speed)            == 'number') and vs.speed            or d.speed
  out.speaker_boost    = (type(vs.speaker_boost)    == 'boolean') and vs.speaker_boost    or d.speaker_boost
  return out
end

local function add_dialogue_speaker(s)
  s.dialogue_speakers = s.dialogue_speakers or {}
  if #s.dialogue_speakers >= DIALOGUE_MAX_SPEAKERS then return nil end
  local sp = {
    id             = gen_dialogue_id('s'),
    label          = next_speaker_label(s),
    voice_id       = '',
    voice_name     = '',
    voice_settings = default_speaker_voice_settings(),
  }
  table.insert(s.dialogue_speakers, sp)
  mark_dirty(s)
  return sp
end

local function remove_dialogue_speaker(s, speaker_id)
  s.dialogue_speakers = s.dialogue_speakers or {}
  for i, sp in ipairs(s.dialogue_speakers) do
    if sp.id == speaker_id then
      table.remove(s.dialogue_speakers, i)
      mark_dirty(s)
      return true
    end
  end
  return false
end

-- M3: build cast preset (named save format) z current dialogue_speakers.
-- speaker_id NIE jest persisted — apply zwraca świeże ids.
-- NS-2e: voice_settings persisted per speaker (deep copy via shallow table — JSON
-- safe because all values are primitives).
local function build_current_dialogue_cast(s)
  local out = {}
  for _, sp in ipairs(s.dialogue_speakers or {}) do
    out[#out + 1] = {
      label          = sp.label,
      voice_id       = sp.voice_id   or '',
      voice_name     = sp.voice_name or '',
      voice_settings = normalize_speaker_voice_settings(sp.voice_settings),
      description    = sp.description,
    }
  end
  return out
end

-- M3: apply cast preset. Replaces dialogue_speakers (regenerowane ids).
-- Existing dialogue_lines z label-matching mapping retain speaker_id;
-- te z orphaned speaker_id → wymagają user reassign (validation catches).
local function apply_dialogue_cast(s, cast)
  if type(cast) ~= 'table' then return end
  -- Map old label → old speaker_id → new speaker_id for line re-mapping.
  local old_label_to_id = {}
  for _, sp in ipairs(s.dialogue_speakers or {}) do
    old_label_to_id[sp.label] = sp.id
  end
  local new_label_to_id = {}
  s.dialogue_speakers = {}
  for _, sp in ipairs(cast) do
    if type(sp) == 'table' and type(sp.label) == 'string' and sp.label ~= '' then
      local new_id = gen_dialogue_id('s')
      s.dialogue_speakers[#s.dialogue_speakers + 1] = {
        id             = new_id,
        label          = sp.label,
        voice_id       = (type(sp.voice_id)   == 'string') and sp.voice_id   or '',
        voice_name     = (type(sp.voice_name) == 'string') and sp.voice_name or '',
        voice_settings = normalize_speaker_voice_settings(sp.voice_settings),
        -- W2 M3.3: opis postaci (Cast Registry / glossary) — tooltip na chipie
        description    = (type(sp.description) == 'string' and sp.description ~= '')
                           and sp.description or nil,
      }
      new_label_to_id[sp.label] = new_id
    end
  end
  -- Re-map lines: if line's speaker_id matched a label in old cast and that
  -- label also exists in new cast → point line to new id.
  local old_id_to_label = {}
  for label, id in pairs(old_label_to_id) do old_id_to_label[id] = label end
  for _, ln in ipairs(s.dialogue_lines or {}) do
    local lbl = old_id_to_label[ln.speaker_id]
    if lbl and new_label_to_id[lbl] then
      ln.speaker_id = new_label_to_id[lbl]
    end
    -- Else: line keeps stale speaker_id → validation warns user.
  end
  mark_dirty(s)
end

----------------------------------------------------------------------------
-- W2 M3.3 (PHASE-W2 §4): "Cast from project" — konsument Cast Registry.
-- Registry proponuje, nigdy nie nadpisuje cicho: jawny klik + wybór
-- Replace/Merge (MB yes/no/cancel — wzorzec import_dialogue_script).
-- Merge: mówcy o tym samym labelu (fold case) dostają głos+opis z rejestru,
-- reszta zostaje; nowe postaci dopisane w limicie 10. Linie zachowują
-- mapowanie po labelu (apply_dialogue_cast).
----------------------------------------------------------------------------
local function apply_project_cast(s)
  local registry = require 'modules.cast_registry'
  local reg = registry.load()
  if registry.is_empty(reg) then
    reaper.MB(
      'No project cast found yet.\n\n'
        .. 'Assign voices to speakers in Dubbing mode first —\n'
        .. 'they are collected into the project cast automatically.',
      'Cast from project', 0)
    return false
  end
  local chars = registry.characters(reg)

  local mode = 'replace'
  if #(s.dialogue_speakers or {}) > 0 then
    local preview = {}
    for i, ch in ipairs(chars) do
      if i > 8 then
        preview[#preview + 1] = ('… and %d more'):format(#chars - 8)
        break
      end
      local _, vname = registry.pick_voice(ch)
      preview[#preview + 1] = ('• %s%s'):format(ch.label,
        vname and vname ~= '' and (' — ' .. vname) or '')
    end
    local r = reaper.MB(
      ('Project cast (%d):\n%s\n\n'):format(#chars, table.concat(preview, '\n'))
        .. 'Yes — replace current speakers with the project cast\n'
        .. 'No — merge (update matching speakers, add new ones)\n'
        .. 'Cancel — abort',
      'Cast from project', 3)
    if r == 2 then return false end
    mode = (r == 6) and 'replace' or 'merge'
  end

  local function entry_from_char(ch)
    local vid, vname = registry.pick_voice(ch)
    return {
      label       = ch.label,
      voice_id    = vid or '',
      voice_name  = vname or '',
      description = ch.description,
    }
  end

  local cast = {}
  if mode == 'merge' then
    local by_norm, used = {}, {}
    for _, ch in ipairs(chars) do
      by_norm[registry.normalize_label(ch.label)] = ch
    end
    for _, sp in ipairs(s.dialogue_speakers or {}) do
      local ch = by_norm[registry.normalize_label(sp.label)]
      if ch then
        used[registry.normalize_label(ch.label)] = true
        local vid, vname = registry.pick_voice(ch)
        cast[#cast + 1] = {
          label          = sp.label,
          voice_id       = (vid and vid ~= '') and vid or sp.voice_id,
          voice_name     = (vid and vid ~= '') and (vname or '') or sp.voice_name,
          voice_settings = sp.voice_settings,
          description    = ch.description or sp.description,
        }
      else
        cast[#cast + 1] = {
          label          = sp.label,
          voice_id       = sp.voice_id,
          voice_name     = sp.voice_name,
          voice_settings = sp.voice_settings,
          description    = sp.description,
        }
      end
    end
    for _, ch in ipairs(chars) do
      if not used[registry.normalize_label(ch.label)] then
        cast[#cast + 1] = entry_from_char(ch)
      end
    end
  else
    for _, ch in ipairs(chars) do
      cast[#cast + 1] = entry_from_char(ch)
    end
  end

  local skipped = 0
  if #cast > DIALOGUE_MAX_SPEAKERS then
    skipped = #cast - DIALOGUE_MAX_SPEAKERS
    for i = #cast, DIALOGUE_MAX_SPEAKERS + 1, -1 do table.remove(cast, i) end
  end

  apply_dialogue_cast(s, cast)
  s.dialogue_gen_status_text = ('Project cast applied · %d %s%s.'):format(
    #cast, #cast == 1 and 'speaker' or 'speakers',
    skipped > 0 and (' · %d skipped (max %d)'):format(skipped, DIALOGUE_MAX_SPEAKERS) or '')
  s.dialogue_gen_status_color = theme.COLORS.status_done
  return true
end

local function add_dialogue_line(s, speaker_id)
  s.dialogue_lines = s.dialogue_lines or {}
  local sp_id = speaker_id
  if not sp_id or sp_id == '' then
    -- Default: NASTĘPNY mówca po mówcy ostatniej linii (rotacja po liście —
    -- naturalna naprzemienna rozmowa; user feedback 2026-06-11). Mówca
    -- ostatniej linii usunięty z listy / brak linii → pierwszy mówca.
    local speakers = s.dialogue_speakers or {}
    local last = s.dialogue_lines[#s.dialogue_lines]
    if last and last.speaker_id and last.speaker_id ~= '' and #speakers > 0 then
      for i, sp in ipairs(speakers) do
        if sp.id == last.speaker_id then
          sp_id = speakers[(i % #speakers) + 1].id
          break
        end
      end
    end
    if not sp_id or sp_id == '' then
      sp_id = (speakers[1] and speakers[1].id) or ''
    end
  end
  local ln = {
    id         = gen_dialogue_id('l'),
    speaker_id = sp_id,
    text       = '',
  }
  table.insert(s.dialogue_lines, ln)
  mark_dirty(s)
  return ln
end

local function remove_dialogue_line(s, line_id)
  s.dialogue_lines = s.dialogue_lines or {}
  for i, ln in ipairs(s.dialogue_lines) do
    if ln.id == line_id then
      table.remove(s.dialogue_lines, i)
      mark_dirty(s)
      return true
    end
  end
  return false
end

local function move_dialogue_line(s, line_id, direction)
  s.dialogue_lines = s.dialogue_lines or {}
  for i, ln in ipairs(s.dialogue_lines) do
    if ln.id == line_id then
      local j = i + direction
      if j < 1 or j > #s.dialogue_lines then return false end
      s.dialogue_lines[i], s.dialogue_lines[j] = s.dialogue_lines[j], s.dialogue_lines[i]
      mark_dirty(s)
      return true
    end
  end
  return false
end

----------------------------------------------------------------------------
-- Import skryptu dialogowego z pliku .txt/.md (W3 2026-06-11, user request).
-- Parser pure w modules/dialogue_script.lua (headless-tested); tu mapowanie:
-- mówcy po label case-insensitive (istniejący zachowują głosy), nowi dodawani
-- bez głosu w limicie API. Niepuste linie w panelu → MB Replace/Append/Cancel.
----------------------------------------------------------------------------
local function import_dialogue_script(s)
  local function fail(msg)
    s.dialogue_gen_status_text  = 'Import: ' .. msg
    s.dialogue_gen_status_color = theme.COLORS.status_error
  end
  if not reaper.GetUserFileNameForRead then
    return fail('file dialog unavailable in this REAPER build.')
  end
  local ok, fn = reaper.GetUserFileNameForRead('', 'Import dialogue script (.txt / .md)', '')
  if not ok or not fn or fn == '' then return end
  local f = io.open(fn, 'rb')
  if not f then return fail('cannot open file.') end
  local raw = f:read('*all') or ''
  f:close()
  local parsed, perr = dialogue_script.parse(raw)
  if not parsed then return fail(perr or 'unrecognized format.') end

  -- Mówcy: istniejący po label (case-insensitive), nowi w limicie głosów.
  local existing = {}
  for _, sp in ipairs(s.dialogue_speakers or {}) do
    existing[sp.label:lower()] = sp.id
  end
  local order, label_of, new_needed = {}, {}, 0
  for _, pl in ipairs(parsed) do
    local key = pl.speaker:lower()
    if not label_of[key] then
      label_of[key] = pl.speaker
      order[#order + 1] = key
      if not existing[key] then new_needed = new_needed + 1 end
    end
  end
  if #(s.dialogue_speakers or {}) + new_needed > DIALOGUE_MAX_SPEAKERS then
    return fail(('script needs %d new speakers — over the %d-voice limit.')
      :format(new_needed, DIALOGUE_MAX_SPEAKERS))
  end

  -- Panel ma już niepuste linie → user decyduje co z nimi.
  local has_lines = false
  for _, ln in ipairs(s.dialogue_lines or {}) do
    if (ln.text or '') ~= '' then
      has_lines = true
      break
    end
  end
  if has_lines then
    local r = reaper.MB(
      'Replace the current lines with the imported script?\n\n' ..
      'Yes — replace all lines\n' ..
      'No — append below existing lines\n' ..
      'Cancel — abort import',
      'Import dialogue script', 3)
    if r == 2 then return end
    if r == 6 then
      s.dialogue_lines = {}
      s.enhance_revert = nil   -- snapshot Revert wskazywał w usunięte linie
    end
  end

  for _, key in ipairs(order) do
    if not existing[key] then
      local sp = add_dialogue_speaker(s)
      if sp then
        sp.label = label_of[key]
        existing[key] = sp.id
      end
    end
  end
  local added = 0
  for _, pl in ipairs(parsed) do
    local ln = add_dialogue_line(s, existing[pl.speaker:lower()])
    ln.text = util.normalize_whitespace(pl.text)
    added = added + 1
  end
  mark_dirty(s)
  s.dialogue_gen_status_text  = ('Imported %d %s · %d %s.'):format(
    added, added == 1 and 'line' or 'lines',
    #order, #order == 1 and 'speaker' or 'speakers')
  s.dialogue_gen_status_color = theme.COLORS.status_done
end

local function count_dialogue_chars(s)
  local total = 0
  for _, ln in ipairs(s.dialogue_lines or {}) do
    total = total + util.utf8_len(ln.text or '')
  end
  return total
end

local function count_unique_voice_ids(s)
  local seen = {}
  for _, ln in ipairs(s.dialogue_lines or {}) do
    if ln.text and ln.text ~= '' then
      local sp = find_speaker_by_id(s, ln.speaker_id)
      if sp and sp.voice_id and sp.voice_id ~= '' then
        seen[sp.voice_id] = true
      end
    end
  end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  return n
end

-- Returns (ok, msg). ok=true → spawn-ready; ok=false → status text dla user.
local function validate_dialogue(s)
  if not s.dialogue_speakers or #s.dialogue_speakers == 0 then
    return false, 'Add at least one speaker.'
  end
  if not s.dialogue_lines or #s.dialogue_lines == 0 then
    return false, 'Add at least one line.'
  end
  local has_text = false
  for i, ln in ipairs(s.dialogue_lines) do
    if ln.text and ln.text ~= '' then
      has_text = true
      local sp = find_speaker_by_id(s, ln.speaker_id)
      if not sp then
        return false, ('Line %d: no speaker assigned.'):format(i)
      end
      if not sp.voice_id or sp.voice_id == '' then
        return false, ('Line %d: speaker %s has no voice picked.'):format(i, sp.label)
      end
    end
  end
  if not has_text then
    return false, 'All lines are empty.'
  end
  local total = count_dialogue_chars(s)
  if total < MIN_TEXT_CHARS then
    return false, ('Total text too short (need at least %d chars).'):format(MIN_TEXT_CHARS)
  end
  if total > DIALOGUE_MAX_CHARS then
    return false, ('Total %d chars exceeds %d char limit.'):format(total, DIALOGUE_MAX_CHARS)
  end
  local uniq = count_unique_voice_ids(s)
  if uniq > DIALOGUE_MAX_SPEAKERS then
    return false, ('%d unique voices used — API max %d.'):format(uniq, DIALOGUE_MAX_SPEAKERS)
  end
  return true, nil
end

-- Build inputs[] for API. Skip empty lines.
local function build_dialogue_inputs(s)
  local out = {}
  for _, ln in ipairs(s.dialogue_lines or {}) do
    if ln.text and ln.text ~= '' then
      local sp = find_speaker_by_id(s, ln.speaker_id)
      if sp and sp.voice_id and sp.voice_id ~= '' then
        out[#out + 1] = { text = ln.text, voice_id = sp.voice_id }
      end
    end
  end
  return out
end

local function dialogue_stability_value(s)
  local id = s.dialogue_v3_stability or 'natural'
  for _, mode in ipairs(V3_STABILITY_MODES) do
    if mode.id == id then return mode.value end
  end
  return 0.5
end

-- Append target detect for dialogue: zaznaczony pojedynczy dialogue item na
-- target track → append take zamiast nowego itemu.
local function detect_dialogue_append_target(target_track, force_guid)
  if force_guid and target_track then
    local item = helpers.find_item_by_guid(force_guid)
    if item and reaper.GetMediaItemTrack(item) == target_track then
      return force_guid
    end
  end
  if not target_track then return nil end
  if reaper.CountSelectedMediaItems(0) ~= 1 then return nil end
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then return nil end
  if reaper.GetMediaItemTrack(item) ~= target_track then return nil end
  if helpers.pext_item_get(item, 'is_tts_dialogue_output') ~= '1' then return nil end
  return helpers.item_guid(item)
end

----------------------------------------------------------------------------
-- spawn_generate_dialogue: validate → build inputs → spawn → handle setup.
----------------------------------------------------------------------------
-- Forward decl (Lua lexical scoping — KNOWN-ISSUES): definicja niżej (~2360),
-- a spawn_generate_dialogue używa jej w guardzie "nic się nie zmieniło".
local dialogue_take_sync

local function spawn_generate_dialogue(s, deps)
  local ok, err = validate_dialogue(s)
  if not ok then
    s.dialogue_gen_status_text  = err or 'Validation failed.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end

  local inputs = build_dialogue_inputs(s)
  if #inputs == 0 then
    s.dialogue_gen_status_text  = 'No non-empty lines to generate.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end

  -- User 2026-07-11 ("po co Generate ma robić się jeszcze raz?"): Generate
  -- przy NIEZMIENIONYCH liniach nie renderuje i nie biluje ponownie —
  -- ostatni take już JEST tym dźwiękiem. Świeża interpretacja = jawny
  -- "Re-gen whole take" (omija guard przez force_append + świeży salt).
  if not s.dialogue_force_append_to_guid then
    local sync = dialogue_take_sync and dialogue_take_sync(s)
    if sync and sync.audio_path and not sync.dirty then
      s.dialogue_gen_status_text  =
        'Nothing changed since the last take — press ▶ on a line to listen, or "Re-gen whole take" for a fresh interpretation.'
      s.dialogue_gen_status_color = theme.COLORS.status_stale
      return
    end
  end

  local settings = { stability = dialogue_stability_value(s) }
  local target_track = ensure_target_track(s)
  local append_guid  = detect_dialogue_append_target(target_track, s.dialogue_force_append_to_guid)

  s.dialogue_gen_target_track   = target_track
  s.dialogue_gen_append_to_guid = append_guid

  -- User 2026-07-11 (mirror decyzji dubbingu W2 M1 §8 q6): seed
  -- DETERMINISTYCZNY per treść — powtórny Generate tej samej rozmowy (np.
  -- po restarcie REAPER albo skasowaniu itemu) = cache hit, darmowa kopia.
  -- Re-gen whole take podbija salt → świeży render z nową interpretacją.
  local seed
  if s.dialogue_seed_salt and s.dialogue_seed_salt > 0 then
    seed = s.dialogue_seed_salt
  else
    local parts = {}
    for _, inp in ipairs(inputs) do
      parts[#parts + 1] = (inp.voice_id or '') .. '\31' .. (inp.text or '')
    end
    seed = util.simple_hash(table.concat(parts, '\30') .. '|'
      .. tostring(dialogue_stability_value(s))) % 4294967295
    if seed == 0 then seed = 1 end
  end
  local spawn_opts = {
    inputs        = inputs,
    settings      = settings,
    model_id      = 'eleven_v3',
    output_format = cfg.get_tts_output_format(),
    seed          = seed,
    -- M5-2: alignment całego pliku w odpowiedzi Generate — playhead/▶ per
    -- linia bez osobnego (płatnego) wywołania alignmentu po imporcie.
    with_timestamps = true,
  }

  local handle = voice_admin.spawn_dialogue(spawn_opts)

  if handle.status == 'error' then
    s.dialogue_gen_status_text    = 'Error: ' .. tostring(handle.error or 'unknown')
    s.dialogue_gen_status_color   = theme.COLORS.status_error
    s.dialogue_gen_target_track   = nil
    s.dialogue_gen_append_to_guid = nil
    return
  end

  handle._spawn_opts  = spawn_opts
  handle._retry_count = 0
  s.dialogue_gen_handle = handle

  local total_chars = count_dialogue_chars(s)
  s.dialogue_gen_status_text = append_guid
    and ('Appending take · %d chars · %d lines…'):format(total_chars, #inputs)
    or  ('Generating dialogue · %d chars · %d lines…'):format(total_chars, #inputs)
  s.dialogue_gen_status_color = theme.COLORS.text_dim

  if deps and deps.action_msg_setter then
    deps.action_msg_setter(
      ('TTS dialogue: generating %d lines (%d chars)'):format(#inputs, total_chars),
      theme.COLORS.text_dim)
  end
end

local function cancel_dialogue_generation(s)
  s.dialogue_gen_handle              = nil
  s.dialogue_gen_target_track        = nil
  s.dialogue_gen_append_to_guid      = nil
  s.dialogue_force_append_to_guid    = nil
  -- NS-2d: also abort any pending diarize split (worker process continues w
  -- tle per invariant #7 — orphan sentinel sprzątany przez przyszły cleanup).
  s.dialogue_split_handle              = nil
  s.dialogue_split_master_guid         = nil
  s.dialogue_split_master_position     = nil
  s.dialogue_split_master_audio_path   = nil
  s.dialogue_split_speakers_chronological = nil
  s.dialogue_gen_status_text         = 'Cancelled.'
  s.dialogue_gen_status_color        = theme.COLORS.text_dim
end

-- spawn_dialogue_variants USUNIĘTE 2026-06-11 (user decision): Variants ×3
-- w dialogu = 3× rachunek za CAŁĄ rozmowę — bez sensu przy multi-speaker
-- (korekty robi się per linia / Re-gen take). Pompa respawn + licznik
-- dialogue_variants_* wycięte przy reszcie C/D (2026-06-11); z mechaniki
-- został TYLKO dialogue_force_append_to_guid — używa go regen_dialogue_take
-- (Re-gen whole take), import czyści flagę po zużyciu.

----------------------------------------------------------------------------
-- NS-2c M2: per-line SOLO preview. Click ▶ na linii → spawn /v1/text-to-speech
-- (SINGLE-voice endpoint, NIE dialogue) z tekstem TEJ linii i głosem speakera.
-- Wynik audio → CF_Preview play. Cache hit deterministic (seed=0 → ten sam
-- klucz dla niezmiennego tekstu/głosu/settings → instant powtórka).
--
-- Idle UI: ▶ (klik = spawn). Spawn-in-flight: spinner. Preview gra: ■ (klik = stop).
-- Double-click bezpieczny (no-op gdy spawn in-flight; toggle stop gdy gra).
----------------------------------------------------------------------------
local function spawn_solo_preview(s, line, speaker)
  -- User-caught 2026-07-11: ciche returny = klik bez ŻADNEJ reakcji.
  if not line or not line.text or line.text == '' then
    s.dialogue_gen_status_text  = 'Line preview: type some text first.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end
  if not speaker or not speaker.voice_id or speaker.voice_id == '' then
    s.dialogue_gen_status_text  = ('Line preview: assign a voice to speaker %s first (click the speaker name).')
      :format(speaker and speaker.label or '?')
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end

  local prev_id = 'tts_dialogue_solo_' .. line.id

  -- Toggle stop if this line's preview is currently playing.
  if preview.is_playing(prev_id) then
    preview.stop()
    return
  end

  -- Ignore double-click while spawn in-flight.
  s.dialogue_solo_handles = s.dialogue_solo_handles or {}
  if s.dialogue_solo_handles[line.id] then return end

  -- NS-2e: per-speaker voice_settings (right-click chip → Voice settings...).
  -- Fallback do defaults gdy speaker nie ma jeszcze settings (legacy state).
  local vs = normalize_speaker_voice_settings(speaker.voice_settings)
  local settings = {
    stability        = vs.stability,
    similarity_boost = vs.similarity_boost,
    style            = vs.style,
    speed            = vs.speed,
  }
  local handle = voice_admin.spawn_tts({
    text           = line.text,
    voice_id       = speaker.voice_id,
    model_id       = 'eleven_v3',
    voice_settings = settings,
    output_format  = cfg.get_tts_output_format(),
    seed           = 0,  -- deterministic dla cache reuse
  })

  if handle.status == 'error' then
    s.dialogue_gen_status_text  = 'Preview error: ' .. tostring(handle.error or 'unknown')
    s.dialogue_gen_status_color = theme.COLORS.status_error
    return
  end
  -- Cache hit synthetic done → play od razu (handle.from_cache=true skips counter).
  if handle.status == 'done' then
    preview.play_file(handle.result, prev_id, { volume = 0.8 })
    return
  end
  s.dialogue_solo_handles[line.id] = handle
end

-- Take name dla dialogue: "TTS-Dialog · HH:MM:SS · N speakers · M lines · seed= · "excerpt""
local function dialogue_take_name(inputs, take_num, seed)
  local first_text = (inputs[1] and inputs[1].text) or ''
  local excerpt = first_text:gsub('[\r\n\t]', ' '):sub(1, 25)
  if #first_text > 25 then excerpt = excerpt .. '…' end
  local n_unique = 0
  do
    local seen = {}
    for _, it in ipairs(inputs) do
      if not seen[it.voice_id] then seen[it.voice_id] = true; n_unique = n_unique + 1 end
    end
  end
  local prefix = take_num and ('Take %d · '):format(take_num) or ''
  local seed_str = ''
  if seed and tonumber(seed) and seed > 0 then
    seed_str = (' · seed=%08x'):format(math.floor(seed))
  end
  return ('%sTTS-Dialog · %s · %d speakers · %d lines%s · "%s"'):format(
    prefix, os.date('%H:%M:%S'), n_unique, #inputs, seed_str, excerpt)
end

----------------------------------------------------------------------------
-- NS-2d: maybe_spawn_dialogue_split — po imporcie master mp3, jeśli config
-- flag ON, spawn STT diarize → później perform_dialogue_split utworzy N
-- speaker tracks z per-region items.
--
-- Skip gdy:
--   - flag OFF (default)
--   - split_handle już active (rapid Generate × 2 — older split lost)
--   - master_item lub audio_path missing
----------------------------------------------------------------------------
local function maybe_spawn_dialogue_split(s, master_item, audio_path, inputs, master_position)
  if not cfg.get_tts_dialogue_split_per_speaker() then return end
  if not master_item or not audio_path or audio_path == '' then return end
  if s.dialogue_split_handle then
    -- Previous split still pending — skip this one (rare edge case, see KNOWN-ISSUES)
    return
  end

  -- Build chronological speakers list z inputs (unique voice_ids w encounter order).
  -- Tym wskaźnikiem map'ujemy diarized speaker_0/1/.. (Scribe response) → naszych
  -- A/B/C cast speakers.
  local seen = {}
  local chrono = {}
  for _, inp in ipairs(inputs or {}) do
    if inp.voice_id and inp.voice_id ~= '' and not seen[inp.voice_id] then
      seen[inp.voice_id] = true
      -- Find our speaker matching this voice_id (used dla label).
      local matched = nil
      for _, candidate in ipairs(s.dialogue_speakers or {}) do
        if candidate.voice_id == inp.voice_id then
          matched = candidate
          break
        end
      end
      chrono[#chrono + 1] = matched or {
        voice_id   = inp.voice_id,
        voice_name = '?',
        label      = ('S%d'):format(#chrono + 1),
      }
    end
  end

  if #chrono == 0 then return end

  -- Spawn diarize STT (file-based, no cache, status pending).
  local handle = stt.spawn_diarize(audio_path)
  if handle.status == 'error' then
    s.dialogue_gen_status_text  = 'Split prep failed: ' .. tostring(handle.error or 'unknown')
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end
  s.dialogue_split_handle                 = handle
  s.dialogue_split_master_guid            = helpers.item_guid(master_item)
  s.dialogue_split_master_position        = master_position or 0
  s.dialogue_split_master_audio_path      = audio_path
  s.dialogue_split_speakers_chronological = chrono
end

----------------------------------------------------------------------------
-- NS-2d: perform_dialogue_split — wykonywane gdy split_handle.status='done'.
-- Parse transcript.words → speech regions → mapping diarized speaker_id na
-- nasze cast speakers → utworzenie N tracks po master + items per region.
-- Mute master (audio nie dubluje gdy split items grają — same source).
----------------------------------------------------------------------------
local function perform_dialogue_split(s, deps)
  local handle = s.dialogue_split_handle
  if not handle or handle.status ~= 'done' or not handle.transcript then return end

  local function reset_split()
    s.dialogue_split_handle                 = nil
    s.dialogue_split_master_guid            = nil
    s.dialogue_split_master_position        = nil
    s.dialogue_split_master_audio_path      = nil
    s.dialogue_split_speakers_chronological = nil
  end

  local master_guid = s.dialogue_split_master_guid
  local master_item = master_guid and helpers.find_item_by_guid(master_guid) or nil
  if not master_item then
    s.dialogue_gen_status_text  = 'Split aborted: master item removed before split done.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    reset_split(); return
  end
  local master_track = reaper.GetMediaItemTrack(master_item)
  if not master_track then
    s.dialogue_gen_status_text  = 'Split aborted: master track not found.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    reset_split(); return
  end

  local audio_path = s.dialogue_split_master_audio_path
  -- M7: ŻYWA pozycja mastera (user mógł przesunąć item, zanim diarize STT
  -- skończyło — regiony liczone ze stashowanej pozycji lądowały obok).
  -- Stash zostaje wyłącznie jako fallback.
  local master_pos = reaper.GetMediaItemInfo_Value(master_item, 'D_POSITION')
                  or s.dialogue_split_master_position or 0
  local chrono     = s.dialogue_split_speakers_chronological or {}

  local words = handle.transcript.words or {}
  if #words == 0 then
    s.dialogue_gen_status_text  = 'Split: STT returned no words. Master item retained.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    reset_split(); return
  end

  -- Diarized speaker order (chronological appearance w transcript).
  local diar_seen, diar_order = {}, {}
  for _, w in ipairs(words) do
    local sp_id = w.speaker_id or 'speaker_0'
    if not diar_seen[sp_id] then
      diar_seen[sp_id] = true
      diar_order[#diar_order + 1] = sp_id
    end
  end

  -- Mapping diarized speaker_id → our speaker (by chronological index).
  -- Fallback do ostatniego gdy diarization wykrywa więcej speakerów niż my mamy.
  local diar_to_our = {}
  for i, diar_id in ipairs(diar_order) do
    diar_to_our[diar_id] = chrono[i] or chrono[#chrono]
  end

  -- Group consecutive words po speaker_id → speech regions.
  local regions = {}
  local current = nil
  for _, w in ipairs(words) do
    local sp_id = w.speaker_id or 'speaker_0'
    local w_start = tonumber(w.start) or tonumber(w['start']) or 0
    local w_end   = tonumber(w['end']) or w_start
    if not current or current.speaker_id ~= sp_id then
      if current then regions[#regions + 1] = current end
      current = {
        speaker_id = sp_id,
        start      = w_start,
        ['end']    = w_end,
        text       = w.text or '',
      }
    else
      current['end'] = w_end
      if w.text and w.text ~= '' then
        current.text = (current.text == '') and w.text or (current.text .. ' ' .. w.text)
      end
    end
  end
  if current then regions[#regions + 1] = current end

  if #regions == 0 then
    s.dialogue_gen_status_text  = 'Split: no speech regions detected.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    reset_split(); return
  end

  -- NS-2e fix: clip overlapping regions to mid-overlap point. Scribe v2
  -- diarization może mark adjacent regions z overlapping timestamps gdy
  -- dwóch speakerów nakłada się głosami (np. interruption, lub jeden
  -- continues while other starts). Half-gap padding logic zakłada
  -- non-overlapping input — bez tego clip, regions z negative gap dawały
  -- pad=0 ale ORYGINALNY data overlap pozostawał w item bounds.
  -- Mid-clip dzieli overlap sprawiedliwie między oba regiony.
  for i = 1, #regions - 1 do
    local cur = regions[i]
    local nxt = regions[i + 1]
    if nxt.start < cur['end'] then
      local mid = (cur['end'] + nxt.start) / 2
      cur['end']  = mid
      nxt.start   = mid
    end
  end

  -- Insert N tracks po master track. IP_TRACKNUMBER is 1-based; -1 = 0-based.
  local master_idx = math.floor(reaper.GetMediaTrackInfo_Value(master_track, 'IP_TRACKNUMBER')) - 1
  if master_idx < 0 then master_idx = 0 end

  reaper.Undo_BeginBlock()

  -- Track creation per unique voice_id (jeśli dwóch naszych speakerów ma ten
  -- sam voice_id, oba mapują do jednej trasy — collapse to one).
  local voice_to_track = {}
  local insert_offset  = 0
  for _, sp in ipairs(chrono) do
    if not voice_to_track[sp.voice_id] then
      insert_offset = insert_offset + 1
      local insert_idx = master_idx + insert_offset
      reaper.InsertTrackAtIndex(insert_idx, true)
      local new_tr = reaper.GetTrack(0, insert_idx)
      local tr_name = ('TTS [%s: %s]'):format(sp.label or '?', sp.voice_name or '?')
      reaper.GetSetMediaTrackInfo_String(new_tr, 'P_NAME', tr_name, true)
      voice_to_track[sp.voice_id] = new_tr
    end
  end

  -- Master source length — needed dla clamp post-pad nie przekroczy plik.
  local master_len = reaper.GetMediaItemInfo_Value(master_item, 'D_LENGTH') or 0

  -- Create item per region.
  local items_created = 0
  for region_idx, reg in ipairs(regions) do
    local our_sp = diar_to_our[reg.speaker_id]
    local track  = our_sp and voice_to_track[our_sp.voice_id] or nil
    if track then
      -- NS-2e fair-pad: half-gap clamp do adjacent regions — żaden speaker
      -- nie nachodzi na drugiego. Edge regions (first/last) clamped przez
      -- 0 / master_len. Każdy region dostaje pełen DIALOGUE_SPLIT_PAD_S
      -- gdy gap >= 2*PAD; przy mniejszym gap meet w środku silence.
      local prev_end   = (region_idx > 1) and regions[region_idx - 1]['end'] or 0
      local next_start = (region_idx < #regions) and regions[region_idx + 1].start or master_len
      local gap_prev   = math.max(0, reg.start - prev_end)
      local gap_next   = math.max(0, next_start - reg['end'])
      local pre_pad    = math.min(DIALOGUE_SPLIT_PAD_S, gap_prev / 2)
      local post_pad   = math.min(DIALOGUE_SPLIT_PAD_S, gap_next / 2)
      local pad_start  = math.max(0, reg.start - pre_pad)
      local pad_end    = math.min(master_len, reg['end'] + post_pad)
      local duration   = math.max(0.01, pad_end - pad_start)

      -- M7: source PRZED AddMediaItem — fail PCM (skasowany/uszkodzony mp3)
      -- zostawiał pusty item-sierotę na tracku speakera.
      local source = reaper.PCM_Source_CreateFromFile(audio_path)
      if source then
        local item = reaper.AddMediaItemToTrack(track)
        local take = reaper.AddTakeToMediaItem(item)
        reaper.SetMediaItemTake_Source(take, source)
        reaper.SetMediaItemPosition(item, master_pos + pad_start, false)
        reaper.SetMediaItemInfo_Value(item, 'D_LENGTH', duration)
        reaper.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', pad_start)
        build_peaks(source)
        local excerpt = (reg.text or ''):sub(1, 40)
        local take_name = ('%s · "%s"'):format(our_sp.label or '?', excerpt)
        reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', take_name, true)
        helpers.pext_item_set(item, 'is_tts_dialogue_split',       '1')
        helpers.pext_item_set(item, 'parent_dialogue_item_guid',   master_guid)
        helpers.pext_item_set(item, 'split_speaker_label',         our_sp.label or '?')
        helpers.pext_item_set(item, 'split_region_index',          tostring(region_idx))
        -- NS-2e Phase B: dodatkowy P_EXT dla per-region regen — split item
        -- staje się self-contained (regen NIE wymaga lookup master P_EXT).
        helpers.pext_item_set(item, 'split_text',                  reg.text or '')
        helpers.pext_item_set(item, 'split_voice_id',              our_sp.voice_id or '')
        helpers.pext_item_set(item, 'split_voice_name',            our_sp.voice_name or '')
        do
          -- Snapshot of per-speaker voice_settings at split time. Regen will
          -- read these — if user changes per-speaker settings później, regen
          -- nadal użyje stored (pożądane: regen replicates original generation
          -- intent unless user manually edits P_EXT).
          local snap = normalize_speaker_voice_settings(our_sp.voice_settings)
          local ok_snap, snap_json = pcall(json.encode, snap)
          helpers.pext_item_set(item, 'split_voice_settings', ok_snap and snap_json or '')
        end
        items_created = items_created + 1
      end
    end
  end

  -- Mute master so audio nie dubluje (split items grają z tego samego mp3).
  -- User może unmute manually if reference playback wanted.
  reaper.SetMediaItemInfo_Value(master_item, 'B_MUTE', 1)

  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock('Reasonate: split dialogue per speaker', -1)

  local n_tracks = 0
  for _ in pairs(voice_to_track) do n_tracks = n_tracks + 1 end
  s.dialogue_gen_status_text  = ('Split done · %d speaker tracks · %d regions · master muted')
    :format(n_tracks, items_created)
  s.dialogue_gen_status_color = theme.COLORS.status_done
  reset_split()

  if deps and deps.action_msg_setter then
    deps.action_msg_setter(
      ('TTS dialogue split · %d tracks · %d regions'):format(n_tracks, items_created),
      theme.COLORS.status_done)
  end
end

----------------------------------------------------------------------------
-- import_dialogue_result: on done, create item z P_EXT.is_tts_dialogue_output.
----------------------------------------------------------------------------
-- Auto-align po Generate (2026-06-11, user decision po weryfikacji cennika:
-- forced alignment = stawka STT $0.22/h audio — ułamki centa per take, plan
-- Creator ma 100 h/mc w cenie). Dzięki temu playhead→kwestia i ▶ per linia
-- działają OD RAZU po generacji, bez pierwszego "uzbrajającego" kliku.
-- Cache deterministyczny per (audio, tekst) — kolejne odpalenia darmowe.
-- Cicho: błąd nie blokuje niczego (▶ na linii ma własny pełny error path).
local function spawn_take_alignment_quiet(s, audio_path, inputs)
  if not audio_path or audio_path == '' then return end
  if s.take_align_handle then return end   -- jeden naraz; ▶ dokończy lazy
  if s.take_align_words and s.take_align_path == audio_path then return end
  local fa = require 'modules.forced_align'
  local parts = {}
  for _, inp in ipairs(inputs or {}) do parts[#parts + 1] = inp.text or '' end
  if #parts == 0 then return end
  local h = fa.spawn(audio_path, table.concat(parts, ' '))
  if h.status == 'error' then return end
  h._align_path       = audio_path
  s.take_align_handle = h   -- pompa consume_take_align w consume_signals dokończy
end

-- M5-2: alignment przyszedł RAZEM z audio (with-timestamps) — zapisz go od
-- razu zamiast spawnować osobne (płatne) wywołanie. false = brak/pusty
-- (caller robi legacy fallback przez spawn_take_alignment_quiet).
local function apply_take_alignment_from_handle(s, audio_path, alignment)
  if not alignment or type(alignment.words) ~= 'table' then return false end
  local words = {}
  for _, w in ipairs(alignment.words) do
    if type(w.text) == 'string' and w.text:match('%S') then
      words[#words + 1] = w
    end
  end
  if #words == 0 then return false end
  s.take_align_words = words
  s.take_align_path  = audio_path
  return true
end

local function import_dialogue_result(s, deps)
  local handle = s.dialogue_gen_handle
  if not handle or handle.status ~= 'done' then return end

  local audio_path     = handle.result
  local target_track   = s.dialogue_gen_target_track
  local append_to_guid = s.dialogue_gen_append_to_guid

  local function reset_gen()
    s.dialogue_gen_handle         = nil
    s.dialogue_gen_target_track   = nil
    s.dialogue_gen_append_to_guid = nil
  end

  if not audio_path or not util.file_exists(audio_path) then
    s.dialogue_gen_status_text  = 'Error: no audio file after generation.'
    s.dialogue_gen_status_color = theme.COLORS.status_error
    reset_gen(); return
  end
  if not target_track then
    s.dialogue_gen_status_text  = 'Error: target track gone before import.'
    s.dialogue_gen_status_color = theme.COLORS.status_error
    reset_gen(); return
  end

  local source_obj = reaper.PCM_Source_CreateFromFile(audio_path)
  if not source_obj then
    s.dialogue_gen_status_text  = 'Error: PCM_Source_CreateFromFile returned nil for ' .. audio_path
    s.dialogue_gen_status_color = theme.COLORS.status_error
    reset_gen(); return
  end

  local src_len = reaper.GetMediaSourceLength(source_obj) or 0
  local inputs  = (handle.args and handle.args.inputs) or {}
  local seed    = handle.args and handle.args.seed
  local ok_inp, inputs_json   = pcall(json.encode, inputs)
  local ok_set, settings_json = pcall(json.encode,
    (handle.args and handle.args.settings) or {})

  local total_chars = 0
  for _, it in ipairs(inputs) do total_chars = total_chars + util.utf8_len(it.text or '') end

  local append_item = append_to_guid and helpers.find_item_by_guid(append_to_guid) or nil

  if append_item then
    reaper.Undo_BeginBlock()
    local new_take = reaper.AddTakeToMediaItem(append_item)
    reaper.SetMediaItemTake_Source(new_take, source_obj)
    build_peaks(source_obj)
    local take_idx = reaper.CountTakes(append_item)
    reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME',
      dialogue_take_name(inputs, take_idx, seed), true)
    reaper.SetActiveTake(new_take)

    local cur_len = reaper.GetMediaItemInfo_Value(append_item, 'D_LENGTH') or 0
    if src_len > cur_len then
      reaper.SetMediaItemLength(append_item, src_len, false)
    end

    helpers.pext_item_set(append_item, 'tts_dialogue_inputs',       ok_inp and inputs_json   or '')
    helpers.pext_item_set(append_item, 'tts_dialogue_seed',         tostring(seed or 0))
    helpers.pext_item_set(append_item, 'tts_dialogue_settings',     ok_set and settings_json or '')
    helpers.pext_item_set(append_item, 'tts_dialogue_generated_at', tostring(os.time()))
    helpers.pext_item_set(append_item, 'tts_dialogue_model_id',     'eleven_v3')

    reaper.UpdateItemInProject(append_item)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock('Reasonate: TTS Dialogue append take', -1)

    if not handle.from_cache then
      cfg.add_tts_chars_used(handle.character_cost or total_chars)
    end

    s.dialogue_gen_status_text  = ('Take appended · %.1fs · take %d')
      :format(src_len, reaper.CountTakes(append_item))
    s.dialogue_gen_status_color = theme.COLORS.status_done
    reset_gen()
    s.dialogue_force_append_to_guid = nil   -- jednorazowy override (Re-gen take)
    -- M5-2: alignment z odpowiedzi with-timestamps; fallback = legacy call.
    if not apply_take_alignment_from_handle(s, audio_path, handle.alignment) then
      spawn_take_alignment_quiet(s, audio_path, inputs)
    end
    if deps and deps.action_msg_setter then
      deps.action_msg_setter(
        ('TTS dialogue take appended · %.1fs · %d lines'):format(src_len, #inputs),
        theme.COLORS.status_done)
    end
    return
  end

  -- Fresh item path
  local cursor_pos = reaper.GetCursorPosition() or 0
  reaper.Undo_BeginBlock()
  local new_item = reaper.AddMediaItemToTrack(target_track)
  local new_take = reaper.AddTakeToMediaItem(new_item)
  reaper.SetMediaItemTake_Source(new_take, source_obj)
  reaper.SetMediaItemPosition(new_item, cursor_pos, false)
  reaper.SetMediaItemLength(new_item, src_len, false)
  build_peaks(source_obj)
  reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME',
    dialogue_take_name(inputs, 1, seed), true)

  helpers.pext_item_set(new_item, 'is_tts_dialogue_output',    '1')
  helpers.pext_item_set(new_item, 'tts_dialogue_inputs',       ok_inp and inputs_json   or '')
  helpers.pext_item_set(new_item, 'tts_dialogue_seed',         tostring(seed or 0))
  helpers.pext_item_set(new_item, 'tts_dialogue_settings',     ok_set and settings_json or '')
  helpers.pext_item_set(new_item, 'tts_dialogue_generated_at', tostring(os.time()))
  helpers.pext_item_set(new_item, 'tts_dialogue_model_id',     'eleven_v3')

  reaper.UpdateItemInProject(new_item)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Reasonate: TTS Dialogue Generate', -1)

  if not handle.from_cache then
    cfg.add_tts_chars_used(handle.character_cost or total_chars)
  end

  if cfg.get_tts_advance_cursor() then
    reaper.SetEditCurPos(cursor_pos + src_len, false, false)
  end

  s.dialogue_gen_status_text  = ('Done · %.1fs · track %s'):format(
    src_len, helpers.track_name(target_track) or '?')
  s.dialogue_gen_status_color = theme.COLORS.status_done
  reset_gen()

  -- NS-2d: spawn split per-speaker tracks (if config flag ON). Gate na
  -- variants flow zniknął razem z Variants ×3 (cleanup 2026-06-11).
  maybe_spawn_dialogue_split(s, new_item, audio_path, inputs, cursor_pos)

  s.dialogue_force_append_to_guid = nil   -- jednorazowy override (Re-gen take)
  -- M5-2: alignment z odpowiedzi with-timestamps; fallback = legacy call.
  if not apply_take_alignment_from_handle(s, audio_path, handle.alignment) then
    spawn_take_alignment_quiet(s, audio_path, inputs)
  end

  if deps and deps.action_msg_setter then
    deps.action_msg_setter(
      ('TTS dialogue done · %.1fs · %d lines'):format(src_len, #inputs),
      theme.COLORS.status_done)
  end
end

----------------------------------------------------------------------------
-- Keyboard shortcut: Cmd/Ctrl+Enter = Generate (gdy nie busy).
-- W dialogue sub-mode → spawn_generate_dialogue; w single → spawn_generate.
----------------------------------------------------------------------------
local function process_shortcuts(ctx, s, deps)
  -- M7: gate na otwarty popup/modal — Enter w modalu (np. nazwa presetu)
  -- nie może jednocześnie odpalić Generate za plecami usera.
  if reaper.ImGui_IsPopupOpen(ctx, '', reaper.ImGui_PopupFlags_AnyPopup()) then
    return
  end
  local mod_ctrl_cmd = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
  if mod_ctrl_cmd
      and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false) then
    if s.sub_mode == 'dialogue' then
      if not s.dialogue_gen_handle then spawn_generate_dialogue(s, deps) end
    else
      if not s.gen_handle then spawn_generate(s, deps) end
    end
  end
end

----------------------------------------------------------------------------
-- M3 — Per-item history helpers.
-- (random_seed moved earlier in file — needed by spawn_generate which sits
-- above this block; Lua lexical scoping doesn't see forward-defined locals.)
----------------------------------------------------------------------------

-- Scan items on track with P_EXT.is_tts_output. Sorted by position
-- (chronologiczny dialog flow).
local function scan_tts_items_on_track(track)
  if not track then return {} end
  local out = {}
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if helpers.pext_item_get(item, 'is_tts_output') == '1' then
      local take_count = reaper.CountTakes(item)
      local active_take = reaper.GetActiveTake(item)
      local active_take_idx = 0
      if active_take then
        for ti = 0, take_count - 1 do
          if reaper.GetTake(item, ti) == active_take then
            active_take_idx = ti
            break
          end
        end
      end
      out[#out + 1] = {
        item            = item,
        guid            = helpers.item_guid(item),
        text            = helpers.pext_item_get(item, 'tts_text') or '',
        voice_id        = helpers.pext_item_get(item, 'tts_voice_id') or '',
        voice_name      = helpers.pext_item_get(item, 'tts_voice_name') or '',
        model_id        = helpers.pext_item_get(item, 'tts_model_id') or '',
        voice_settings  = helpers.pext_item_get(item, 'tts_voice_settings') or '',
        duration        = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0,
        position        = reaper.GetMediaItemInfo_Value(item, 'D_POSITION') or 0,
        generated_at    = tonumber(helpers.pext_item_get(item, 'tts_generated_at')),
        take_count      = take_count,
        active_take_idx = active_take_idx,
        -- C_LOCK &1 (B_LOCK NIE istnieje dla itemów — silent no-op; SDK 2026-06-11)
        locked          = (math.floor(reaper.GetMediaItemInfo_Value(item, 'C_LOCK') or 0) & 1) == 1,
      }
    end
  end
  table.sort(out, function(a, b) return a.position < b.position end)
  return out
end

local function format_short_text(text, max_chars)
  local t = (text or ''):gsub('[\r\n\t]', ' ')
  -- Cięcie po ZNAKACH (utf8.offset), nie bajtach — sub() w środku
  -- wielobajtowego znaku renderuje zepsuty glif (M3-1).
  if util.utf8_len(t) > max_chars then
    local cut = utf8.offset(t, max_chars) or (#t + 1)
    return t:sub(1, cut - 1) .. '…'
  end
  return t
end

local function format_gen_time(unix_ts)
  if not unix_ts then return '?' end
  return os.date('%H:%M', unix_ts)
end

local function format_duration(secs)
  secs = secs or 0
  local m = math.floor(secs / 60)
  local s = secs - m * 60
  return ('%d:%04.1f'):format(m, s)
end

local function toggle_item_lock(item)
  -- C_LOCK char bitmask, &1=locked (B_LOCK nie istnieje dla itemów — toggle
  -- był silent no-op od NS-2b; user-caught 2026-06-11). Zachowujemy bit &2
  -- (lock to active take), przełączamy tylko &1.
  local cur = math.floor(reaper.GetMediaItemInfo_Value(item, 'C_LOCK') or 0)
  reaper.SetMediaItemInfo_Value(item, 'C_LOCK', (cur & 1) == 1 and (cur & ~1) or (cur | 1))
  reaper.UpdateItemInProject(item)
end

local function cycle_take(item, direction)
  local cnt = reaper.CountTakes(item)
  if cnt < 2 then return end
  local active = reaper.GetActiveTake(item)
  local cur_idx = 0
  for ti = 0, cnt - 1 do
    if reaper.GetTake(item, ti) == active then cur_idx = ti; break end
  end
  local new_idx = ((cur_idx + direction) % cnt + cnt) % cnt
  local new_take = reaper.GetTake(item, new_idx)
  if new_take then
    reaper.SetActiveTake(new_take)
    reaper.UpdateItemInProject(item)
    reaper.UpdateArrange()
  end
end

local function select_item_in_timeline(item)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.UpdateArrange()
end

-- Delete the currently-active take from `item` via REAPER action 40129
-- ("Take: Delete active take from items"). Saves + restores selection so the
-- user's working selection isn't clobbered.
local function delete_active_take_action(item)
  if not item then return end
  local prev = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    prev[#prev + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  reaper.Undo_BeginBlock()
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.Main_OnCommand(40129, 0)
  reaper.Undo_EndBlock('Reasonate: Delete TTS take', -1)
  reaper.SelectAllMediaItems(0, false)
  for _, it in ipairs(prev) do
    if reaper.ValidatePtr(it, 'MediaItem*') then
      reaper.SetMediaItemSelected(it, true)
    end
  end
  reaper.UpdateArrange()
end

-- Reveal item's active take audio file in the OS file manager. Best-effort:
-- Finder/Explorer can highlight the file; Linux falls back to xdg-open on dir.
local function reveal_active_take_audio(item)
  local take = item and reaper.GetActiveTake(item) or nil
  local src  = take and reaper.GetMediaItemTake_Source(take) or nil
  local path = src and reaper.GetMediaSourceFileName(src, '') or nil
  if not path or path == '' then return end
  local os_str = reaper.GetOS() or ''
  local cmd
  if os_str:find('Win') then
    cmd = ('explorer /select,%s'):format(util.shell_escape(path))
  elseif os_str:find('OSX') or os_str:find('macOS') then
    cmd = ('/usr/bin/open -R %s'):format(util.shell_escape(path))
  else
    local dir = path:match('^(.+)/[^/]+$') or '.'
    cmd = ('xdg-open %s'):format(util.shell_escape(dir))
  end
  reaper.ExecProcess(cmd, -1)
end

----------------------------------------------------------------------------
-- NS-2c M3: scan dialogue items na track (separate flag is_tts_dialogue_output).
-- Mirror scan_tts_items_on_track ale dla dialogue P_EXT fields.
----------------------------------------------------------------------------
local function scan_dialogue_items_on_track(track)
  if not track then return {} end
  local out = {}
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if helpers.pext_item_get(item, 'is_tts_dialogue_output') == '1' then
      local take_count    = reaper.CountTakes(item)
      local active_take   = reaper.GetActiveTake(item)
      local active_take_idx = 0
      if active_take then
        for ti = 0, take_count - 1 do
          if reaper.GetTake(item, ti) == active_take then
            active_take_idx = ti
            break
          end
        end
      end
      local inputs_json   = helpers.pext_item_get(item, 'tts_dialogue_inputs') or ''
      local inputs        = {}
      if inputs_json ~= '' then
        local ok, decoded = pcall(json.decode, inputs_json)
        if ok and type(decoded) == 'table' then inputs = decoded end
      end
      out[#out + 1] = {
        item              = item,
        guid              = helpers.item_guid(item),
        inputs            = inputs,
        inputs_json       = inputs_json,
        settings_json     = helpers.pext_item_get(item, 'tts_dialogue_settings') or '',
        seed              = tonumber(helpers.pext_item_get(item, 'tts_dialogue_seed')),
        duration          = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0,
        position          = reaper.GetMediaItemInfo_Value(item, 'D_POSITION') or 0,
        generated_at      = tonumber(helpers.pext_item_get(item, 'tts_dialogue_generated_at')),
        take_count        = take_count,
        active_take_idx   = active_take_idx,
        -- C_LOCK &1 (B_LOCK NIE istnieje dla itemów — silent no-op; SDK 2026-06-11)
        locked            = (math.floor(reaper.GetMediaItemInfo_Value(item, 'C_LOCK') or 0) & 1) == 1,
      }
    end
  end
  table.sort(out, function(a, b) return a.position < b.position end)
  return out
end

-- W3 live (2026-06-11): korekta po wygenerowaniu. Porównanie bieżących linii
-- panelu z inputs OSTATNIO wygenerowanego dialogue itemu na target tracku →
-- pasek akcji pokazuje "edited since last take" + 1-klik re-gen (nowy take
-- na TYM SAMYM itemie, stare take'i zostają; mirror dirty→1-klik z dubbingu).
function dialogue_take_sync(s)   -- przypisanie do forward decl (patrz wyżej)
  if not s.target_track_guid or s.target_track_guid == '' then return nil end
  local track = helpers.find_track_by_guid(s.target_track_guid)
  if not track then return nil end
  local latest = nil
  for _, r in ipairs(scan_dialogue_items_on_track(track)) do
    if r.inputs and #r.inputs > 0 then
      if not latest or (r.generated_at or 0) > (latest.generated_at or 0) then
        latest = r
      end
    end
  end
  if not latest then return nil end
  local current = build_dialogue_inputs(s)
  if #current == 0 then return nil end
  local dirty = (#current ~= #latest.inputs)
  if not dirty then
    for i = 1, #current do
      local a, b = current[i], latest.inputs[i]
      if a.text ~= (b.text or '') or a.voice_id ~= (b.voice_id or '') then
        dirty = true
        break
      end
    end
  end
  -- Ścieżka audio aktywnego take'a — linia ▶ gra wygenerowany dub zamiast
  -- bilować nowe solo, gdy linia jest częścią ostatniego take'a (2026-06-11).
  local audio_path = nil
  local take = latest.item and reaper.GetActiveTake(latest.item)
  if take then
    local src = reaper.GetMediaItemTake_Source(take)
    if src then
      local fn = reaper.GetMediaSourceFileName(src, '')
      if fn and fn ~= '' and util.file_exists(fn) then audio_path = fn end
    end
  end
  return { guid = latest.guid, dirty = dirty, locked = latest.locked,
           inputs = latest.inputs, audio_path = audio_path }
end

local function regen_dialogue_take(s, deps, item_guid)
  s.dialogue_force_append_to_guid = item_guid
  -- User 2026-07-11: świeży salt = świeża interpretacja (seed Generate jest
  -- deterministyczny per treść; bez saltu Re-gen byłby cache hitem).
  s.dialogue_seed_salt = random_seed()
  spawn_generate_dialogue(s, deps)
end

----------------------------------------------------------------------------
-- Per-line playback wygenerowanego take'a (2026-06-11, user request: ▶ ma
-- grać KONKRETNĄ kwestię, nie całość od początku). Czasy słów w audio
-- z /v1/forced-alignment — lazy przy pierwszym ▶ po Generate, cache per
-- (audio, tekst) → kolejne kliki natychmiastowe i darmowe. Liczenie słów
-- per input przez fa.sanitize_text — IDENTYCZNA normalizacja co w spawn;
-- indeksy mapowane przez non-space (KNOWN-ISSUES: words[] ma tokeny spacji).
----------------------------------------------------------------------------
local function take_input_word_counts(inputs)
  local fa = require 'modules.forced_align'
  local counts = {}
  for i, inp in ipairs(inputs or {}) do
    local n = 0
    for _ in fa.sanitize_text(inp.text or ''):gmatch('%S+') do n = n + 1 end
    counts[i] = n
  end
  return counts
end

local function take_line_range(s, inputs, input_index)
  local words = s.take_align_words
  if not words then return nil end
  local counts = take_input_word_counts(inputs)
  if (counts[input_index] or 0) == 0 then return nil end
  local first = 1
  for i = 1, input_index - 1 do first = first + (counts[i] or 0) end
  local last = first + counts[input_index] - 1
  if last > #words then return nil end  -- rozjazd tokenizacji → fallback całość
  local t0 = math.max(0, (words[first].start or 0) - 0.05)
  local t1 = (words[last]['end'] or words[last].start or 0) + 0.15
  if t1 <= t0 then return nil end
  return t0, t1
end

local function play_take_range_or_all(s, sync, input_index)
  local t0, t1 = take_line_range(s, sync.inputs, input_index)
  if t0 then
    preview.play_file_range(sync.audio_path, t0, t1, 'tts_dialogue_take', { volume = 0.8 })
  else
    preview.play_file(sync.audio_path, 'tts_dialogue_take', { volume = 0.8 })
  end
end

-- Forward decl (KNOWN-ISSUES lexical scoping): consume_take_align odpala
-- patch po async alignmencie, a request_line_patch jest zdefiniowane niżej.
local request_line_patch

local function consume_take_align(s)
  local h = s.take_align_handle
  if not h then return end
  if h.status == 'running' then
    local fa = require 'modules.forced_align'
    fa.poll(h)
    if h.status == 'running' then async_op.force_error_if_stale(h, 'Line timing') end
  end
  if h.status == 'done' then
    s.take_align_handle = nil
    local words = {}
    for _, w in ipairs((h.result and h.result.words) or {}) do
      if type(w.text) == 'string' and w.text:match('%S') then
        words[#words + 1] = w
      end
    end
    s.take_align_words = words
    s.take_align_path  = h._align_path
    s.dialogue_gen_status_text = nil
    local pend = s.take_align_pending
    s.take_align_pending = nil
    if pend then
      if pend.action == 'patch' then
        request_line_patch(s, pend.line_id)
      else
        local sync = dialogue_take_sync(s)
        if sync and sync.audio_path == s.take_align_path then
          s.take_play_line_id = pend.line_id
          play_take_range_or_all(s, sync, pend.input_index)
        end
      end
    end
  elseif h.status == 'error' then
    s.take_align_handle  = nil
    s.take_align_pending = nil
    s.dialogue_gen_status_text  = 'Line timing: ' .. tostring(h.error)
    s.dialogue_gen_status_color = theme.COLORS.status_stale
  end
end

-- ▶ na linii będącej częścią ostatniego take'a (wołane z panelu).
local function request_take_line_play(s, sync, input_index, line_id)
  if not (sync and sync.audio_path) then return end
  s.take_play_line_id = line_id   -- shared play_id → panel zna graną linię
  if s.take_align_words and s.take_align_path == sync.audio_path then
    play_take_range_or_all(s, sync, input_index)
    return
  end
  if s.take_align_handle then
    s.take_align_pending = { input_index = input_index, line_id = line_id }
    return
  end
  local fa = require 'modules.forced_align'
  local parts = {}
  for _, inp in ipairs(sync.inputs or {}) do parts[#parts + 1] = inp.text or '' end
  local h = fa.spawn(sync.audio_path, table.concat(parts, ' '))
  if h.status == 'error' then
    -- Nie blokuj odsłuchu: zagraj całość, przyczyna w statusie.
    preview.play_file(sync.audio_path, 'tts_dialogue_take', { volume = 0.8 })
    s.dialogue_gen_status_text  = 'Line timing: ' .. tostring(h.error)
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end
  h._align_path        = sync.audio_path
  s.take_align_handle  = h
  s.take_align_pending = { input_index = input_index, line_id = line_id }
  if h.status == 'done' then
    consume_take_align(s)  -- cache hit: syntetyczny done — graj od razu
  else
    s.dialogue_gen_status_text  = 'Mapping line timings…'
    s.dialogue_gen_status_color = theme.COLORS.text_dim
  end
end

----------------------------------------------------------------------------
-- Per-line PATCH (user decision 2026-06-11, AskUserQuestion): poprawka
-- edytowanej kwestii = wygeneruj TYLKO ją (single TTS z prev/next context
-- dla prozodii) i podmień jej fragment na osi czasu. Model "klocki per
-- kwestia": pierwszy patch tnie item dialogu SplitMediaItem na granicach
-- kwestii (czasy z forced-alignment), kawałki dostają P_EXT schematu
-- NS-2d split (is_tts_dialogue_split + split_*) + split_line_id → cały
-- mechanizm NS-2e (spawn_split_regen pump, on_split_regen_done AddTake,
-- mini-sekcja "Selected split region") działa na nich BEZ ZMIAN.
----------------------------------------------------------------------------

-- Track "TTS · line takes" pod trackiem dialogu (tryb jeden-plik: regen
-- linii ląduje TU jako osobny item pod oryginalnym miejscem kwestii).
local function find_patch_track(parent_guid)
  for tr in helpers.iter_tracks() do
    if helpers.pext_track_get(tr, 'is_tts_patch_track') == '1'
       and (helpers.pext_track_get(tr, 'patch_parent_guid') or '') == parent_guid then
      return tr
    end
  end
  return nil
end

local function get_or_create_patch_track(parent_track, parent_guid)
  local existing = find_patch_track(parent_guid)
  if existing then return existing end
  -- IP_TRACKNUMBER jest 1-based → wartość parenta = 0-based slot ZA nim.
  local insert_at = helpers.track_index(parent_track)
  reaper.InsertTrackAtIndex(insert_at, true)
  local tr = reaper.GetTrack(0, insert_at)
  reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', 'TTS · line takes', true)
  helpers.pext_track_set(tr, 'is_tts_patch_track', '1')
  helpers.pext_track_set(tr, 'patch_parent_guid', parent_guid)
  reaper.TrackList_AdjustWindows(false)
  return tr
end

-- Mapa line_id → klocek/patch-item linii (per frame z panelu). Skanuje
-- target track (klocki po splicie) ORAZ track patchów pod nim (tryb
-- jeden-plik) — oba niosą ten sam schemat P_EXT split_*.
local function scan_dialogue_line_items(s)
  local out = {}
  if not s.target_track_guid or s.target_track_guid == '' then return out end
  local track = helpers.find_track_by_guid(s.target_track_guid)
  if not track then return out end
  local function scan_track(tr)
    if not tr then return end
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local item = reaper.GetTrackMediaItem(tr, i)
      if helpers.pext_item_get(item, 'is_tts_dialogue_split') == '1' then
        local lid = helpers.pext_item_get(item, 'split_line_id') or ''
        if lid ~= '' then
          local audio_path, startoffs = nil, 0
          local take = reaper.GetActiveTake(item)
          if take then
            startoffs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
            local src = reaper.GetMediaItemTake_Source(take)
            if src then
              local fn = reaper.GetMediaSourceFileName(src, '')
              if fn and fn ~= '' and util.file_exists(fn) then audio_path = fn end
            end
          end
          out[lid] = {
            item           = item,
            guid           = helpers.item_guid(item),
            split_text     = helpers.pext_item_get(item, 'split_text') or '',
            split_voice_id = helpers.pext_item_get(item, 'split_voice_id') or '',
            audio_path     = audio_path,
            startoffs      = startoffs,
            length         = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0,
          }
        end
      end
    end
  end
  scan_track(track)
  scan_track(find_patch_track(s.target_track_guid))
  return out
end

-- Inputs take'a → panelowe linie po KOLEJNOŚCI (build_dialogue_inputs
-- buduje inputs dokładnie tak samo). Edytowany TEKST nie psuje mapowania;
-- dodanie/usunięcie/przestawienie linii od Generate = mismatch → nil.
local function map_take_inputs_to_lines(s, inputs)
  local mapped = {}
  for _, ln in ipairs(s.dialogue_lines or {}) do
    if (ln.text or '') ~= '' then
      local sp = find_speaker_by_id(s, ln.speaker_id)
      if sp and sp.voice_id ~= '' then
        mapped[#mapped + 1] = { line = ln, speaker = sp }
      end
    end
  end
  if #mapped ~= #inputs then return nil end
  return mapped
end

-- Tnie item wspólnego take'a na klocki per kwestia. Granica między
-- kwestiami = środek przerwy między ostatnim słowem jednej a pierwszym
-- następnej. Zwraca map line_id → piece item (lub nil, err).
local function split_take_into_line_items(s, sync)
  local item = helpers.find_item_by_guid(sync.guid)
  if not item then return nil, 'take item not found' end
  local take = reaper.GetActiveTake(item)
  if not take then return nil, 'take missing' end
  local playrate = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1
  if math.abs(playrate - 1) > 0.001 then
    return nil, 'item playrate must be 1.0'
  end
  local mapped = map_take_inputs_to_lines(s, sync.inputs)
  if not mapped then
    return nil, 'lines were added/removed since the last Generate — use whole-take Re-gen'
  end
  local words  = s.take_align_words
  local counts = take_input_word_counts(sync.inputs)
  local ranges, first = {}, 1
  for i = 1, #sync.inputs do
    local n = counts[i] or 0
    if n == 0 or first + n - 1 > #words then
      return nil, 'line timing mapping failed'
    end
    local last = first + n - 1
    ranges[i] = { s0 = words[first].start or 0,
                  s1 = words[last]['end'] or words[last].start or 0 }
    first = last + 1
  end

  local item_pos  = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local item_len  = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local startoffs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0

  reaper.Undo_BeginBlock()
  local pieces, cur = {}, item
  for i = 1, #sync.inputs - 1 do
    local b_src  = (ranges[i].s1 + ranges[i + 1].s0) * 0.5
    local b_proj = item_pos + (b_src - startoffs)
    local right = nil
    if b_proj > item_pos + 0.01 and b_proj < item_pos + item_len - 0.01 then
      right = reaper.SplitMediaItem(cur, b_proj)
    end
    if not right then
      reaper.Undo_EndBlock('Reasonate: split dialogue into line items', -1)
      return nil, 'split failed at line boundary ' .. i
    end
    pieces[#pieces + 1] = cur
    cur = right
  end
  pieces[#pieces + 1] = cur

  local by_line = {}
  for i, piece in ipairs(pieces) do
    local m = mapped[i]
    -- Kawałki NIE są już wspólnym takem — historia/take_sync mają ich nie widzieć.
    helpers.pext_item_set(piece, 'is_tts_dialogue_output', '')
    helpers.pext_item_set(piece, 'tts_dialogue_inputs', '')
    helpers.pext_item_set(piece, 'is_tts_dialogue_split', '1')
    helpers.pext_item_set(piece, 'split_line_id',       m.line.id)
    helpers.pext_item_set(piece, 'split_text',          sync.inputs[i].text)
    helpers.pext_item_set(piece, 'split_voice_id',      sync.inputs[i].voice_id)
    helpers.pext_item_set(piece, 'split_voice_name',    m.speaker.voice_name or '')
    helpers.pext_item_set(piece, 'split_speaker_label', m.speaker.label or '')
    local okv, vs_json = pcall(json.encode,
      normalize_speaker_voice_settings(m.speaker.voice_settings))
    helpers.pext_item_set(piece, 'split_voice_settings', okv and vs_json or '')
    by_line[m.line.id] = piece
  end
  reaper.Undo_EndBlock('Reasonate: split dialogue into line items', -1)
  reaper.UpdateArrange()
  return by_line
end

-- Single TTS edytowanej kwestii → handle ląduje w ISTNIEJĄCEJ pompie
-- dialogue_split_regen_handles (AddTake po done).
-- UWAGA (live 2026-06-11): eleven_v3 NIE wspiera request stitching —
-- previous_text/next_text = HTTP 400 ("Providing…"); pola działają tylko
-- w v2/turbo/flash. Kwestia renderuje się bez kontekstu sąsiadów (jedyna
-- opcja w v3); prozodię ratuje voice_settings mówcy + treść zdania.
local function spawn_line_patch(s, item, ln, sp)
  local guid = helpers.item_guid(item)
  s.dialogue_split_regen_handles = s.dialogue_split_regen_handles or {}
  if s.dialogue_split_regen_handles[guid] then return end
  local stripped = (ln.text or ''):gsub('%s+', '')
  if util.utf8_len(stripped) < MIN_TEXT_CHARS then
    s.dialogue_gen_status_text  = 'Line too short to re-render.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end
  local vs = normalize_speaker_voice_settings(sp.voice_settings)
  local spawn_opts = {
    voice_id       = sp.voice_id,
    text           = ln.text,
    model_id       = 'eleven_v3',
    voice_settings = {
      stability        = vs.stability,
      similarity_boost = vs.similarity_boost,
      style            = vs.style,
      speed            = vs.speed,
    },
    output_format  = cfg.get_tts_output_format(),
    seed           = random_seed(),
  }
  local handle = voice_admin.spawn_tts(spawn_opts)
  if handle.status == 'error' then
    s.dialogue_gen_status_text  = 'Line re-render: ' .. tostring(handle.error or 'unknown')
    s.dialogue_gen_status_color = theme.COLORS.status_error
    return
  end
  handle._spawn_opts      = spawn_opts
  handle._retry_count     = 0
  handle._split_item_guid = guid
  local okv, vs_json = pcall(json.encode, vs)
  handle._patch_meta = {
    text          = ln.text,
    voice_id      = sp.voice_id,
    voice_name    = sp.voice_name or '',
    settings_json = okv and vs_json or '',
  }
  s.dialogue_split_regen_handles[guid] = handle
  s.dialogue_gen_status_text  = ('Re-rendering line · %d chars…'):format(#ln.text)
  s.dialogue_gen_status_color = theme.COLORS.text_dim
end

-- Tryb jeden-plik (patch_split_mode=false, default): render linii ląduje
-- jako NOWY item na tracku patchów pod dialogiem (pozycja = miejsce kwestii,
-- długość = naturalna długość nowego nagrania). Handle w tej samej pompie,
-- klucz 'new_<line_id>' (brak itemu przed done).
local function spawn_line_patch_new(s, ln, sp, proj_pos)
  local key = 'new_' .. ln.id
  s.dialogue_split_regen_handles = s.dialogue_split_regen_handles or {}
  if s.dialogue_split_regen_handles[key] then return end
  local stripped = (ln.text or ''):gsub('%s+', '')
  if util.utf8_len(stripped) < MIN_TEXT_CHARS then
    s.dialogue_gen_status_text  = 'Line too short to re-render.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end
  local vs = normalize_speaker_voice_settings(sp.voice_settings)
  local spawn_opts = {
    voice_id       = sp.voice_id,
    text           = ln.text,
    model_id       = 'eleven_v3',
    voice_settings = {
      stability        = vs.stability,
      similarity_boost = vs.similarity_boost,
      style            = vs.style,
      speed            = vs.speed,
    },
    output_format  = cfg.get_tts_output_format(),
    seed           = random_seed(),
  }
  local handle = voice_admin.spawn_tts(spawn_opts)
  if handle.status == 'error' then
    s.dialogue_gen_status_text  = 'Line re-render: ' .. tostring(handle.error or 'unknown')
    s.dialogue_gen_status_color = theme.COLORS.status_error
    return
  end
  handle._spawn_opts  = spawn_opts
  handle._retry_count = 0
  local okv, vs_json = pcall(json.encode, vs)
  handle._patch_create = {
    parent_guid   = s.target_track_guid,
    position      = proj_pos,
    line_id       = ln.id,
    text          = ln.text,
    voice_id      = sp.voice_id,
    voice_name    = sp.voice_name or '',
    label         = sp.label or '',
    settings_json = okv and vs_json or '',
  }
  s.dialogue_split_regen_handles[key] = handle
  s.dialogue_gen_status_text  = ('Re-rendering line · %d chars…'):format(#ln.text)
  s.dialogue_gen_status_color = theme.COLORS.text_dim
end

-- Done handler trybu jeden-plik (wołane z on_split_regen_done).
local function create_patch_item(s, handle)
  local meta = handle._patch_create
  local audio_path = handle.result
  if not audio_path or not util.file_exists(audio_path) then return end
  local parent = helpers.find_track_by_guid(meta.parent_guid)
  if not parent then return end
  local source_obj = reaper.PCM_Source_CreateFromFile(audio_path)
  if not source_obj then return end
  local src_len = reaper.GetMediaSourceLength(source_obj) or 0

  reaper.Undo_BeginBlock()
  local track = get_or_create_patch_track(parent, meta.parent_guid)
  local item  = reaper.AddMediaItemToTrack(track)
  reaper.SetMediaItemInfo_Value(item, 'D_POSITION', meta.position)
  reaper.SetMediaItemInfo_Value(item, 'D_LENGTH', src_len)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, source_obj)
  build_peaks(source_obj)
  local seed = handle.args and handle.args.seed
  local seed_str = ''
  if seed and tonumber(seed) and seed > 0 then
    seed_str = (' · seed=%08x'):format(math.floor(seed))
  end
  local excerpt = (meta.text or ''):gsub('[\r\n\t]', ' '):sub(1, 40)
  reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME',
    ('Take 1 · %s%s · "%s"'):format(
      meta.voice_name ~= '' and meta.voice_name or '?', seed_str, excerpt), true)
  reaper.SetActiveTake(take)
  -- Schemat split_* → kolejne [Re-gen]/▶ tej linii działają na TYM itemie
  -- (scan_dialogue_line_items skanuje też track patchów) — następne
  -- poprawki dokładają take'i, nie nowe itemy.
  helpers.pext_item_set(item, 'is_tts_dialogue_split', '1')
  helpers.pext_item_set(item, 'split_line_id',         meta.line_id)
  helpers.pext_item_set(item, 'split_text',            meta.text)
  helpers.pext_item_set(item, 'split_voice_id',        meta.voice_id)
  helpers.pext_item_set(item, 'split_voice_name',      meta.voice_name)
  helpers.pext_item_set(item, 'split_voice_settings',  meta.settings_json)
  helpers.pext_item_set(item, 'split_speaker_label',   meta.label)
  reaper.UpdateItemInProject(item)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Reasonate: line take below dialogue', -1)

  s.dialogue_gen_status_text  = 'Line rendered on the "line takes" track below.'
  s.dialogue_gen_status_color = theme.COLORS.status_done

  if not handle.from_cache then
    cfg.add_tts_chars_used(handle.character_cost or util.utf8_len(handle.args and handle.args.text or ''))
  end
end

-- Wejście z panelu: [Re-gen] przy edytowanej linii. Łańcuch async:
-- (klocek/patch-item istnieje → take patch) | (wspólny take → alignment? →
-- split LUB item pod dialogiem, wg s.patch_split_mode).
function request_line_patch(s, line_id)
  local lines = s.dialogue_lines or {}
  local ln
  for _, l in ipairs(lines) do
    if l.id == line_id then
      ln = l
      break
    end
  end
  if not ln or (ln.text or '') == '' then return end
  local sp = find_speaker_by_id(s, ln.speaker_id)
  if not sp or sp.voice_id == '' then
    s.dialogue_gen_status_text  = "Assign the speaker's voice first."
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end

  local li = scan_dialogue_line_items(s)[line_id]
  if li then
    spawn_line_patch(s, li.item, ln, sp)
    return
  end

  local sync = dialogue_take_sync(s)
  if not (sync and sync.audio_path) then
    s.dialogue_gen_status_text  = 'No generated take found for this conversation.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end
  if not (s.take_align_words and s.take_align_path == sync.audio_path) then
    if s.take_align_handle then
      s.take_align_pending = { action = 'patch', line_id = line_id }
      return
    end
    local fa = require 'modules.forced_align'
    local parts = {}
    for _, inp in ipairs(sync.inputs or {}) do parts[#parts + 1] = inp.text or '' end
    local h = fa.spawn(sync.audio_path, table.concat(parts, ' '))
    if h.status == 'error' then
      s.dialogue_gen_status_text  = 'Line timing: ' .. tostring(h.error)
      s.dialogue_gen_status_color = theme.COLORS.status_stale
      return
    end
    h._align_path        = sync.audio_path
    s.take_align_handle  = h
    s.take_align_pending = { action = 'patch', line_id = line_id }
    if h.status == 'done' then
      consume_take_align(s)
    else
      s.dialogue_gen_status_text  = 'Mapping line timings…'
      s.dialogue_gen_status_color = theme.COLORS.text_dim
    end
    return
  end

  if s.patch_split_mode then
    -- Tryb klocków: pierwsze [Re-gen] tnie dialog per kwestia.
    local by_line, serr = split_take_into_line_items(s, sync)
    if not by_line then
      s.dialogue_gen_status_text  = 'Line split: ' .. tostring(serr)
      s.dialogue_gen_status_color = theme.COLORS.status_stale
      return
    end
    local piece = by_line[line_id]
    if piece then
      spawn_line_patch(s, piece, ln, sp)
    end
    return
  end

  -- Tryb jeden-plik (default): pozycja kwestii z czasów słów → nowy item
  -- na tracku patchów pod dialogiem.
  local mapped = map_take_inputs_to_lines(s, sync.inputs)
  local input_index
  if mapped then
    for i, m in ipairs(mapped) do
      if m.line.id == line_id then
        input_index = i
        break
      end
    end
  end
  if not input_index then
    s.dialogue_gen_status_text  =
      'Lines were added/removed since the last Generate — generate the whole conversation again.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end
  local counts = take_input_word_counts(sync.inputs)
  local first = 1
  for i = 1, input_index - 1 do first = first + (counts[i] or 0) end
  local w = s.take_align_words and s.take_align_words[first]
  if not w or (counts[input_index] or 0) == 0 then
    s.dialogue_gen_status_text  = 'Line timing mapping failed.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end
  local item = helpers.find_item_by_guid(sync.guid)
  if not item then
    s.dialogue_gen_status_text  = 'Take item not found.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end
  local take = reaper.GetActiveTake(item)
  local startoffs = take and (reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0) or 0
  local item_pos  = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local proj_pos  = math.max(0, item_pos + ((w.start or 0) - startoffs))
  spawn_line_patch_new(s, ln, sp, proj_pos)
end

----------------------------------------------------------------------------
-- Playhead → podświetlenie aktywnej kwestii w Lines (user request
-- 2026-06-11; mirror Dubbing sync_playhead_segment / Repair word underline
-- z W3 s3). Klocki/patch-itemy: item pod pozycją (split_line_id). Wspólny
-- take: pozycja → czas pliku → zakresy słów per kwestia — TYLKO gdy
-- alignment już w cache (zero wywołań API dla samego podświetlenia).
----------------------------------------------------------------------------
local function try_load_take_alignment_from_cache(s, sync)
  if s.take_align_words and s.take_align_path == sync.audio_path then return true end
  if s.take_align_handle then return false end
  local fa = require 'modules.forced_align'
  local parts = {}
  for _, inp in ipairs(sync.inputs or {}) do parts[#parts + 1] = inp.text or '' end
  local text = table.concat(parts, ' ')
  local cp = fa.cache_path_for(sync.audio_path, fa.sanitize_text(text))
  if not (cp and util.file_exists(cp)) then return false end
  local h = fa.spawn(sync.audio_path, text)  -- cache hit → synthetic done
  if h.status ~= 'done' then return false end
  h._align_path       = sync.audio_path
  s.take_align_handle = h
  consume_take_align(s)
  return s.take_align_words ~= nil and s.take_align_path == sync.audio_path
end

local function sync_playhead_line(s)
  local playing = (reaper.GetPlayState() & 1) == 1
  local pos = playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local found = nil

  if s.target_track_guid and s.target_track_guid ~= '' then
    local track = helpers.find_track_by_guid(s.target_track_guid)
    local function probe(tr)
      if not tr or found then return end
      for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local item = reaper.GetTrackMediaItem(tr, i)
        local p = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
        local l = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
        if pos >= p and pos < p + l
           and helpers.pext_item_get(item, 'is_tts_dialogue_split') == '1' then
          local lid = helpers.pext_item_get(item, 'split_line_id') or ''
          if lid ~= '' then
            found = lid
            return
          end
        end
      end
    end
    probe(track)
    probe(find_patch_track(s.target_track_guid))

    if not found then
      local sync = dialogue_take_sync(s)
      if sync and sync.audio_path then
        local item = helpers.find_item_by_guid(sync.guid)
        if item then
          local p = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
          local l = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
          if pos >= p and pos < p + l
             and try_load_take_alignment_from_cache(s, sync) then
            local take = reaper.GetActiveTake(item)
            local offs = take
              and (reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0) or 0
            local src_t  = offs + (pos - p)
            local mapped = map_take_inputs_to_lines(s, sync.inputs)
            if mapped then
              local counts = take_input_word_counts(sync.inputs)
              local words  = s.take_align_words
              local first  = 1
              for i = 1, #sync.inputs do
                local n = counts[i] or 0
                if n > 0 and first + n - 1 <= #words then
                  local t0 = words[first].start or 0
                  local t1 = words[first + n - 1]['end'] or t0
                  if src_t >= t0 - 0.05 and src_t <= t1 + 0.2 then
                    found = mapped[i] and mapped[i].line.id or nil
                    break
                  end
                end
                first = first + n
              end
            end
          end
        end
      end
    end
  end

  if found ~= s.playhead_line_id then
    s.playhead_line_id = found
    -- One-shot scroll TYLKO podczas odtwarzania — panel jest też edytorem,
    -- skakanie przy klikaniu kursorem po timeline byłoby wkurzające.
    if playing and found then
      s.dialogue_scroll_line_id = found
    end
  end
end

-- M3: spawn dialogue regen z P_EXT inputs/settings + new seed → append take.
local function spawn_dialogue_regen(s, row)
  if not row.inputs or #row.inputs == 0 then
    s.dialogue_gen_status_text  = 'Regen aborted: no inputs in P_EXT.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end
  local settings = {}
  if row.settings_json and row.settings_json ~= '' then
    local ok, decoded = pcall(json.decode, row.settings_json)
    if ok and type(decoded) == 'table' then settings = decoded end
  end
  local seed = random_seed()
  local spawn_opts = {
    inputs        = row.inputs,
    settings      = settings,
    model_id      = 'eleven_v3',
    output_format = cfg.get_tts_output_format(),
    seed          = seed,
    with_timestamps = true,   -- M5-2: alignment w odpowiedzi (bez extra callu)
  }
  local handle = voice_admin.spawn_dialogue(spawn_opts)
  if handle.status == 'error' then
    s.dialogue_gen_status_text  = 'Regen error: ' .. tostring(handle.error or 'unknown')
    s.dialogue_gen_status_color = theme.COLORS.status_error
    return
  end
  handle._spawn_opts          = spawn_opts
  handle._retry_count         = 0
  handle._regen_item_guid     = row.guid
  s.dialogue_row_handles      = s.dialogue_row_handles or {}
  s.dialogue_row_handles[row.guid] = handle
end

-- M3: on dialogue regen done → AddTake do tego itemu z extend length.
local function on_dialogue_regen_done(s, handle)
  local guid = handle._regen_item_guid
  s.dialogue_row_handles[guid] = nil
  if handle.status ~= 'done' then return end
  local item = helpers.find_item_by_guid(guid)
  if not item then return end  -- user deleted item; silently drop
  local audio_path = handle.result
  if not audio_path or not util.file_exists(audio_path) then return end
  local source_obj = reaper.PCM_Source_CreateFromFile(audio_path)
  if not source_obj then return end

  local inputs  = (handle.args and handle.args.inputs) or {}
  local seed    = handle.args and handle.args.seed
  local total_chars = 0
  for _, it in ipairs(inputs) do total_chars = total_chars + util.utf8_len(it.text or '') end

  reaper.Undo_BeginBlock()
  local new_take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(new_take, source_obj)
  build_peaks(source_obj)
  local regen_take_idx = reaper.CountTakes(item)
  reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME',
    dialogue_take_name(inputs, regen_take_idx, seed), true)
  reaper.SetActiveTake(new_take)

  local src_len = reaper.GetMediaSourceLength(source_obj) or 0
  local cur_len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
  if src_len > cur_len then
    reaper.SetMediaItemLength(item, src_len, false)
  end
  -- Update P_EXT seed (latest)
  helpers.pext_item_set(item, 'tts_dialogue_seed',         tostring(seed or 0))
  helpers.pext_item_set(item, 'tts_dialogue_generated_at', tostring(os.time()))

  reaper.UpdateItemInProject(item)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Reasonate: TTS Dialogue Regenerate (new take)', -1)

  if not handle.from_cache then
    cfg.add_tts_chars_used(handle.character_cost or total_chars)
  end
end

----------------------------------------------------------------------------
-- NS-2e Phase B: per-region regen — spawn single-voice TTS dla wybranego
-- split itemu z stored P_EXT (text + voice_id + voice_settings). Wynik
-- AddTake do tego split itemu (multi-take cycling). User wybiera REAPER
-- item w timeline → mini-section w panel pokazuje Regen button.
--
-- Uses /v1/text-to-speech (single voice endpoint) — NIE dialogue endpoint
-- (jedna kwestia = jeden głos = pasuje do single TTS API). New random seed
-- → different audio każdy regen.
----------------------------------------------------------------------------
local function spawn_split_regen(s, split_item)
  if not split_item then return end
  local split_guid = helpers.item_guid(split_item)
  if not split_guid or split_guid == '' then return end
  s.dialogue_split_regen_handles = s.dialogue_split_regen_handles or {}
  if s.dialogue_split_regen_handles[split_guid] then return end  -- already in-flight

  local text     = helpers.pext_item_get(split_item, 'split_text')     or ''
  local voice_id = helpers.pext_item_get(split_item, 'split_voice_id') or ''
  if text == '' or voice_id == '' then
    s.dialogue_gen_status_text  = 'Split regen aborted: missing text or voice_id in P_EXT.'
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end

  local stripped = text:gsub('%s+', '')
  if util.utf8_len(stripped) < MIN_TEXT_CHARS then
    s.dialogue_gen_status_text  = ('Split regen aborted: stored text too short (need at least %d chars).')
      :format(MIN_TEXT_CHARS)
    s.dialogue_gen_status_color = theme.COLORS.status_stale
    return
  end

  -- Read stored voice_settings (snapshot from split time) — fallback do defaults.
  local vs = default_speaker_voice_settings()
  local vs_raw = helpers.pext_item_get(split_item, 'split_voice_settings')
  if vs_raw and vs_raw ~= '' then
    local ok, decoded = pcall(json.decode, vs_raw)
    if ok and type(decoded) == 'table' then
      vs = normalize_speaker_voice_settings(decoded)
    end
  end

  local settings_for_api = {
    stability        = vs.stability,
    similarity_boost = vs.similarity_boost,
    style            = vs.style,
    speed            = vs.speed,
  }

  local seed = random_seed()
  local spawn_opts = {
    voice_id       = voice_id,
    text           = text,
    model_id       = 'eleven_v3',
    voice_settings = settings_for_api,
    output_format  = cfg.get_tts_output_format(),
    seed           = seed,
  }

  local handle = voice_admin.spawn_tts(spawn_opts)
  if handle.status == 'error' then
    s.dialogue_gen_status_text  = 'Split regen error: ' .. tostring(handle.error or 'unknown')
    s.dialogue_gen_status_color = theme.COLORS.status_error
    return
  end
  handle._spawn_opts       = spawn_opts
  handle._retry_count      = 0
  handle._split_item_guid  = split_guid
  s.dialogue_split_regen_handles[split_guid] = handle
  s.dialogue_gen_status_text  = ('Regenerating split region · %d chars…'):format(#text)
  s.dialogue_gen_status_color = theme.COLORS.text_dim
end

local function on_split_regen_done(s, handle)
  -- Tryb jeden-plik: handle bez itemu (klucz 'new_<line_id>') → nowy item
  -- na tracku patchów zamiast AddTake.
  if handle._patch_create then
    if s.dialogue_split_regen_handles then
      s.dialogue_split_regen_handles['new_' .. handle._patch_create.line_id] = nil
    end
    if handle.status == 'done' then create_patch_item(s, handle) end
    return
  end
  local guid = handle._split_item_guid
  if s.dialogue_split_regen_handles then
    s.dialogue_split_regen_handles[guid] = nil
  end
  if handle.status ~= 'done' then return end
  local item = helpers.find_item_by_guid(guid)
  if not item then return end  -- user deleted split item, drop silently
  local audio_path = handle.result
  if not audio_path or not util.file_exists(audio_path) then return end
  local source_obj = reaper.PCM_Source_CreateFromFile(audio_path)
  if not source_obj then return end

  reaper.Undo_BeginBlock()
  -- Patch linii (2026-06-11): po sukcesie klocek opisuje NOWĄ kwestię —
  -- P_EXT przed budową nazwy take'a (nazwa czyta split_text).
  if handle._patch_meta then
    helpers.pext_item_set(item, 'split_text',           handle._patch_meta.text)
    helpers.pext_item_set(item, 'split_voice_id',       handle._patch_meta.voice_id)
    helpers.pext_item_set(item, 'split_voice_name',     handle._patch_meta.voice_name)
    helpers.pext_item_set(item, 'split_voice_settings', handle._patch_meta.settings_json)
  end
  local new_take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(new_take, source_obj)
  build_peaks(source_obj)
  local take_idx = reaper.CountTakes(item)
  -- Take name: "Take N · {voice_name} · seed=XXXX · "excerpt""
  local txt   = helpers.pext_item_get(item, 'split_text')       or ''
  local vname = helpers.pext_item_get(item, 'split_voice_name') or '?'
  local seed  = handle.args and handle.args.seed
  local seed_str = ''
  if seed and tonumber(seed) and seed > 0 then
    seed_str = (' · seed=%08x'):format(math.floor(seed))
  end
  local excerpt = txt:gsub('[\r\n\t]', ' '):sub(1, 40)
  reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME',
    ('Take %d · %s%s · "%s"'):format(take_idx, vname, seed_str, excerpt), true)
  reaper.SetActiveTake(new_take)
  -- New take's audio file starts at 0 (fresh single TTS mp3, NIE master split).
  -- Reset D_STARTOFFS dla new take (master split takes used offset into master mp3).
  reaper.SetMediaItemTakeInfo_Value(new_take, 'D_STARTOFFS', 0)

  -- Item D_LENGTH preserved (fixed timeline layout). If new take audio dłuższy
  -- than item bounds → audio cut at item edge. Shorter → silence at end.
  -- User can manually adjust item edge w REAPER if needed.

  reaper.UpdateItemInProject(item)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Reasonate: regenerate split region', -1)

  if handle._patch_meta then
    s.dialogue_gen_status_text  = 'Line re-rendered — new take on its item.'
    s.dialogue_gen_status_color = theme.COLORS.status_done
  end

  if not handle.from_cache then
    local txt_len = util.utf8_len(handle.args and handle.args.text or '')
    cfg.add_tts_chars_used(handle.character_cost or txt_len)
  end

  s.dialogue_gen_status_text  = ('Split regen done · take %d added'):format(take_idx)
  s.dialogue_gen_status_color = theme.COLORS.status_done
end

-- Spawn TTS regen z metadanych itemu + new seed. Handle stored w
-- s.row_handles[guid]; consume_signals poll'uje + on done append take.
local function spawn_regen(s, row)
  local stripped = (row.text or ''):gsub('%s+', '')
  if util.utf8_len(stripped) < MIN_TEXT_CHARS then
    s.gen_status_text  = ('Regen aborted: stored text too short (need at least %d non-whitespace characters).'):format(MIN_TEXT_CHARS)
    s.gen_status_color = theme.COLORS.status_stale
    return
  end
  local vs = {}
  if row.voice_settings and row.voice_settings ~= '' then
    local ok, decoded = pcall(json.decode, row.voice_settings)
    if ok and type(decoded) == 'table' then vs = decoded end
  end
  local seed = random_seed()
  local spawn_opts = {
    voice_id       = row.voice_id,
    text           = row.text,
    model_id       = (row.model_id ~= '' and row.model_id) or 'eleven_v3',
    voice_settings = vs,
    output_format  = cfg.get_tts_output_format(),
    seed           = seed,
  }
  local handle = voice_admin.spawn_tts(spawn_opts)
  if handle.status == 'error' then
    s.gen_status_text  = 'Regen error: ' .. tostring(handle.error or 'unknown')
    s.gen_status_color = theme.COLORS.status_error
    return
  end
  handle._spawn_opts       = spawn_opts
  handle._retry_count      = 0
  handle._regen_item_guid  = row.guid
  handle._regen_voice_name = row.voice_name
  s.row_handles[row.guid] = handle
end

-- On regen done: AddTake to the same item + extend length if new take longer
-- (TTS may produce +/-20% length on new seed).
local function on_regen_done(s, handle)
  local guid = handle._regen_item_guid
  s.row_handles[guid] = nil
  if handle.status ~= 'done' then return end
  local item = helpers.find_item_by_guid(guid)
  if not item then return end  -- user removed item, silently drop
  local audio_path = handle.result
  if not audio_path or not util.file_exists(audio_path) then return end
  local source_obj = reaper.PCM_Source_CreateFromFile(audio_path)
  if not source_obj then return end

  reaper.Undo_BeginBlock()
  local new_take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(new_take, source_obj)
  if reaper.PCM_Source_BuildPeaks(source_obj, 0) > 0 then
    local safety = 1000
    while reaper.PCM_Source_BuildPeaks(source_obj, 1) > 0 and safety > 0 do
      safety = safety - 1
    end
    reaper.PCM_Source_BuildPeaks(source_obj, 2)
  end
  local regen_take_idx = reaper.CountTakes(item)
  local regen_seed = handle.args and handle.args.seed
  reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME',
    take_name_for(handle._regen_voice_name,
      helpers.pext_item_get(item, 'tts_text') or '',
      regen_take_idx, regen_seed),
    true)
  reaper.SetActiveTake(new_take)

  -- Extend item length jeśli new take dłuższy
  local src_len = reaper.GetMediaSourceLength(source_obj) or 0
  local cur_len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
  if src_len > cur_len then
    reaper.SetMediaItemLength(item, src_len, false)
  end

  reaper.UpdateItemInProject(item)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Reasonate: TTS Regenerate (new take)', -1)

  if not handle.from_cache then
    cfg.add_tts_chars_used(handle.character_cost or util.utf8_len(handle.args and handle.args.text or ''))
  end
end

----------------------------------------------------------------------------
-- Enhance (2026-06-11): LLM wstawia v3 audio tagi bez zmiany słów (mirror
-- przycisku "Enhance" z ElevenLabs playground — UI-only, brak endpointu API).
-- Prompty + schematy + walidator words-preserved w modules/tts_enhance.lua
-- (pure, headless-tested). Tutaj: spawn / poll-handler / apply / revert.
--
-- Gwarancja danych: walidacja i apply porównują ze SNAPSHOTEM tekstu z
-- momentu spawn — linia/tekst edytowane w trakcie requestu NIE są nadpisywane.
-- Walidacja words-preserved failuje → jeden cichy strict-retry → potem error
-- (oryginalny tekst nietknięty).
----------------------------------------------------------------------------

local function enhance_status(s, kind, text, color)
  if kind == 'dialogue' then
    s.dialogue_gen_status_text  = text
    s.dialogue_gen_status_color = color
  else
    s.gen_status_text  = text
    s.gen_status_color = color
  end
end

local function spawn_enhance(s, opts)
  opts = opts or {}
  local llm  = require 'modules.llm'
  local kind = (s.sub_mode == 'dialogue') and 'dialogue' or 'single'

  local task, system_prompt, user_prompt, snapshot
  if kind == 'dialogue' then
    if #(s.dialogue_lines or {}) == 0 then
      enhance_status(s, kind, 'Add dialogue lines before enhancing.',
        theme.COLORS.status_error)
      return
    end
    local labels = {}
    for _, sp in ipairs(s.dialogue_speakers or {}) do labels[sp.id] = sp.label end
    snapshot = {}
    for _, ln in ipairs(s.dialogue_lines) do
      snapshot[#snapshot + 1] = { id = ln.id, speaker_id = ln.speaker_id, text = ln.text or '' }
    end
    task          = tts_enhance.TASK_ENHANCE_DIALOGUE
    system_prompt = tts_enhance.build_system_prompt(s.enhance_intensity,
      { dialogue = true, strict_retry = opts.strict_retry,
        allow_punct = s.enhance_punct == true })
    user_prompt   = tts_enhance.build_user_prompt_dialogue(snapshot, labels, s.enhance_note)
  else
    local text = s.text_buffer or ''
    if util.utf8_len((text:gsub('%s', ''))) < MIN_TEXT_CHARS then
      enhance_status(s, kind, 'Type text before enhancing.', theme.COLORS.status_error)
      return
    end
    snapshot      = { text = text }
    task          = tts_enhance.TASK_ENHANCE_SINGLE
    system_prompt = tts_enhance.build_system_prompt(s.enhance_intensity,
      { strict_retry = opts.strict_retry, allow_punct = s.enhance_punct == true })
    user_prompt   = tts_enhance.build_user_prompt_single(text, s.enhance_note)
  end

  -- Output ≈ wejście + tagi + JSON overhead (~3 znaki/token, zapas ×1.5).
  local h = llm.spawn_json({
    task          = task,
    purpose       = 'enhance',   -- per-feature override (Settings → AI)
    system_prompt = system_prompt,
    user_prompt   = user_prompt,
    max_tokens    = math.min(4000, 800 + math.ceil(#user_prompt / 2)),
    temperature   = 0.6,
  })
  if h.status == 'error' then
    enhance_status(s, kind, 'Enhance: ' .. tostring(h.error), theme.COLORS.status_error)
    return
  end
  h.enhance_kind      = kind
  h._enhance_snapshot = snapshot
  h._enhance_strict   = opts.strict_retry or false
  -- Tryb walidacji zamrożony per request — toggle w trakcie nie zmienia
  -- reguł oceny już lecącej odpowiedzi.
  h._enhance_punct    = s.enhance_punct == true
  s.enhance_handle    = h
  enhance_status(s, kind, 'Enhance — adding audio tags…', theme.COLORS.text_dim)
end

local function request_enhance(s)
  if s.enhance_handle then return end
  spawn_enhance(s, nil)
end

-- Przywraca tekst sprzed ostatniego Enhance (snapshot tylko zaaplikowanych
-- linii). Revert nadpisuje też edycje zrobione PO Enhance — standardowa
-- semantyka "revert", tooltip przy przycisku to mówi.
local function revert_enhance(s)
  local rev = s.enhance_revert
  if not rev then return end
  if rev.kind == 'single' then
    s.text_buffer = rev.text
    if _input_cb then
      pcall(reaper.ImGui_Function_SetValue, _input_cb, 'target_cursor', #rev.text)
      pcall(reaper.ImGui_Function_SetValue, _input_cb, 'set_cursor', 1)
    end
    s.pending_focus_input = true
  else
    local tdp = require 'modules.gui.tts_dialogue_panel'
    for _, ln in ipairs(s.dialogue_lines or {}) do
      local old = rev.texts[ln.id]
      if old then
        ln.text = old
        tdp.reset_line_wrap(ln.id)
        if s.dialogue_edit_line_id == ln.id then s.dialogue_edit_line_id = nil end
      end
    end
  end
  s.enhance_revert = nil
  mark_dirty(s)
  theme.flash('tts_enhance', 'Reverted to text before Enhance.', theme.COLORS.text_dim)
end

local function handle_enhance_done(s, h)
  local kind = h.enhance_kind
  local data = h.result and h.result.data
  local snap = h._enhance_snapshot

  if kind == 'single' then
    if (s.text_buffer or '') ~= snap.text then
      enhance_status(s, kind, 'Text changed while enhancing — click Enhance again.',
        theme.COLORS.status_stale)
      return
    end
    local enhanced = (type(data) == 'table') and data.text or nil
    local stats, verr = tts_enhance.validate_enhanced_text(snap.text, enhanced,
      { allow_punct = h._enhance_punct })
    if not stats then
      if not h._enhance_strict then
        enhance_status(s, kind, 'Model altered the text — retrying once…',
          theme.COLORS.text_dim)
        spawn_enhance(s, { strict_retry = true })
        return
      end
      enhance_status(s, kind,
        'Enhance failed (' .. tostring(verr) .. ') — original text kept.',
        theme.COLORS.status_error)
      return
    end
    if enhanced == snap.text or stats.tags_added == 0 then
      enhance_status(s, kind, nil, nil)
      theme.flash('tts_enhance', 'No changes suggested — text already reads well.',
        theme.COLORS.text_dim)
      return
    end
    s.enhance_revert = { kind = 'single', text = snap.text }
    s.text_buffer    = enhanced
    -- Mirror palety tagów: refocus + caret na końcu wymusza przeładowanie
    -- bufora widgetu (user w polu w trakcie requestu → internal buffer
    -- nadpisałby enhanced tekst przy następnym keystroke'u).
    if _input_cb then
      pcall(reaper.ImGui_Function_SetValue, _input_cb, 'target_cursor', #enhanced)
      pcall(reaper.ImGui_Function_SetValue, _input_cb, 'set_cursor', 1)
    end
    s.pending_focus_input = true
    mark_dirty(s)
    enhance_status(s, kind, nil, nil)
    local msg = ('Enhanced — %d %s added.'):format(
      stats.tags_added, stats.tags_added == 1 and 'tag' or 'tags')
    if util.utf8_len(enhanced) > find_model(s.model_id).char_limit then
      msg = msg .. ' Over the character limit now — trim or Revert.'
      theme.flash('tts_enhance', msg, theme.COLORS.status_stale)
    else
      theme.flash('tts_enhance', msg)
    end
    return
  end

  -- Dialogue: plan z walidacją per linia (pure), apply tylko na liniach
  -- niezmienionych od spawn.
  local plan, perr = tts_enhance.plan_dialogue_apply(snap, data,
    { allow_punct = h._enhance_punct })
  if not plan or (#plan.changes == 0 and #plan.invalid > 0) then
    if not h._enhance_strict then
      enhance_status(s, kind, 'Model altered the text — retrying once…',
        theme.COLORS.text_dim)
      spawn_enhance(s, { strict_retry = true })
      return
    end
    enhance_status(s, kind,
      'Enhance failed (' .. tostring(perr or 'model altered the words') ..
      ') — original text kept.',
      theme.COLORS.status_error)
    return
  end
  if #plan.changes == 0 then
    enhance_status(s, kind, nil, nil)
    theme.flash('tts_enhance', 'No changes suggested — dialogue already reads well.',
      theme.COLORS.text_dim)
    return
  end

  local tdp = require 'modules.gui.tts_dialogue_panel'
  local snap_text_by_id = {}
  for _, sl in ipairs(snap) do snap_text_by_id[sl.id] = sl.text end
  local line_by_id = {}
  for _, ln in ipairs(s.dialogue_lines or {}) do line_by_id[ln.id] = ln end

  local revert_texts, applied, tags_added, edited_skipped = {}, 0, 0, 0
  for _, ch in ipairs(plan.changes) do
    local ln = line_by_id[ch.id]
    if ln then
      if (ln.text or '') ~= snap_text_by_id[ch.id] then
        edited_skipped = edited_skipped + 1
      else
        revert_texts[ch.id] = ln.text
        ln.text = ch.new_text
        tdp.reset_line_wrap(ch.id)
        if s.dialogue_edit_line_id == ch.id then s.dialogue_edit_line_id = nil end
        applied    = applied + 1
        tags_added = tags_added + ch.tags_added
      end
    end
  end

  if applied == 0 then
    enhance_status(s, kind, 'Lines changed while enhancing — click Enhance again.',
      theme.COLORS.status_stale)
    return
  end

  s.enhance_revert = { kind = 'dialogue', texts = revert_texts }
  mark_dirty(s)
  enhance_status(s, kind, nil, nil)
  local msg = ('Enhanced %d %s · %d tags added.'):format(
    applied, applied == 1 and 'line' or 'lines', tags_added)
  if #plan.invalid > 0 then
    msg = msg .. (' %d kept (model altered words).'):format(#plan.invalid)
  end
  if edited_skipped > 0 then
    msg = msg .. (' %d skipped (edited meanwhile).'):format(edited_skipped)
  end
  -- Tagi liczą się do limitu znaków API — ostrzeż, gdy Enhance go przekroczył
  -- (licznik w pasku robi się czerwony, Generate i tak jest zablokowany).
  if count_dialogue_chars(s) > DIALOGUE_MAX_CHARS then
    msg = msg .. ' Over the character limit now — trim or Revert.'
    theme.flash('tts_enhance', msg, theme.COLORS.status_stale)
  else
    theme.flash('tts_enhance', msg)
  end
end

----------------------------------------------------------------------------
-- Render — wydzielone (audit M3-1, 2026-06-10) do:
--   gui/tts_panel.lua          — single sub-mode (render_content + palette)
--   gui/tts_dialogue_panel.lua — dialogue sub-mode (speakers/lines/content/palette)
-- Czysto mechaniczny podział (plik miał 4257 LOC). Panele dostają tabelę A
-- (akcje + stałe tego modułu) przez init() — logika/stan zostają tutaj.
----------------------------------------------------------------------------
local tts_panel          = require 'modules.gui.tts_panel'
local tts_dialogue_panel = require 'modules.gui.tts_dialogue_panel'

local A = {
  add_dialogue_line = add_dialogue_line,
  add_dialogue_speaker = add_dialogue_speaker,
  apply_dialogue_cast = apply_dialogue_cast,
  apply_project_cast = apply_project_cast,
  apply_preset = apply_preset,
  apply_track_tts_defaults = apply_track_tts_defaults,
  build_current_dialogue_cast = build_current_dialogue_cast,
  build_current_preset = build_current_preset,
  cancel_dialogue_generation = cancel_dialogue_generation,
  cancel_generation = cancel_generation,
  count_dialogue_chars = count_dialogue_chars,
  cycle_take = cycle_take,
  default_speaker_voice_settings = default_speaker_voice_settings,
  dialogue_take_sync = dialogue_take_sync,
  regen_dialogue_take = regen_dialogue_take,
  request_take_line_play = request_take_line_play,
  request_line_patch = request_line_patch,
  scan_dialogue_line_items = scan_dialogue_line_items,
  delete_active_take_action = delete_active_take_action,
  ENHANCE_INTENSITIES = tts_enhance.INTENSITIES,
  request_enhance = request_enhance,
  revert_enhance = revert_enhance,
  DIALOGUE_LIMIT_AMBER = DIALOGUE_LIMIT_AMBER,
  DIALOGUE_LIMIT_SOFT = DIALOGUE_LIMIT_SOFT,
  DIALOGUE_MAX_CHARS = DIALOGUE_MAX_CHARS,
  DIALOGUE_MAX_SPEAKERS = DIALOGUE_MAX_SPEAKERS,
  find_speaker_by_id = find_speaker_by_id,
  format_duration = format_duration,
  format_gen_time = format_gen_time,
  format_short_text = format_short_text,
  get_input_callback = get_input_callback,
  list_tracks_for_dropdown = list_tracks_for_dropdown,
  mark_dirty = mark_dirty,
  MODELS = MODELS,
  move_dialogue_line = move_dialogue_line,
  normalize_speaker_voice_settings = normalize_speaker_voice_settings,
  remove_dialogue_line = remove_dialogue_line,
  remove_dialogue_speaker = remove_dialogue_speaker,
  request_insert_at_cursor = request_insert_at_cursor,
  reveal_active_take_audio = reveal_active_take_audio,
  scan_dialogue_items_on_track = scan_dialogue_items_on_track,
  scan_tts_items_on_track = scan_tts_items_on_track,
  select_item_in_timeline = select_item_in_timeline,
  spawn_dialogue_regen = spawn_dialogue_regen,
  import_dialogue_script = import_dialogue_script,
  spawn_generate = spawn_generate,
  spawn_generate_dialogue = spawn_generate_dialogue,
  spawn_regen = spawn_regen,
  spawn_solo_preview = spawn_solo_preview,
  spawn_split_regen = spawn_split_regen,
  spawn_variants = spawn_variants,
  toggle_item_lock = toggle_item_lock,
  V3_STABILITY_MODES = V3_STABILITY_MODES,
}
tts_panel.init(A)
tts_dialogue_panel.init(A)

----------------------------------------------------------------------------
-- Public render — sub-mode toggle u góry + dispatch.
--   sub_mode='single'   → render_content (existing NS-2b single TTS panel)
--   sub_mode='dialogue' → render_dialogue_content (NS-2c multi-speaker)
-- Layout dla obu: split content (fills - palette) + palette right (v3 only
-- for single; always for dialogue bo dialogue jest v3-only).
-- BeginChild contract: visible=true → wywołaj EndChild; visible=false →
-- ReaImGui sam pop'uje, NIE wywoływać EndChild (per CLAUDE.md invariant #6).
----------------------------------------------------------------------------
local SUB_MODE_ITEMS = {
  { key = 'single',   label = 'Single voice',
    tooltip = 'One voice reads the whole text.' },
  { key = 'dialogue', label = 'Multi-speaker dialogue',
    tooltip = 'Multiple voices generated together in one natural-flowing audio.\n' ..
              'v3 model only. Max 10 unique voices, ~2000 chars total.' },
}

function M.render(ctx, state, deps)
  local s = init_state(state)

  -- ====== NS-2c: Sub-mode toggle (Single voice / Multi-speaker dialogue) ======
  -- W3 (2026-06-11): radio → theme.segmented sm (akcent TTS, mirror paska trybów).
  local cur_sub = s.sub_mode == 'dialogue' and 'dialogue' or 'single'
  local sub_clicked = theme.segmented(ctx, 'tts_sub_mode', SUB_MODE_ITEMS,
    cur_sub, { size = 'sm', accent = theme.MODE_ACCENTS.tts })
  if sub_clicked and sub_clicked ~= cur_sub then
    s.sub_mode = sub_clicked
    mark_dirty(s)
  end
  -- Toggle palety tagów (W3 2026-06-11, user request) — tylko gdy paleta
  -- w ogóle aplikuje się do bieżącego widoku (dialog zawsze v3; single = v3).
  local palette_applicable = (s.sub_mode == 'dialogue')
    or (find_model(s.model_id).audio_tags == true)
  if palette_applicable then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
    -- +3px: optyczne wycentrowanie SmallButtona (~18px) względem railu 24px.
    reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + 3)
    if reaper.ImGui_SmallButton(ctx, s.palette_hidden
        and 'Show tags' or 'Hide tags') then
      s.palette_hidden = not s.palette_hidden
      mark_dirty(s)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Show / hide the audio tags palette (right column).')
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  local PALETTE_W = 220
  local GAP       = theme.SPACING.md

  if s.sub_mode == 'dialogue' then
    -- Dialogue sub-mode: palette domyślnie widoczna (v3-only endpoint),
    -- chowania przyciskiem "Hide tags" u góry.
    local busy = s.dialogue_gen_handle ~= nil
    sync_playhead_line(s)  -- playhead → aktywna kwestia (tint + scroll)
    local show_palette = not s.palette_hidden
    -- W3 (mniej przewijania): kolumna content = scroll-child skrócony o
    -- przyklejony pasek akcji (Generate/ustawienia ZAWSZE widoczne
    -- niezależnie od liczby linii dialogu) + pasek pod spodem. Zagnieżdżenie
    -- w zewnętrznym childzie trzyma paletę po prawej na pełnej wysokości.
    local ACTIONS_H = 100
    local col_visible = reaper.ImGui_BeginChild(ctx, 'tts_content_col',
      show_palette and -(PALETTE_W + GAP) or -1, 0)
    if col_visible then
      local content_visible = reaper.ImGui_BeginChild(ctx, 'tts_content',
        0, -ACTIONS_H)
      if content_visible then
        tts_dialogue_panel.render(ctx, state, deps, s, busy)
        reaper.ImGui_EndChild(ctx)
      end
      tts_dialogue_panel.render_actions(ctx, state, deps, s, busy)
      reaper.ImGui_EndChild(ctx)
    end
    if show_palette then
      reaper.ImGui_SameLine(ctx, 0, GAP)
      local palette_visible = reaper.ImGui_BeginChild(ctx, 'tts_palette', PALETTE_W, 0)
      if palette_visible then
        tts_dialogue_panel.render_palette(ctx, s)
        reaper.ImGui_EndChild(ctx)
      end
    end
  else
    -- Single sub-mode: existing NS-2b path. Palette only for v3 model.
    local model = find_model(s.model_id)
    local busy  = s.gen_handle ~= nil
    local show_palette = model.audio_tags == true and not s.palette_hidden
    local content_w = show_palette and -(PALETTE_W + GAP) or -1
    local content_visible = reaper.ImGui_BeginChild(ctx, 'tts_content',
      content_w, 0)
    if content_visible then
      tts_panel.render(ctx, state, deps, s, model, busy)
      reaper.ImGui_EndChild(ctx)
    end
    if show_palette then
      reaper.ImGui_SameLine(ctx, 0, GAP)
      local palette_visible = reaper.ImGui_BeginChild(ctx, 'tts_palette',
        PALETTE_W, 0)
      if palette_visible then
        tts_panel.render_palette(ctx, s, _input_cb)
        reaper.ImGui_EndChild(ctx)
      end
    end
  end

  -- Keyboard shortcut (poza BeginChild scope żeby działało gdy focus na text)
  process_shortcuts(ctx, s, deps)
end

----------------------------------------------------------------------------
-- Mode-specific modals (none in M1 — voice_picker is global singleton).
----------------------------------------------------------------------------
function M.render_modals(ctx, state, deps)
  -- intentionally empty
end

----------------------------------------------------------------------------
-- Post-frame signals: poll async TTS handle; on done → import audio item.
----------------------------------------------------------------------------
function M.consume_signals(state, deps)
  local s = init_state(state)

  -- Persistence: flush ProjExtState after debounce window
  if s._dirty and util.now() - (s._dirty_at or 0) >= DIRTY_DEBOUNCE_S then
    save_state_to_proj(s)
    s._dirty = false
  end

  -- Enhance: jedna krótka prośba LLM (forced JSON). Bez retry-429 — re-klik
  -- jest tani; stale watchdog przez async_op jak pozostałe handle. done może
  -- odpalić strict-retry (handle_enhance_done → spawn_enhance ustawia handle
  -- na nowo — dlatego czyścimy PRZED handlerem).
  if s.enhance_handle then
    local h = s.enhance_handle
    local llm = require 'modules.llm'
    llm.poll(h)
    if h.status == 'running' then async_op.force_error_if_stale(h, 'Enhance') end
    if h.status == 'done' then
      s.enhance_handle = nil
      handle_enhance_done(s, h)
    elseif h.status == 'error' then
      s.enhance_handle = nil
      enhance_status(s, h.enhance_kind, 'Enhance: ' .. tostring(h.error),
        theme.COLORS.status_error)
    end
  end

  -- Per-line playback: poll forced-alignment take'a (lazy, cache per audio)
  consume_take_align(s)

  -- Variants (B#1): respawn next variant when previous import completed and
  -- gen_handle is free. Failure (validation error, no voice) clears state.
  if s.variant_respawn_pending and not s.gen_handle then
    s.variant_respawn_pending = false
    spawn_generate(s, deps)
    if not s.gen_handle then
      s.variants_remaining   = 0
      s._variants_initial    = nil
      s.force_append_to_guid = nil
    end
  end

  -- Main Generate handle (with retry-on-429 backoff scheduling)
  if s.gen_handle then
    local h = s.gen_handle
    if h._retry_at then
      if util.now() >= h._retry_at then
        h._retry_at = nil
        local nh = voice_admin.spawn_tts(h._spawn_opts)
        if nh.status == 'error' then
          s.gen_status_text    = 'Retry failed: ' .. tostring(nh.error or 'unknown')
          s.gen_status_color   = theme.COLORS.status_error
          s.gen_handle         = nil
          s.gen_target_track   = nil
          s.gen_voice_meta     = nil
          s.gen_append_to_guid = nil
          s.variants_remaining = 0
          s._variants_initial  = nil
          s.force_append_to_guid = nil
        else
          nh._spawn_opts  = h._spawn_opts
          nh._retry_count = h._retry_count
          s.gen_handle    = nh
          s.gen_status_text  = ('Generating %d chars (retry %d/%d)…'):format(
            #h._spawn_opts.text, h._retry_count, MAX_TTS_RETRIES)
          s.gen_status_color = theme.COLORS.text_dim
        end
      else
        local remaining = math.ceil(h._retry_at - util.now())
        s.gen_status_text  = ('Rate limited, retry %d/%d in %ds…'):format(
          h._retry_count, MAX_TTS_RETRIES, remaining)
        s.gen_status_color = theme.COLORS.text_dim
      end
    else
      voice_admin.poll(h)
      if h.status == 'running' then async_op.force_error_if_stale(h, 'TTS generate') end
      if h.status == 'done' then
        import_tts_result(s, deps)
      elseif h.status == 'error' then
        if schedule_retry(h) then
          local remaining = math.ceil(h._retry_at - util.now())
          s.gen_status_text  = ('Rate limited, retry %d/%d in %ds…'):format(
            h._retry_count, MAX_TTS_RETRIES, remaining)
          s.gen_status_color = theme.COLORS.text_dim
        else
          s.gen_status_text    = 'TTS error: ' .. tostring(h.error or 'unknown')
          s.gen_status_color   = theme.COLORS.status_error
          s.gen_handle         = nil
          s.gen_target_track   = nil
          s.gen_voice_meta     = nil
          s.gen_append_to_guid = nil
          s.variants_remaining = 0
          s._variants_initial  = nil
          s.force_append_to_guid = nil
          if deps and deps.action_msg_setter then
            deps.action_msg_setter('TTS failed', theme.COLORS.status_error)
          end
        end
      end
    end
  end

  -- NS-2c: dialogue Generate handle (mirror single pattern z retry-on-429)
  if s.dialogue_gen_handle then
    local h = s.dialogue_gen_handle
    if h._retry_at then
      if util.now() >= h._retry_at then
        h._retry_at = nil
        local nh = voice_admin.spawn_dialogue(h._spawn_opts)
        if nh.status == 'error' then
          s.dialogue_gen_status_text     = 'Retry failed: ' .. tostring(nh.error or 'unknown')
          s.dialogue_gen_status_color    = theme.COLORS.status_error
          s.dialogue_gen_handle          = nil
          s.dialogue_gen_target_track    = nil
          s.dialogue_gen_append_to_guid  = nil
          s.dialogue_force_append_to_guid = nil
        else
          nh._spawn_opts  = h._spawn_opts
          nh._retry_count = h._retry_count
          s.dialogue_gen_handle = nh
          local total = 0
          for _, it in ipairs(h._spawn_opts.inputs or {}) do total = total + util.utf8_len(it.text or '') end
          s.dialogue_gen_status_text  = ('Generating %d chars (retry %d/%d)…'):format(
            total, h._retry_count, MAX_TTS_RETRIES)
          s.dialogue_gen_status_color = theme.COLORS.text_dim
        end
      else
        local remaining = math.ceil(h._retry_at - util.now())
        s.dialogue_gen_status_text  = ('Rate limited, retry %d/%d in %ds…'):format(
          h._retry_count, MAX_TTS_RETRIES, remaining)
        s.dialogue_gen_status_color = theme.COLORS.text_dim
      end
    else
      voice_admin.poll(h)
      if h.status == 'running' then async_op.force_error_if_stale(h, 'Dialogue generate') end
      if h.status == 'done' then
        import_dialogue_result(s, deps)
      elseif h.status == 'error' then
        if schedule_retry(h) then
          local remaining = math.ceil(h._retry_at - util.now())
          s.dialogue_gen_status_text  = ('Rate limited, retry %d/%d in %ds…'):format(
            h._retry_count, MAX_TTS_RETRIES, remaining)
          s.dialogue_gen_status_color = theme.COLORS.text_dim
        else
          s.dialogue_gen_status_text     = 'Dialogue error: ' .. tostring(h.error or 'unknown')
          s.dialogue_gen_status_color    = theme.COLORS.status_error
          s.dialogue_gen_handle          = nil
          s.dialogue_gen_target_track    = nil
          s.dialogue_gen_append_to_guid  = nil
          s.dialogue_force_append_to_guid = nil
          if deps and deps.action_msg_setter then
            deps.action_msg_setter('TTS dialogue failed', theme.COLORS.status_error)
          end
        end
      end
    end
  end

  -- NS-2d: dialogue split STT poll. Independent od main gen handle. Fires
  -- po pomyślnym imporcie master mp3 jeśli config flag ON. On done:
  -- perform_dialogue_split tworzy N speaker tracks + items per region.
  if s.dialogue_split_handle then
    local h = s.dialogue_split_handle
    stt.poll_transcribe(h)
    if h.status == 'running' then async_op.force_error_if_stale(h, 'Split STT') end
    if h.status == 'done' then
      perform_dialogue_split(s, deps)
    elseif h.status == 'error' then
      s.dialogue_gen_status_text  = 'Split STT failed: ' .. tostring(h.error or 'unknown')
      s.dialogue_gen_status_color = theme.COLORS.status_stale  -- non-fatal — master still works
      s.dialogue_split_handle                 = nil
      s.dialogue_split_master_guid            = nil
      s.dialogue_split_master_position        = nil
      s.dialogue_split_master_audio_path      = nil
      s.dialogue_split_speakers_chronological = nil
    else
      -- pending — show progress in status text
      local elapsed = util.now() - (h.started_at or util.now())
      s.dialogue_gen_status_text  = ('Splitting per speaker · %s %.1fs…'):format(
        voice_admin.spinner_glyph(), elapsed)
      s.dialogue_gen_status_color = theme.COLORS.text_dim
    end
  end

  -- NS-2c M2: per-line SOLO preview handles. One-shot — on done: play CF_Preview
  -- + clear handle. On error: just clear (inline failure, no status text spam).
  if s.dialogue_solo_handles then
    for line_id, h in pairs(s.dialogue_solo_handles) do
      voice_admin.poll(h)
      if h.status == 'running' then async_op.force_error_if_stale(h, 'Line preview') end
      if h.status == 'done' then
        local prev_id = 'tts_dialogue_solo_' .. line_id
        preview.play_file(h.result, prev_id, { volume = 0.8 })
        if not h.from_cache then
          -- Single TTS call billed as normal char usage (M6-6: header
          -- character-cost = realny koszt serwera, gdy dostępny).
          local txt_len = util.utf8_len(h.args and h.args.text or '')
          cfg.add_tts_chars_used(h.character_cost or txt_len)
        end
        s.dialogue_solo_handles[line_id] = nil
      elseif h.status == 'error' then
        -- User-caught 2026-07-11: błąd solo (np. głos niekompatybilny z v3)
        -- był POŁYKANY — spinner znikał i nic. Teraz status + przyczyna.
        s.dialogue_gen_status_text  = 'Line preview failed: ' .. tostring(h.error or '?')
        s.dialogue_gen_status_color = theme.COLORS.status_error
        s.dialogue_solo_handles[line_id] = nil
      end
    end
  end

  -- NS-2e Phase B: per-split-region regen handles. One per split item guid.
  -- On done → on_split_regen_done AddTake to split item. Retry-on-429 mirror
  -- pattern z dialogue_row_handles.
  if s.dialogue_split_regen_handles then
    for guid, h in pairs(s.dialogue_split_regen_handles) do
      if h._retry_at then
        if util.now() >= h._retry_at then
          h._retry_at = nil
          local nh = voice_admin.spawn_tts(h._spawn_opts)
          if nh.status == 'error' then
            s.dialogue_gen_status_text  = 'Split regen retry failed: ' .. tostring(nh.error or 'unknown')
            s.dialogue_gen_status_color = theme.COLORS.status_error
            s.dialogue_split_regen_handles[guid] = nil
          else
            nh._spawn_opts        = h._spawn_opts
            nh._retry_count       = h._retry_count
            nh._split_item_guid   = h._split_item_guid
            -- Patch linii (2026-06-11): meta podróżuje przez retry — bez
            -- tego respawn po 429 gubił P_EXT update / tworzenie itemu.
            nh._patch_meta        = h._patch_meta
            nh._patch_create      = h._patch_create
            s.dialogue_split_regen_handles[guid] = nh
          end
        end
      else
        voice_admin.poll(h)
        if h.status == 'running' then async_op.force_error_if_stale(h, 'Split regen') end
        if h.status == 'done' then
          on_split_regen_done(s, h)  -- clears handle
        elseif h.status == 'error' then
          if not schedule_retry(h) then
            s.dialogue_gen_status_text  = ('Split regen error: %s'):format(tostring(h.error or 'unknown'))
            s.dialogue_gen_status_color = theme.COLORS.status_error
            s.dialogue_split_regen_handles[guid] = nil
          end
        end
      end
    end
  end

  -- NS-2c M3: per-row dialogue regen handles. Mirror single mode row_handles
  -- pattern but for dialogue items. On done → on_dialogue_regen_done (append take).
  if s.dialogue_row_handles then
    for guid, h in pairs(s.dialogue_row_handles) do
      if h._retry_at then
        if util.now() >= h._retry_at then
          h._retry_at = nil
          local nh = voice_admin.spawn_dialogue(h._spawn_opts)
          if nh.status == 'error' then
            s.dialogue_gen_status_text  = 'Regen retry failed: ' .. tostring(nh.error or 'unknown')
            s.dialogue_gen_status_color = theme.COLORS.status_error
            s.dialogue_row_handles[guid] = nil
          else
            nh._spawn_opts          = h._spawn_opts
            nh._retry_count         = h._retry_count
            nh._regen_item_guid     = h._regen_item_guid
            s.dialogue_row_handles[guid] = nh
          end
        end
      else
        voice_admin.poll(h)
        if h.status == 'running' then async_op.force_error_if_stale(h, 'Dialogue regen') end
        if h.status == 'done' then
          on_dialogue_regen_done(s, h)  -- clears s.dialogue_row_handles[guid]
        elseif h.status == 'error' then
          if not schedule_retry(h) then
            s.dialogue_gen_status_text  = ('Regen error: %s'):format(tostring(h.error or 'unknown'))
            s.dialogue_gen_status_color = theme.COLORS.status_error
            s.dialogue_row_handles[guid] = nil
          end
        end
      end
    end
  end

  -- M3: per-row regen handles (concurrent, one per item; same retry pattern).
  for guid, h in pairs(s.row_handles) do
    if h._retry_at then
      if util.now() >= h._retry_at then
        h._retry_at = nil
        local nh = voice_admin.spawn_tts(h._spawn_opts)
        if nh.status == 'error' then
          s.gen_status_text  = 'Regen retry failed: ' .. tostring(nh.error or 'unknown')
          s.gen_status_color = theme.COLORS.status_error
          s.row_handles[guid] = nil
        else
          nh._spawn_opts       = h._spawn_opts
          nh._retry_count      = h._retry_count
          nh._regen_item_guid  = h._regen_item_guid
          nh._regen_voice_name = h._regen_voice_name
          s.row_handles[guid]  = nh
        end
      end
      -- still waiting backoff: per-row spinner already rendered via row_handles[guid]
    else
      voice_admin.poll(h)
      if h.status == 'running' then async_op.force_error_if_stale(h, 'Regen') end
      if h.status == 'done' then
        on_regen_done(s, h)  -- clears s.row_handles[guid]
      elseif h.status == 'error' then
        if not schedule_retry(h) then
          s.gen_status_text  = ('Regen error: %s'):format(tostring(h.error or 'unknown'))
          s.gen_status_color = theme.COLORS.status_error
          s.row_handles[guid] = nil
        end
        -- schedule_retry true → keep handle in map with _retry_at; respawn next tick
      end
    end
  end
end

----------------------------------------------------------------------------
-- atexit cleanup: flush dirty state to ProjExtState synchronously (REAPER
-- close within debounce window would otherwise drop unsaved changes).
----------------------------------------------------------------------------
function M.shutdown(state)
  if not state or not state.mode_state then return end
  local s = state.mode_state('tts')
  if s and s._initialized and s._dirty and s._loaded_proj then
    pcall(save_state_to_proj, s, s._loaded_proj)
  end
end

return M
