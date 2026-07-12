-- modules/modes/sfx.lua
-- NS-SFX (2026-06-10): Sound FX mode — efekty dźwiękowe z ElevenLabs
-- POST /v1/sound-generation. Dwa pod-tryby:
--   'describe' — user pisze prompt ręcznie → Generate N propozycji →
--                ▶ preview → Insert at playhead na track "SFX".
--   'scene'    — user zaznacza item źródłowy (+ opcjonalna time selection
--                zawężająca fragment) → STT fragmentu (Scribe, cache) →
--                LLM sound-designer brief (llm.spawn_json, 4 providery) →
--                2-3 EDYTOWALNE kandydackie prompty → Generate → Insert
--                w pozycji sceny.
--
-- Konwencje: panel (gui/sfx_panel.lua) mutuje stan + ustawia s.req_* flagi;
-- spawny/polle/insert wykonuje consume_signals (gui nie dotyka projektu
-- bezpośrednio — patrz SESSION.md "Granice modułów"). Async: voice_admin
-- spawn_sfx/poll + async_op stale/retry — mirror modes/tts row_handles.

local helpers     = require 'modules.reaper_helpers'
local cfg         = require 'modules.config'
local util        = require 'modules.util'
local theme       = require 'modules.theme'
local colors      = require 'modules.colors'
local voice_admin = require 'modules.voice_admin'
local async_op    = require 'modules.async_op'
local stt         = require 'modules.stt'
local transcript  = require 'modules.transcript'
local sfx_panel   = require 'modules.gui.sfx_panel'

local M = {}

M.CREDITS_PER_SECOND = 40      -- SFX: per ElevenLabs docs (duration specified)
M.DUR_MIN, M.DUR_MAX = 0.5, 30                 -- SFX (API: 0.5-30 s)
M.MUSIC_DUR_MIN, M.MUSIC_DUR_MAX = 3, 600      -- Music (API: 3000-600000 ms)
-- T9c (user 2026-07-11): gęstość podąża za GATUNKIEM i sceną — bogate
-- słuchowisko (foley każdej akcji + warstwy ambientu + muzyka) potrzebuje
-- 8-10 propozycji, audiobook 2-4. Twardy sufit 10; realną liczbę wybiera
-- LLM wg per-preset PACKAGE guidance + liczby zdarzeń w transkrypcie.
M.MAX_CANDIDATES     = 10

-- Loop a muzyka (user decision 2026-06-10): /v1/music NIE ma parametru loop,
-- a instrukcja "seamless loop" w prompcie jest ignorowana (live-tested) —
-- muzyka NIE oferuje pętli (user loopuje ręcznie w REAPER gdy chce).
-- Krótkie muzyczne loopy (pad/drone/rytm ≤30 s) robi silnik SFX, który MA
-- parametr loop — LLM przy analizie sceny proponuje je jako kind=ambience.

-- Kolory rodzajów propozycji — jedno źródło dla pill/pasków w panelu
-- (sfx_panel czyta przez mode().KIND_COLORS) i koloru tracka "Music".
M.KIND_COLORS = {
  one_shot = 0xF43F5EFF,   -- rose (= MODE_ACCENTS.sfx = track SFX)
  ambience = 0x14B8A6FF,   -- teal
  music    = 0xD946EFFF,   -- fuchsia (= track Music)
}

local MAX_RETRIES   = async_op.MAX_RETRIES
local RETRY_BACKOFF = async_op.RETRY_BACKOFF

----------------------------------------------------------------------------
-- Scene style presets — brief (EN) wchodzi do system promptu LLM.
-- Mirror wzorca dubbing_project.STYLE_PRESETS (label + brief, ORDER dla UI).
----------------------------------------------------------------------------
-- T9c: `package` = kompozycja i gęstość typowej oprawy GATUNKU (wchodzi do
-- system promptu jako PACKAGE guidance — LLM dobiera liczbę i mix
-- kandydatów z wyczuciem formatu, w suficie MAX_CANDIDATES).
M.SCENE_PRESETS = {
  film_drama = {
    label = 'Film / drama',
    brief = 'Cinematic realism: diegetic sounds and subtle room ambience that ground the scene. No musical stingers unless the text clearly calls for one.',
    package = 'Typical package: room tone + 2-4 diegetic one-shots anchored to events + optional restrained underscore. Usually 4-6 candidates.',
  },
  audio_drama = {
    label = 'Audio drama / fiction',
    brief = 'Radio-play storytelling where SOUND carries the picture: every action the text mentions can be heard, spaces are built from layered ambience, and transitions read clearly without visuals.',
    package = 'Rich package: this is the densest format. Foley one-shot for EVERY distinct action mentioned (doors, steps, objects, weather), 1-2 layered ambiences per location (room tone + exterior/weather), scene-transition accents, optional underscore bed, and intro/outro themes when the fragment opens or closes an episode. 6-10 candidates are normal for a busy scene.',
  },
  horror_thriller = {
    label = 'Horror / thriller',
    brief = 'Tension-first design: low drones, uneasy ambience, sudden accents. Sounds may exaggerate reality to build dread.',
    package = 'Typical package: constant uneasy drone/bed + room tone layer + 2-4 sudden accents/stingers timed to the text. Usually 5-8 candidates.',
  },
  comedy = {
    label = 'Comedy',
    brief = 'Light, playful, slightly exaggerated effects with crisp comedic timing; cartoon-adjacent is welcome when the scene is silly.',
    package = 'Typical package: accents timed to punchlines + light ambience; music sting only when the joke lands on it. Usually 3-5 candidates.',
  },
  scifi_fantasy = {
    label = 'Sci-fi / fantasy',
    brief = 'Designed, otherworldly textures: synthesized whooshes, magical shimmers, tech hums — consistent with a built world, not stock reality.',
    package = 'Typical package: world-building ambience layer(s) + designed one-shots for tech/magic events + optional tonal drone or underscore. Usually 5-8 candidates.',
  },
  documentary = {
    label = 'Documentary / nature',
    brief = 'Natural, realistic field-recording character. Authentic ambiences, honest perspective, no dramatization.',
    package = 'Typical package: 1-2 authentic ambiences + a few spot sounds actually present in the scene; music rarely, only as a neutral bed. Usually 2-4 candidates.',
  },
  audiobook = {
    label = 'Audiobook',
    brief = 'Subtle, supportive beds and sparse one-shots that never compete with narration; conservative density and dynamics.',
    package = 'Sparse package: at most a gentle bed + 1-2 discreet accents; silence is a valid choice. Usually 2-4 candidates.',
  },
  game = {
    label = 'Video game',
    brief = 'Punchy, instantly readable game audio: clear one-shots with fast transients, clean loopable ambience beds.',
    package = 'Typical package: loopable ambience bed(s) + punchy readable one-shots per event + optional music loop proposed as musical ambience. Usually 4-7 candidates.',
  },
  commercial = {
    label = 'Commercial / podcast',
    brief = 'Modern polished production sound: clean transitions, tasteful whooshes and accents with a branded, contemporary feel.',
    package = 'Typical package: opening theme + underscore bed + room tone + 1-2 tasteful accents + closing theme (the classic show package). Usually 4-6 candidates.',
  },
}

M.SCENE_PRESET_ORDER = {
  'film_drama', 'audio_drama', 'horror_thriller', 'comedy', 'scifi_fantasy',
  'documentary', 'audiobook', 'game', 'commercial',
}

-- T10 (user 2026-07-11): własne style usera — klucz 'custom:<Name>'
-- rozwiązuje się z ExtState (config.get_custom_styles 'sfx_scene');
-- nieznany klucz → film_drama (bezpieczny default, jak dotąd).
function M.resolve_scene_style(key)
  if type(key) == 'string' then
    local name = key:match('^custom:(.+)$')
    if name then
      local st = cfg.get_custom_styles('sfx_scene')[name]
      if st and type(st.brief) == 'string' and st.brief ~= '' then
        return {
          label   = name,
          brief   = st.brief,
          package = (type(st.package) == 'string' and st.package ~= '')
                      and st.package or nil,
        }
      end
    end
  end
  return M.SCENE_PRESETS[key] or M.SCENE_PRESETS.film_drama
end

----------------------------------------------------------------------------
-- LLM task: sound-designer brief → JSON candidates (llm.spawn_json).
-- openai_schema jawnie (strict wymaga required-all + additionalProperties
-- false REKURENCYJNIE — patrz adapter openai).
----------------------------------------------------------------------------
local CANDIDATE_PROPS = {
  prompt           = { type = 'string',  description = 'Generation prompt in English — written freely and evocatively. Optional levers when useful: for sound effects the source/material/space, audio terminology (impact, whoosh, ambience, one-shot, braam, drone, glitch, stem, foley), "X, then Y" sequences; for music the genre, mood, instrumentation, tempo ("90 BPM"), key ("in D minor") and song-structure words (intro, build, drop, outro). Never lyrics or speech.' },
  duration_seconds = { type = 'number',  description = 'Suggested length in seconds. Sound effects: 0.5-30. Music: 10-300 — think in REAL time: enough room for the piece to develop AND resolve with a natural ending/tail; ending too early is worse than running longer than the scene.' },
  starts_at_seconds = { type = 'number', description = 'When the sound should START, in seconds RELATIVE TO THE FRAGMENT START (only for placement="at"). Read it from the [t] time markers in the transcript — anchor the sound to the word where the event happens. Use 0 for beds that underlay the whole fragment.' },
  kind             = { type = 'string',  enum = { 'one_shot', 'ambience', 'music' }, description = 'one_shot = single non-musical event; ambience = background sound bed; music = ANY musical material (underscore bed, opening theme/jingle, outro theme, stinger with melody/harmony) — always the music engine.' },
  placement        = { type = 'string',  enum = { 'intro', 'at', 'outro' }, description = 'intro = opening theme/jingle placed BEFORE the fragment starts (show/podcast opener, cold-open sting); at = anchored inside the fragment at starts_at_seconds; outro = closing theme placed right AFTER the fragment ends.' },
  fills_scene      = { type = 'boolean', description = 'true when the piece/bed should underlay the WHOLE fragment — the engine will be asked for at least the fragment duration plus a natural tail (the result may be longer than the scene; that is intended).' },
  loop             = { type = 'boolean', description = 'true only for seamless ambience beds (the music engine cannot loop).' },
  why              = { type = 'string',  description = 'One short sentence: why this fits the scene.' },
}

M.TASK_SFX_BRIEF = {
  name        = 'emit_sfx_brief',
  description = 'Emit sound-effect and music-bed prompt candidates for the scene as a structured JSON object. ALWAYS call this tool — never reply with plain text.',
  schema = {
    type = 'object',
    properties = {
      candidates = {
        type        = 'array',
        maxItems    = 10,
        description = 'Sound-design candidates (best first): sound effects, ambience beds and up to three music pieces (opening theme, underscore bed, outro) when they serve the scene. Density follows the scene and the genre package guidance — from 2-3 for sparse formats up to 8-10 for a rich audio-drama scene.',
        items = {
          type       = 'object',
          properties = CANDIDATE_PROPS,
          required   = { 'prompt', 'duration_seconds', 'starts_at_seconds', 'kind' },
        },
      },
    },
    required = { 'candidates' },
  },
  openai_schema = {
    name   = 'sfx_brief',
    strict = true,
    schema = {
      type = 'object',
      properties = {
        candidates = {
          type  = 'array',
          items = {
            type       = 'object',
            properties = CANDIDATE_PROPS,
            required   = { 'prompt', 'duration_seconds', 'starts_at_seconds',
                           'kind', 'placement', 'fills_scene', 'loop', 'why' },
            additionalProperties = false,
          },
        },
      },
      required             = { 'candidates' },
      additionalProperties = false,
    },
  },
  deepseek_instruction = [[


OUTPUT FORMAT:
Return a single JSON object matching this exact schema (no markdown fence, no preamble, no commentary):
{
  "candidates": [
    { "prompt": "Heavy rain hitting a corrugated tin roof, steady ambience",
      "duration_seconds": 12.0, "starts_at_seconds": 0,
      "kind": "ambience", "placement": "at", "fills_scene": true,
      "loop": true,
      "why": "The narrator describes a downpour over their head." }
  ]
}

"kind" is "one_shot", "ambience" or "music". ANY musical material (underscore bed, opening theme/jingle, outro, melodic stinger) is kind="music". "placement": "intro" = opening theme BEFORE the fragment, "at" = inside the fragment at "starts_at_seconds" (read the [t] markers; 0 for full-fragment beds), "outro" = right after the fragment ends. "fills_scene": true when the piece should underlay the whole fragment (it will be generated at least fragment-length + tail; longer than the scene is fine). Up to THREE music candidates, one per placement (opening theme + underscore bed + outro = classic full package); never two beds under the same speech. 2 to 10 candidates forming a complete sound package for the genre — density follows the scene (sparse formats 2-4, rich audio-drama scenes 8-10), best first. Prompts in English.]],
}

----------------------------------------------------------------------------
-- LLM task: rephrase kandydata — JEDEN nowy opis w tym samym klimacie
-- (ten sam moment sceny, rodzaj i przeznaczenie; inna interpretacja
-- brzmieniowa). Poprzednie wersje promptu idą do LLM jako "already tried".
----------------------------------------------------------------------------
local REPHRASE_PROPS = {
  prompt           = { type = 'string', description = 'The NEW generation prompt in English — same scene moment, same kind and dramatic purpose as the original, but a clearly DIFFERENT sonic interpretation (different source, texture or angle). Never a paraphrase of a previous prompt.' },
  duration_seconds = { type = 'number', description = 'Suggested length in seconds for the new idea (omit to keep the current one).' },
}

M.TASK_SFX_REPHRASE = {
  name        = 'emit_sfx_rephrase',
  description = 'Emit ONE alternative prompt for the candidate as a structured JSON object. ALWAYS call this tool — never reply with plain text.',
  schema = {
    type       = 'object',
    properties = REPHRASE_PROPS,
    required   = { 'prompt' },
  },
  openai_schema = {
    name   = 'sfx_rephrase',
    strict = true,
    schema = {
      type                 = 'object',
      properties           = REPHRASE_PROPS,
      required             = { 'prompt', 'duration_seconds' },
      additionalProperties = false,
    },
  },
  deepseek_instruction = [[


OUTPUT FORMAT:
Return a single JSON object matching this exact schema (no markdown fence, no preamble, no commentary):
{ "prompt": "Heavy oak door slamming shut in a stone hallway, sharp impact with a long cold reverb tail",
  "duration_seconds": 4.0 }

"prompt" = ONE new English generation prompt — same scene moment and type as the original, different sonic interpretation. "duration_seconds" optional.]],
}

-- Pure (headless-tested): aplikuje wynik rephrase na kandydata. Prompt
-- replaced + stara wersja do history; pozycja/rodzaj/loop NIETKNIĘTE.
-- gen_count ZEROWANY — nowy opis nie był jeszcze generowany, znacznik
-- "generated ×N" dotyczył starego promptu.
function M.apply_rephrase(cand, data)
  if type(data) ~= 'table' or type(data.prompt) ~= 'string' or data.prompt == '' then
    return false, 'LLM response missing prompt'
  end
  cand.prompt_history = cand.prompt_history or {}
  table.insert(cand.prompt_history, cand.prompt)
  cand.prompt    = data.prompt
  cand.gen_count = nil
  local dur = tonumber(data.duration_seconds)
  if dur then
    local lo = (cand.kind == 'music') and M.MUSIC_DUR_MIN or M.DUR_MIN
    local hi = (cand.kind == 'music') and M.MUSIC_DUR_MAX or M.DUR_MAX
    cand.duration_seconds = math.max(lo, math.min(hi, dur))
  end
  return true
end

----------------------------------------------------------------------------
-- init_state — defensive per-field merge (per memory init_state idempotent).
----------------------------------------------------------------------------
----------------------------------------------------------------------------
-- T5b (UX-POLISH 2026-07-11): persystencja panelu — ProjExtState
-- 'sfx_state' (mirror tts_state; audyt: stan był in-memory only — kandydaci
-- sceny i grupy wyników ginęły przy zamknięciu). Serializujemy DANE
-- (prompty, ustawienia, kandydaci sceny, grupy wyników ze ścieżkami mp3 w
-- reasonate_tmp + liczniki sekwencji); transient (handles/spinnery/status)
-- — nie. Dirty-detect: panel mutuje stan BEZPOŚREDNIO (bez mode API), więc
-- zamiast mark_dirty w gui liczymy tani fingerprint w consume_signals;
-- zmiana → debounce 500 ms → flush. Restore: take'i z brakującym plikiem
-- tmp są dropowane (nie da się ich zagrać ani wstawić) + status 1×.
----------------------------------------------------------------------------
local json = require 'modules.lib.json'

local PROJ_KEY_SFX_STATE = 'sfx_state'

local function mark_dirty(s)
  s._dirty    = true
  s._dirty_at = util.now()
end

-- Kandydat sceny bez pól transient (rephrase_handle itp.) i nie-JSON-owych.
local function clean_candidate(cand)
  local out = {}
  for k, v in pairs(cand) do
    local tv = type(v)
    if tv ~= 'function' and tv ~= 'userdata'
       and not tostring(k):find('handle', 1, true) then
      out[k] = v
    end
  end
  return out
end

local function serialize_state(s)
  local cands = {}
  for _, c in ipairs(s.scene_candidates or {}) do
    cands[#cands + 1] = clean_candidate(c)
  end
  local groups = {}
  for _, g in ipairs(s.result_groups or {}) do
    local takes = {}
    for _, t in ipairs(g.takes or {}) do
      takes[#takes + 1] = { id = t.id, path = t.path,
                            from_cache = t.from_cache or false }
    end
    groups[#groups + 1] = {
      id = g.id, prompt = g.prompt, kind = g.kind, loop = g.loop or false,
      scene_pos = g.scene_pos, scene_offset = g.scene_offset,
      place = g.place, scene_start = g.scene_start, scene_len = g.scene_len,
      cand_index = g.cand_index,
      anchor_guid = g.anchor_guid, anchor_pos = g.anchor_pos,
      from = g.from, open = g.open or false, takes = takes,
    }
  end
  return json.encode({
    sub_mode = s.sub_mode, gen_kind = s.gen_kind,
    text_buffer = s.text_buffer or '',
    duration_auto = s.duration_auto, duration_seconds = s.duration_seconds,
    prompt_influence = s.prompt_influence, loop = s.loop,
    variant_count = s.variant_count,
    music_text_buffer = s.music_text_buffer or '',
    music_duration_auto = s.music_duration_auto,
    music_duration_seconds = s.music_duration_seconds,
    music_instrumental = s.music_instrumental,
    scene_music_model = s.scene_music_model,
    scene_preset = s.scene_preset, scene_detail = s.scene_detail or '',
    scene_frag = s.scene_frag,
    scene_candidates = cands, result_groups = groups,
    variant_seq = s.variant_seq or 0, result_seq = s.result_seq or 0,
    group_seq = s.group_seq or 0,
  })
end

local function save_state_to_proj(s, proj)
  local ok, payload = pcall(serialize_state, s)
  if not ok or type(payload) ~= 'string' then return end
  reaper.SetProjExtState(proj or 0, 'Reasonate', PROJ_KEY_SFX_STATE, payload)
end

local function load_state_from_proj(s, proj)
  local rv, payload = reaper.GetProjExtState(proj or 0, 'Reasonate', PROJ_KEY_SFX_STATE)
  if rv ~= 1 or payload == nil or payload == '' then return false end
  local ok, d = pcall(json.decode, payload)
  if not ok or type(d) ~= 'table' then return false end
  if d.sub_mode == 'describe' or d.sub_mode == 'scene' then s.sub_mode = d.sub_mode end
  if d.gen_kind == 'sfx' or d.gen_kind == 'music' then s.gen_kind = d.gen_kind end
  if type(d.text_buffer) == 'string'        then s.text_buffer = d.text_buffer end
  if type(d.duration_auto) == 'boolean'     then s.duration_auto = d.duration_auto end
  if type(d.duration_seconds) == 'number'   then s.duration_seconds = d.duration_seconds end
  if type(d.prompt_influence) == 'number'   then s.prompt_influence = d.prompt_influence end
  if type(d.loop) == 'boolean'              then s.loop = d.loop end
  if type(d.variant_count) == 'number'      then s.variant_count = d.variant_count end
  if type(d.music_text_buffer) == 'string'  then s.music_text_buffer = d.music_text_buffer end
  if type(d.music_duration_auto) == 'boolean' then s.music_duration_auto = d.music_duration_auto end
  if type(d.music_duration_seconds) == 'number' then s.music_duration_seconds = d.music_duration_seconds end
  if type(d.music_instrumental) == 'boolean' then s.music_instrumental = d.music_instrumental end
  if type(d.scene_music_model) == 'string'  then s.scene_music_model = d.scene_music_model end
  if type(d.scene_preset) == 'string'       then s.scene_preset = d.scene_preset end
  if type(d.scene_detail) == 'string'       then s.scene_detail = d.scene_detail end
  if type(d.scene_frag) == 'table' and type(d.scene_frag.pos) == 'number'
     and type(d.scene_frag.len) == 'number' then
    s.scene_frag = d.scene_frag
  end
  if type(d.scene_candidates) == 'table' then
    local out = {}
    for _, c in ipairs(d.scene_candidates) do
      if type(c) == 'table' and type(c.prompt) == 'string' and c.prompt ~= '' then
        out[#out + 1] = c
      end
    end
    s.scene_candidates = out
    -- Kandydaci przeżyli restart → widok From scene wraca do 'ready'
    -- (transkrypcja/LLM nie muszą lecieć drugi raz).
    if #out > 0 and s.scene_frag then s.scene_phase = 'ready' end
  end
  if type(d.result_groups) == 'table' then
    local groups, dropped = {}, 0
    for _, g in ipairs(d.result_groups) do
      if type(g) == 'table' and type(g.takes) == 'table' then
        local takes = {}
        for _, t in ipairs(g.takes) do
          if type(t) == 'table' and type(t.path) == 'string'
             and util.file_exists(t.path) then
            takes[#takes + 1] = t
          else
            dropped = dropped + 1
          end
        end
        if #takes > 0 then
          g.takes = takes
          groups[#groups + 1] = g
        end
      end
    end
    s.result_groups = groups
    if dropped > 0 then
      s.status_text  = ('%d generated take(s) were cleaned from the tmp cache — regenerate if needed.')
        :format(dropped)
      s.status_color = theme.COLORS.status_stale
    end
  end
  if type(d.variant_seq) == 'number' then s.variant_seq = d.variant_seq end
  if type(d.result_seq) == 'number'  then s.result_seq = d.result_seq end
  if type(d.group_seq) == 'number'   then s.group_seq = d.group_seq end
  return true
end

-- Tani fingerprint durable stanu (per frame w consume_signals) — DJB2 po
-- buforach + skalary + kształt grup/kandydatów. Zmiana → mark_dirty.
local function state_fingerprint(s)
  local parts = {
    s.sub_mode, s.gen_kind,
    util.simple_hash(s.text_buffer or ''),
    util.simple_hash(s.music_text_buffer or ''),
    util.simple_hash(s.scene_detail or ''),
    tostring(s.duration_auto), s.duration_seconds, s.prompt_influence,
    tostring(s.loop), s.variant_count,
    tostring(s.music_duration_auto), s.music_duration_seconds,
    tostring(s.music_instrumental), s.scene_music_model, s.scene_preset,
    #(s.scene_candidates or {}), #(s.result_groups or {}),
  }
  local cand_seed, open_seed, take_n = {}, 0, 0
  for _, c in ipairs(s.scene_candidates or {}) do
    cand_seed[#cand_seed + 1] = (c.prompt or '') .. '|' .. tostring(c.starts_at)
      .. '|' .. tostring(c.duration) .. '|' .. tostring(c.gen_count)
      .. '|' .. tostring(c.music_model) .. '|' .. tostring(c.loop)
      .. '|' .. tostring(c.placement) .. '|' .. tostring(c.fills_scene)
      .. '|' .. tostring(c.open)
  end
  for _, g in ipairs(s.result_groups or {}) do
    take_n = take_n + #(g.takes or {})
    if g.open then open_seed = open_seed + g.id end
    open_seed = open_seed + (g.cand_index or 0) * 131
  end
  parts[#parts + 1] = util.simple_hash(table.concat(cand_seed, '\1'))
  parts[#parts + 1] = take_n
  parts[#parts + 1] = open_seed
  return table.concat(parts, '|')
end

local function init_state(state)
  state.modes.sfx = state.modes.sfx or {}
  local s = state.modes.sfx
  -- T5b: project-switch detection (mirror modes/tts init_state) — flush
  -- dirty do STAREGO projektu, reset + load z nowego.
  local current_proj = reaper.EnumProjects(-1)
  if s._initialized and s._loaded_proj ~= current_proj then
    if s._dirty and s._loaded_proj then
      pcall(save_state_to_proj, s, s._loaded_proj)
    end
    -- Twardy reset durable pól (nil-guardy niżej wypełnią defaulty) +
    -- transient (handles należą do starego projektu).
    for k in pairs(s) do s[k] = nil end
  end
  if s.sub_mode         == nil then s.sub_mode         = 'describe' end
  -- Describe — sound effect
  if s.gen_kind         == nil then s.gen_kind         = 'sfx' end  -- 'sfx'|'music'
  if s.text_buffer      == nil then s.text_buffer      = '' end
  if s.duration_auto    == nil then s.duration_auto    = true end
  if s.duration_seconds == nil then s.duration_seconds = 5.0 end
  if s.prompt_influence == nil then s.prompt_influence = 0.3 end
  if s.loop             == nil then s.loop             = false end
  if s.variant_count    == nil then s.variant_count    = cfg.get_sfx_variant_count() end
  -- Describe — music (NS-MUSIC; osobny bufor, żeby toggle nie kasował promptów)
  if s.music_text_buffer      == nil then s.music_text_buffer      = '' end
  if s.music_duration_auto    == nil then s.music_duration_auto    = false end
  if s.music_duration_seconds == nil then s.music_duration_seconds = 60 end
  if s.music_instrumental     == nil then s.music_instrumental     = true end
  -- User 2026-07-11: model muzyki dla From scene — własne pole (Describe
  -- NIE steruje sceną); default v2.
  if s.scene_music_model      == nil then s.scene_music_model      = 'music_v2' end
  -- Generation + results (grupy per klik Generate, najnowsza pierwsza)
  if s.gen_entries      == nil then s.gen_entries      = {} end   -- {{h, group_id, ...}}
  if s.result_groups    == nil then s.result_groups    = {} end
  if s.variant_seq      == nil then s.variant_seq      = 0 end
  if s.result_seq       == nil then s.result_seq       = 0 end
  if s.group_seq        == nil then s.group_seq        = 0 end
  -- Scene
  if s.scene_phase      == nil then s.scene_phase      = 'idle' end  -- idle|transcribing|analyzing|ready
  if s.scene_preset     == nil then s.scene_preset     = 'film_drama' end
  if s.scene_detail     == nil then s.scene_detail     = '' end
  if s.scene_candidates == nil then s.scene_candidates = {} end
  -- Status line
  if s.status_text      == nil then s.status_text      = '' end
  if s.status_color     == nil then s.status_color     = theme.COLORS.text_dim end
  -- T5b: load raz per (sesja, projekt); _last_fp od razu po load — inaczej
  -- pierwszy frame widziałby "zmianę" i brudził świeżo otwarty projekt.
  if not s._initialized then
    load_state_from_proj(s, current_proj)
    s._loaded_proj = current_proj
    s._dirty       = false
    s._dirty_at    = 0
    s._last_fp     = state_fingerprint(s)
    s._initialized = true
  end
  return s
end

local function set_status(s, msg, color)
  s.status_text  = msg or ''
  s.status_color = color or theme.COLORS.text_dim
end

----------------------------------------------------------------------------
-- Retry-429 (mirror modes/tts schedule_retry — respawn z _spawn_opts).
----------------------------------------------------------------------------
local function is_rate_limit_error(err)
  if not err then return false end
  local lower = tostring(err):lower()
  return (lower:find('429', 1, true) ~= nil)
      or (lower:find('rate limit', 1, true) ~= nil)
      or (lower:find('rate_limit', 1, true) ~= nil)
      or (lower:find('too many', 1, true) ~= nil)
end

local function schedule_retry(handle)
  if not is_rate_limit_error(handle.error) then return false end
  if not handle._spawn_opts then return false end
  local next_count = (handle._retry_count or 0) + 1
  if next_count > MAX_RETRIES then return false end
  handle._retry_at    = util.now() + (RETRY_BACKOFF[next_count] or 4)
  handle._retry_count = next_count
  return true
end

----------------------------------------------------------------------------
-- Candidates validation (pure — headless-tested w tests/run.lua).
----------------------------------------------------------------------------
-- T9 (UX-POLISH): ogon dodawany do fills_scene — utwór ma wypełnić scenę
-- i wybrzmieć, nie uciąć się na jej krawędzi (user 2026-07-11).
M.FILL_SCENE_TAIL_SECS = 8

function M.validate_sfx_candidates(data, max_offset)
  if type(data) ~= 'table' or type(data.candidates) ~= 'table' then
    return nil, 'LLM response missing candidates[]'
  end
  -- max_offset = długość fragmentu sceny (clamp kotwic ORAZ baza fills_scene).
  local out, music_by_place = {}, {}
  for _, c in ipairs(data.candidates) do
    if type(c) == 'table' and type(c.prompt) == 'string' and c.prompt ~= '' then
      local kind = (c.kind == 'ambience' or c.kind == 'music') and c.kind or 'one_shot'
      local place = (c.placement == 'intro' or c.placement == 'outro')
        and c.placement or 'at'
      -- T9: max 2 kandydatów muzycznych, każdy w INNYM placemencie (np.
      -- czołówka + podkład); drugi bed pod tą samą mową = drop.
      if kind == 'music' then
        if music_by_place[place] then kind = nil else music_by_place[place] = true end
      end
      if kind then
        local at = math.max(0, tonumber(c.starts_at_seconds) or 0)
        if max_offset then at = math.min(at, max_offset) end
        local dur_lo = (kind == 'music') and M.MUSIC_DUR_MIN or M.DUR_MIN
        local dur_hi = (kind == 'music') and M.MUSIC_DUR_MAX or M.DUR_MAX
        local dur = math.max(dur_lo, math.min(dur_hi, tonumber(c.duration_seconds) or 4.0))
        -- T9: fills_scene = utwór MUSI fizycznie wypełnić fragment + ogon
        -- (dłuższy niż scena jest OK — lepszy niż urwany). Tylko muzyka:
        -- ambience wypełnia scenę pętlą (loop=true → B_LOOPSRC), cap 30 s
        -- zostaje.
        local fills = (c.fills_scene == true)
        if fills and kind == 'music' and max_offset then
          dur = math.max(dur, math.min(dur_hi, max_offset + M.FILL_SCENE_TAIL_SECS))
        end
        out[#out + 1] = {
          prompt           = c.prompt,
          duration_seconds = dur,
          starts_at        = (place == 'at') and at or 0,
          placement        = place,
          fills_scene      = fills,
          kind             = kind,
          loop             = (c.loop == true) and kind == 'ambience',
          instrumental     = kind == 'music' or nil,  -- scene beds: zawsze bez wokalu
          why              = type(c.why) == 'string' and c.why or '',
        }
      end
      if #out >= M.MAX_CANDIDATES then break end
    end
  end
  if #out == 0 then return nil, 'no valid candidates in LLM response' end
  return out
end

----------------------------------------------------------------------------
-- Scene fragment detection: selected item + opcjonalna time selection.
-- Zwraca frag = { item, item_guid, pos, len, src_lo, src_hi, label } | nil, err.
-- src_lo/hi = SOURCE time (do filtra słów transkryptu — words są source-time).
----------------------------------------------------------------------------
function M.detect_scene_fragment()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then return nil, 'Select a source audio item first.' end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    return nil, 'Selected item has no audio take.'
  end
  local item_pos  = reaper.GetMediaItemInfo_Value(item, 'D_POSITION') or 0
  local item_len  = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
  local item_offs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
  local playrate  = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1
  if playrate <= 0 then playrate = 1 end

  local frag_pos, frag_len = item_pos, item_len
  local ts_a, ts_b = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if ts_b > ts_a then
    local lo = math.max(ts_a, item_pos)
    local hi = math.min(ts_b, item_pos + item_len)
    if hi > lo then
      frag_pos, frag_len = lo, hi - lo
    end
  end

  return {
    item      = item,
    -- item_guid USUNIĘTE M7 (2026-07-11, user OK) — nikt nie czytał.
    pos       = frag_pos,
    len       = frag_len,
    src_lo    = item_offs + (frag_pos - item_pos) * playrate,
    src_hi    = item_offs + (frag_pos - item_pos + frag_len) * playrate,
    playrate  = playrate,
  }, nil
end

----------------------------------------------------------------------------
-- LLM prompts (scene → sound-designer brief).
----------------------------------------------------------------------------
local function build_scene_system_prompt(preset_key)
  local p = M.resolve_scene_style(preset_key)   -- T10: stock + custom
  return ([[You are a senior sound designer and music supervisor for film, games and audio drama.
You receive the transcript of a scene fragment (narration or dialogue) with inline [t] time markers (seconds from the fragment start), plus the fragment duration. Propose candidates (best first) that together form a COMPLETE sound package for the scene — opening theme, underscore bed, room tone/ambience layers, moment accents (one-shots) and a closing theme are ALL fair game in one analysis. DENSITY FOLLOWS THE SCENE AND THE GENRE: count the distinct sound-worthy events in the transcript and weigh the fragment length — a sparse format deserves restraint (2-4 candidates), a busy audio-drama scene can justify 8-10 (cap 10). Never pad with filler; every candidate must earn its place. Skip a category only when it genuinely does not serve the scene.

STYLE BRIEF: %s

PACKAGE GUIDANCE FOR THIS GENRE: %s

RULES:
1. Prompts in ENGLISH. You have FULL creative freedom in how you write them — vivid, evocative, surprising descriptions are welcome. Optional levers the generator responds well to, when they serve the idea (not a template): naming the source/material/space, audio terminology (impact, whoosh, ambience, one-shot, braam, drone, foley), "X, then Y" sequences for two-stage events.
2. kind=one_shot for single events (typically 0.5-4 s). kind=ambience for background sound beds — these may span the whole fragment (cap 30 s) and should set loop=true when a seamless bed makes sense. Ambience may also be MUSICAL when the scene calls for it (atmospheric synth pad, tonal drone, rhythmic loop with a BPM) — the sound engine handles musical material and loops it seamlessly.
3. kind=music is ANY musical material — underscore beds, but also opening themes / show jingles / podcast intros, outro themes and melodic stingers. These ALWAYS go to the music engine (never one_shot). Instrumental only — never lyrics or vocals. Genre, mood, instrumentation, tempo ("90 BPM"), key ("in D minor") and song-structure words (intro, build, outro) are reliable levers when you want control, but free evocative description works too. Up to THREE music candidates, one per placement (opening theme + underscore bed + outro is a classic full package) — never two beds under the same speech. Music CANNOT loop — when the scene needs a short repeating musical bed, propose it as a musical kind=ambience with loop=true instead.
4. placement: "intro" for opening themes/jingles/cold-open stings — they are placed BEFORE the fragment starts (classic show opener; the listener hears them before any speech). "outro" for closing themes — placed right AFTER the fragment ends. "at" for everything anchored inside the scene. For intro/outro the starts_at_seconds value is ignored.
5. starts_at_seconds (placement="at" only): anchor each sound to the MOMENT its event happens — read the [t] markers around the word that mentions it. Beds that underlay the whole fragment start at 0 and set fills_scene=true. The sound may start slightly before the word (~0.2-0.5 s) when it should feel anticipatory.
6. THINK IN REAL TIME. The fragment duration is given — a bed with fills_scene=true must physically last the whole fragment (it will be generated at least that long; LONGER than the scene is fine and often better). Music needs room to DEVELOP and to RESOLVE: write an ending into the prompt (outro, decay, ring-out) and budget ~10-20%% extra tail beyond the moment it covers — a piece that stops abruptly mid-phrase is a failure. Long scene = long piece.
7. If USER DETAILS are provided, they OVERRIDE anything implied by the transcript (the user knows the scene better than the text).
8. Never include speech, dialogue, or songs with lyrics in prompts.
9. Each candidate must be a DIFFERENT interpretation of the scene, not a rephrasing of the same sound.]]):format(
    p.brief,
    p.package or 'Use professional judgement for this format.')
end

local function build_scene_user_prompt(frag_len, transcript_text, detail)
  local lines = {
    ('SCENE TRANSCRIPT with [t] time markers (fragment lasts %.1f seconds):'):format(frag_len or 0),
    '"' .. (transcript_text or '') .. '"',
  }
  if detail and detail ~= '' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'USER DETAILS (override transcript): ' .. detail
  end
  return table.concat(lines, '\n')
end

local function build_rephrase_system_prompt(preset_key, kind)
  local p = M.resolve_scene_style(preset_key)   -- T10: stock + custom
  -- Guide = paleta opcjonalnych dźwigni + twarde limity, NIE szablon.
  -- Pierwsza wersja (nakazowa: "tylko to co słychać", "1-2 zdania") robiła
  -- hermetyczne, gorsze propozycje (user feedback 2026-06-10); oficjalny
  -- music guide sam ostrzega, że proste sugestywne hasła często biją
  -- elaboraty. Kreatywność explicit zaproszona, dźwignie "when useful".
  local kind_rule = (kind == 'music')
    and [[The candidate is an instrumental MUSIC bed. You have FULL creative freedom in how you write the prompt — vivid, evocative, surprising language is welcome, and simple suggestive descriptions often beat elaborate ones. Optional levers the generator responds well to, when you want control: genre, mood, instrumentation, tempo ("90 BPM"), key ("in D minor"), song-structure words (intro, build, drop, outro). Hard limit: instrumental only — no lyrics or vocals (it plays under speech).]]
    or  [[The candidate is a SOUND EFFECT. You have FULL creative freedom in how you write the prompt — vivid, evocative descriptions are welcome. Optional levers the generator responds well to, when they serve the idea: naming the source/material/space, audio terminology (impact, whoosh, ambience, braam, glitch, drone, foley), "X, then Y" sequences for two-stage events. Hard limit: no speech, dialogue or songs with lyrics.]]
  return ([[You are a senior sound designer for film, games and audio drama.
You receive a scene fragment transcript, one EXISTING generation prompt for a specific moment of that scene, and a list of prompts already tried. Propose ONE alternative prompt for the SAME moment with the SAME dramatic purpose — but a clearly different sonic interpretation (different source, texture or angle). Do NOT repeat or paraphrase the existing prompt nor anything from the list.

STYLE BRIEF: %s

%s]]):format(p.brief, kind_rule)
end

local function build_rephrase_user_prompt(s, cand)
  local lines = {
    ('SCENE TRANSCRIPT (fragment lasts %.1f seconds):'):format(s.scene_frag and s.scene_frag.len or 0),
    '"' .. (s.scene_transcript_text or '') .. '"',
    '',
    -- T9: placement niesie intencję (czołówka ≠ moment w scenie) — rephrase
    -- musi zostać w tej samej roli.
    (cand.placement == 'intro'
       and 'MOMENT: opening theme played BEFORE the fragment starts.%s'
     or cand.placement == 'outro'
       and 'MOMENT: closing theme played right AFTER the fragment ends.%s'
     or ('MOMENT: starts at +%.1f s into the fragment.%%s'):format(cand.starts_at or 0))
      :format(cand.why ~= '' and (' Purpose: ' .. cand.why) or ''),
    'CURRENT PROMPT: "' .. cand.prompt .. '"',
  }
  if cand.prompt_history and #cand.prompt_history > 0 then
    lines[#lines + 1] = 'ALREADY TRIED (do not repeat): "'
      .. table.concat(cand.prompt_history, '" · "') .. '"'
  end
  if s.scene_detail and s.scene_detail ~= '' then
    lines[#lines + 1] = 'USER DETAILS (override transcript): ' .. s.scene_detail
  end
  return table.concat(lines, '\n')
end

----------------------------------------------------------------------------
-- Output tracki (SFX / Music) + insert (Undo block; niezmiennik #4).
-- Osobny track "Music" (user decision 2026-06-10): długie podkłady nie
-- mieszają się z efektami, całość ścisza się jednym faderem.
----------------------------------------------------------------------------
local TRACK_DEFS = {
  sfx   = { flag = 'is_sfx_track',   name = 'SFX',   rgba = nil },  -- rgba nil = MODE_ACCENTS.sfx
  music = { flag = 'is_music_track', name = 'Music', rgba = M.KIND_COLORS.music },
}

local function track_rgba(def)
  return def.rgba or theme.MODE_ACCENTS.sfx
end

local function get_or_create_output_track(kind)
  local def = TRACK_DEFS[kind] or TRACK_DEFS.sfx
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if helpers.pext_track_get(tr, def.flag) == '1' then return tr, def end
  end
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', def.name, true)
  helpers.pext_track_set(tr, def.flag, '1')
  local r, g, b = colors.rgba_to_rgb(track_rgba(def))
  reaper.SetTrackColor(tr, colors.rgb_to_native(r, g, b))
  return tr, def
end

local function insert_result(s, res, pos)
  if not res or not res.path or not util.file_exists(res.path) then
    set_status(s, 'Audio file missing — generate again.', theme.COLORS.status_error)
    return
  end
  local src = reaper.PCM_Source_CreateFromFile(res.path)
  if not src then
    set_status(s, 'Cannot read generated audio file.', theme.COLORS.status_error)
    return
  end
  local len = reaper.GetMediaSourceLength(src) or 0
  if reaper.PCM_Source_BuildPeaks then reaper.PCM_Source_BuildPeaks(src, 0) end

  -- T9 (UX-POLISH): placement — czołówka (intro) kończy się tam, gdzie
  -- zaczyna się fragment (klasyczny opener przed materiałem); outro zaczyna
  -- się na końcu fragmentu. Liczone z REALNEJ długości renderu.
  if res.place == 'intro' and res.scene_start then
    pos = math.max(0, res.scene_start - len)
  elseif res.place == 'outro' and res.scene_start then
    pos = res.scene_start + (res.scene_len or 0)
  end

  local is_music = res.kind == 'music'

  -- T9f (user-caught "nie wypełnił sceny"): zapętlony ambient wstawiony
  -- "at scene" rozciąga się do KOŃCA sceny (B_LOOPSRC zapętla źródło) —
  -- 30-sekundowy loop kryje i 5-minutową scenę. Intro/outro i muzyka
  -- (nie loopuje) zachowują naturalną długość renderu.
  local item_len = len
  if res.loop and not is_music and res.fill_to_scene_end
     and res.place ~= 'intro' and res.place ~= 'outro'
     and res.scene_start and res.scene_len then
    local fill = (res.scene_start + res.scene_len) - pos
    if fill > 0.5 then item_len = fill end
  end

  reaper.Undo_BeginBlock()
  local tr, def = get_or_create_output_track(is_music and 'music' or 'sfx')
  local item = reaper.AddMediaItemToTrack(tr)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', 0)
  reaper.SetMediaItemInfo_Value(item, 'D_POSITION', pos)
  reaper.SetMediaItemInfo_Value(item, 'D_LENGTH', item_len)
  -- Loopowalne tła SFX/ambience: B_LOOPSRC → user przeciąga prawą krawędź
  -- żeby wydłużyć bed (API generuje seamless loop). Muzyka nie loopuje
  -- (engine bez parametru loop; user loopuje ręcznie w REAPER gdy chce).
  if res.loop and not is_music then reaper.SetMediaItemInfo_Value(item, 'B_LOOPSRC', 1) end
  local name = res.prompt
  if #name > 60 then name = name:sub(1, 57) .. '...' end
  local prefix = is_music and 'Music: ' or 'SFX: '
  reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', prefix .. name, true)
  if is_music then
    helpers.pext_item_set(item, 'is_music_output', '1')
    helpers.pext_item_set(item, 'music_prompt', res.prompt)
    helpers.pext_item_set(item, 'music_generated_at', tostring(os.time()))
  else
    helpers.pext_item_set(item, 'is_sfx_output', '1')
    helpers.pext_item_set(item, 'sfx_prompt', res.prompt)
    helpers.pext_item_set(item, 'sfx_loop', res.loop and '1' or '')
    helpers.pext_item_set(item, 'sfx_generated_at', tostring(os.time()))
  end
  local r, g, b = colors.rgba_to_rgb(track_rgba(def))
  reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', colors.rgb_to_native(r, g, b) | 0x1000000)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(is_music and 'Reasonate: insert music bed' or 'Reasonate: insert sound effect', -1)
  set_status(s, ('Inserted "%s" at %.2fs on %s track.'):format(name, pos, def.name),
    theme.COLORS.status_done)
end

----------------------------------------------------------------------------
-- Generation batch (Describe i scene-candidate używają tej samej ścieżki).
-- req = { prompt, kind ('sfx'|'music'), duration (nil=auto), influence,
--         loop, instrumental, count, scene_pos?, scene_offset? }
-- Każdy klik Generate = jedna zwijana GRUPA wyników (user decision
-- 2026-06-10: "żeby playerów nie było milion"); take'y dolatują do grupy.
----------------------------------------------------------------------------
local function new_result_group(s, req)
  s.group_seq = s.group_seq + 1
  for _, g in ipairs(s.result_groups) do g.open = false end
  local group = {
    id           = s.group_seq,
    prompt       = req.prompt,
    kind         = req.kind or 'sfx',
    loop         = req.loop or false,
    scene_pos    = req.scene_pos,
    scene_offset = req.scene_offset,
    -- T9: placement intro/at/outro + geometria sceny (pozycja intro/outro
    -- liczona przy insercie z REALNEJ długości renderu).
    place        = req.place,
    scene_start  = req.scene_start,
    scene_len    = req.scene_len,
    -- T9e: link do kandydata sceny — take'y renderują się INLINE w jego
    -- wierszu tabeli pomysłów; nil = Describe / sierota po re-Analyze
    -- (dolna sekcja "Generated sounds").
    cand_index   = req.cand_index,
    -- T9f: kotwica do żywego itemu — insert liczy deltę bieżącej pozycji
    -- itemu vs pozycja z momentu Analyze (item przesunięty ≠ insert w polu).
    anchor_guid  = req.anchor_guid,
    anchor_pos   = req.anchor_pos,
    from         = req.scene_pos and 'scene' or 'describe',
    takes        = {},
    open         = true,
  }
  table.insert(s.result_groups, 1, group)
  return group
end

local function start_generation(s, req)
  local is_music = req.kind == 'music'
  local group = new_result_group(s, req)
  local spawned = 0
  for n = 1, math.max(1, req.count or 1) do
    local opts, h
    if is_music then
      opts = {
        text             = req.prompt,
        duration_seconds = req.duration,
        instrumental     = req.instrumental ~= false,
        variant_n        = s.variant_seq + n,
        output_format    = 'mp3_44100_128',
        -- 2026-07-11: music_v2 dostępny w API (user-caught). Priorytet:
        -- model wybrany PRZY kandydACIE From scene (req.music_model — user:
        -- scena ma własne ustawienia, Describe NIE steruje sceną), fallback
        -- = selektor sekcji Describe→Music. Respawn dziedziczy _spawn_opts.
        model_id         = req.music_model or cfg.get_music_model(),
      }
      h = voice_admin.spawn_music(opts)
    else
      opts = {
        text             = req.prompt,
        duration_seconds = req.duration,
        prompt_influence = req.influence,
        loop             = req.loop or false,
        variant_n        = s.variant_seq + n,
        output_format    = 'mp3_44100_128',
      }
      h = voice_admin.spawn_sfx(opts)
    end
    h._spawn_opts  = opts
    h._retry_count = h._retry_count or 0
    if h.status == 'error' then
      set_status(s, (is_music and 'Music: ' or 'SFX: ') .. tostring(h.error),
        theme.COLORS.status_error)
    else
      table.insert(s.gen_entries, { h = h, group_id = group.id, kind = group.kind })
      spawned = spawned + 1
    end
  end
  s.variant_seq = s.variant_seq + math.max(1, req.count or 1)
  if spawned > 0 then
    set_status(s, ('Generating %d %s…'):format(spawned,
      is_music and (spawned == 1 and 'music take' or 'music takes')
               or (spawned == 1 and 'sound' or 'sounds')),
      theme.COLORS.text_dim)
  end
end

local function find_group(s, group_id)
  for _, g in ipairs(s.result_groups) do
    if g.id == group_id then return g end
  end
end

local function count_takes(s)
  local n = 0
  for _, g in ipairs(s.result_groups) do n = n + #g.takes end
  return n
end

-- Grupa bez take'ów po końcu batcha = wszystkie spawny error/cancel —
-- zostałby pusty wiersz-wdowa na liście.
local function prune_empty_groups(s)
  local keep = {}
  for _, g in ipairs(s.result_groups) do
    if #g.takes > 0 then keep[#keep + 1] = g end
  end
  s.result_groups = keep
end

local function finalize_entry(s, entry)
  local group = find_group(s, entry.group_id)
  if not group then return end   -- grupa usunięta w trakcie generacji — drop
  s.result_seq = s.result_seq + 1
  table.insert(group.takes, {
    id         = s.result_seq,
    path       = entry.h.result,
    from_cache = entry.h.from_cache or false,
  })
  -- T9e: świeży take → auto-rozwiń wiersz kandydata w tabeli pomysłów
  -- (dźwięk pojawia się PRZY pomyśle — user od razu widzi ▶).
  if group.cand_index and s.scene_candidates[group.cand_index] then
    s.scene_candidates[group.cand_index].open = true
  end
end

----------------------------------------------------------------------------
-- Polling pumps (wołane z consume_signals).
----------------------------------------------------------------------------
local function poll_generation(s)
  if #s.gen_entries == 0 then return end
  local still = {}
  for _, entry in ipairs(s.gen_entries) do
    local h = entry.h
    -- Pending retry-429: respawn po backoffie (spawn per rodzaj generacji).
    if h._retry_at and util.now() >= h._retry_at then
      local respawn = (entry.kind == 'music') and voice_admin.spawn_music or voice_admin.spawn_sfx
      local nh = respawn(h._spawn_opts)
      nh._spawn_opts  = h._spawn_opts
      nh._retry_count = h._retry_count
      entry.h = nh
      h = nh
    end
    if h.status == 'running' then
      voice_admin.poll(h)
      async_op.force_error_if_stale(h, 'SFX/Music generation')
    end
    if h.status == 'done' then
      finalize_entry(s, entry)
    elseif h.status == 'error' and not h._retry_at then
      if schedule_retry(h) then
        set_status(s, ('Rate limited — retrying (%d/%d)…'):format(h._retry_count, MAX_RETRIES),
          theme.COLORS.status_stale)
        table.insert(still, entry)
      else
        set_status(s, 'SFX: ' .. tostring(h.error), theme.COLORS.status_error)
      end
    elseif h.status ~= 'done' then
      table.insert(still, entry)
    end
  end
  s.gen_entries = still
  if #still == 0 then
    prune_empty_groups(s)
    if s.status_text:find('Generating', 1, true) then
      local n = count_takes(s)
      set_status(s, ('Done — %d take%s ready below.'):format(n, n == 1 and '' or 's'),
        theme.COLORS.status_done)
    end
  end
end

local function poll_scene_pipeline(s)
  -- Step 1: STT
  if s.scene_stt_handle then
    local h = s.scene_stt_handle
    stt.poll_transcribe(h)
    async_op.force_error_if_stale(h, 'Scene STT')
    if h.status == 'done' then
      s.scene_stt_handle = nil
      local tr = h.transcript
      local frag = s.scene_frag
      if not tr or type(tr.words) ~= 'table' or not frag then
        s.scene_phase = 'idle'
        set_status(s, 'Transcription returned no words.', theme.COLORS.status_error)
        return
      end
      -- collect_visible_words zwraca {display, raw_idx, word} — tekst w .word.text.
      -- Co ~5 słów wstawiamy znacznik [t] (sekundy od początku fragmentu;
      -- word.start jest source-time → /playrate na sekundy timeline) — LLM
      -- kotwiczy starts_at_seconds do słowa, przy którym dzieje się zdarzenie.
      local entries = transcript.collect_visible_words(tr, { lo = frag.src_lo, hi = frag.src_hi })
      local parts, n_words = {}, 0
      local rate = frag.playrate or 1
      for _, e in ipairs(entries or {}) do
        if e.word and e.word.text then
          if n_words % 5 == 0 and e.word.start then
            parts[#parts + 1] = ('[%.1f]'):format(
              math.max(0, (e.word.start - frag.src_lo) / rate))
          end
          parts[#parts + 1] = e.word.text
          n_words = n_words + 1
        end
      end
      local text = table.concat(parts, ' ')
      if text == '' then
        s.scene_phase = 'idle'
        set_status(s, 'No speech found in the selected fragment.', theme.COLORS.status_error)
        return
      end
      s.scene_transcript_text = text
      -- Step 2: LLM brief
      local llm = require 'modules.llm'
      local lh = llm.spawn_json({
        task          = M.TASK_SFX_BRIEF,
        purpose       = 'sfx',   -- per-feature override (Settings → AI)
        system_prompt = build_scene_system_prompt(s.scene_preset),
        user_prompt   = build_scene_user_prompt(frag.len, text, s.scene_detail),
        max_tokens    = 1024,
        temperature   = 0.8,
      })
      if lh.status == 'error' then
        s.scene_phase = 'idle'
        set_status(s, 'LLM: ' .. tostring(lh.error), theme.COLORS.status_error)
        return
      end
      s.scene_llm_handle = lh
      s.scene_phase = 'analyzing'
      set_status(s, ('Asking %s for sound ideas…'):format(lh.provider or 'LLM'), theme.COLORS.text_dim)
    elseif h.status == 'error' then
      s.scene_stt_handle = nil
      s.scene_phase = 'idle'
      set_status(s, 'Transcribe: ' .. tostring(h.error), theme.COLORS.status_error)
    end
  end

  -- Step 2 poll: LLM
  if s.scene_llm_handle then
    local llm = require 'modules.llm'
    local h = llm.poll(s.scene_llm_handle)
    async_op.force_error_if_stale(h, 'Scene ideas (LLM)')
    if h.status == 'done' then
      s.scene_llm_handle = nil
      local cands, cerr = M.validate_sfx_candidates(h.result and h.result.data,
        s.scene_frag and s.scene_frag.len or nil)
      if not cands then
        s.scene_phase = 'idle'
        set_status(s, 'LLM: ' .. tostring(cerr), theme.COLORS.status_error)
        return
      end
      s.scene_candidates = cands
      s.scene_phase = 'ready'
      set_status(s, ('%d sound idea%s ready — edit freely, then Generate.')
        :format(#cands, #cands == 1 and '' or 's'), theme.COLORS.status_done)
    elseif h.status == 'error' then
      s.scene_llm_handle = nil
      s.scene_phase = 'idle'
      set_status(s, 'LLM: ' .. tostring(h.error), theme.COLORS.status_error)
    end
  end
end

----------------------------------------------------------------------------
-- Rephrase pump — per-candidate handle (kandydat trzyma swój spinner).
----------------------------------------------------------------------------
local function poll_rephrase(s)
  for _, cand in ipairs(s.scene_candidates) do
    local h = cand.rephrase_handle
    if h then
      local llm = require 'modules.llm'
      llm.poll(h)
      async_op.force_error_if_stale(h, 'New idea (LLM)')
      if h.status == 'done' then
        cand.rephrase_handle = nil
        local applied, aerr = M.apply_rephrase(cand, h.result and h.result.data)
        if applied then
          set_status(s, 'New idea ready — review the description, then Generate.',
            theme.COLORS.status_done)
        else
          set_status(s, 'New idea: ' .. tostring(aerr), theme.COLORS.status_error)
        end
      elseif h.status == 'error' then
        cand.rephrase_handle = nil
        set_status(s, 'New idea: ' .. tostring(h.error), theme.COLORS.status_error)
      end
    end
  end
end

----------------------------------------------------------------------------
-- Request handlers (flagi z panelu).
----------------------------------------------------------------------------
local function handle_requests(s)
  if s.req_generate then
    local req = s.req_generate
    s.req_generate = nil
    if req.prompt and req.prompt ~= '' then
      start_generation(s, req)
      -- Znacznik "generated ×N" na karcie kandydata (scene flow).
      local cand = req.cand_index and s.scene_candidates[req.cand_index] or nil
      if cand then cand.gen_count = (cand.gen_count or 0) + 1 end
    end
  end

  if s.req_rephrase then
    local idx = s.req_rephrase
    s.req_rephrase = nil
    local cand = s.scene_candidates[idx]
    if cand and not cand.rephrase_handle then
      local llm = require 'modules.llm'
      local lh = llm.spawn_json({
        task          = M.TASK_SFX_REPHRASE,
        purpose       = 'sfx',   -- per-feature override (Settings → AI)
        system_prompt = build_rephrase_system_prompt(s.scene_preset, cand.kind),
        user_prompt   = build_rephrase_user_prompt(s, cand),
        max_tokens    = 400,
        temperature   = 0.9,
      })
      if lh.status == 'error' then
        set_status(s, 'New idea: ' .. tostring(lh.error), theme.COLORS.status_error)
      else
        cand.rephrase_handle = lh
        set_status(s, 'Asking for a fresh take on this idea…', theme.COLORS.text_dim)
      end
    end
  end

  if s.req_analyze then
    s.req_analyze = nil
    local frag, err = M.detect_scene_fragment()
    if not frag then
      set_status(s, err or 'No fragment.', theme.COLORS.status_error)
    else
      -- Mirror repair.start_stt RECIPE 1:1 (render visible region + geometry-
      -- stable cache key + diarize=true + language z repair_language) —
      -- IDENTYCZNE opts ⇒ cache WSPÓŁDZIELONY z Repair: item raz
      -- przetranskrybowany tam = darmowa analiza sceny tu (i odwrotnie).
      local audio_render = require 'modules.audio_render'
      local rendered_path, render_err, render_info = audio_render.prepare_audio_for_api(frag.item)
      if not rendered_path then
        set_status(s, 'Cannot render audio: ' .. tostring(render_err), theme.COLORS.status_error)
        return
      end
      local take = reaper.GetActiveTake(frag.item)
      local src  = helpers.resolve_root_source(reaper.GetMediaItemTake_Source(take))
      local src_path = reaper.GetMediaSourceFileName(src, '')
      local ri = {
        item_offs   = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0,
        item_length = reaper.GetMediaItemInfo_Value(frag.item, 'D_LENGTH') or 0,
        playrate    = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1,
        language    = cfg.get_repair_language(),
      }
      if ri.playrate <= 0 then ri.playrate = 1 end
      local h = stt.spawn_transcribe_for_item(frag.item, {
        language_code          = cfg.get_repair_language(),
        diarize                = true,
        timestamps_granularity = 'word',
        cache_key              = stt.cache_key(src_path, ri),
        timestamp_shift_secs   = render_info and (render_info.item_offs or 0) or 0,
        audio_path             = rendered_path,
      })
      if not h or h.status == 'error' then
        set_status(s, 'Transcribe: ' .. tostring(h and h.error or 'spawn failed'),
          theme.COLORS.status_error)
      else
        -- frag.item nie jest trzymany po spawn (item może zniknąć) — tylko
        -- liczby + guid. T9f (user-caught: insert "poza sceną"): pozycje są
        -- absolutne Z MOMENTU Analyze — gdy item przesunie się przed
        -- insertem, kotwiczymy do ŻYWEGO itemu (guid + delta w insercie).
        s.scene_frag = {
          pos = frag.pos, len = frag.len,
          src_lo = frag.src_lo, src_hi = frag.src_hi,
          playrate = frag.playrate or 1,
          item_guid = helpers.item_guid(frag.item),
          item_pos  = reaper.GetMediaItemInfo_Value(frag.item, 'D_POSITION') or 0,
        }
        s.scene_candidates  = {}
        -- T9e: nowa analiza = stare linki grupa→kandydat tracą sens
        -- (indeksy wskazywałyby INNE pomysły) → sieroty do dolnej sekcji.
        for _, g in ipairs(s.result_groups) do g.cand_index = nil end
        s.scene_stt_handle  = h
        s.scene_phase       = 'transcribing'
        set_status(s, h.status == 'done' and 'Transcript from cache…' or 'Transcribing fragment…',
          theme.COLORS.text_dim)
      end
    end
  end

  if s.req_insert then
    local req = s.req_insert
    s.req_insert = nil
    local group = find_group(s, req.group_id)
    local take
    if group then
      for _, t in ipairs(group.takes) do
        if t.id == req.take_id then take = t; break end
      end
    end
    if take then
      -- T9f: delta żywego itemu — pozycje grupy są absolutne z momentu
      -- Analyze; jeśli item źródłowy się przesunął, wszystkie kotwice
      -- (at/intro/outro) jadą razem z nim. Item zniknął → stare koordy.
      local delta = 0
      if req.where == 'scene' and group.anchor_guid then
        local src_it = helpers.find_item_by_guid(group.anchor_guid)
        if src_it then
          delta = (reaper.GetMediaItemInfo_Value(src_it, 'D_POSITION') or 0)
                - (group.anchor_pos or 0)
        end
      end
      -- T10b (user-caught): req.place / req.starts_at = BIEŻĄCE kontrolki
      -- wiersza kandydata — nadpisują snapshot grupy z momentu Generate
      -- (zmiana "At moment"→"Closes scene" po generacji MA działać przy
      -- ponownym Insert). Bez nadpisania (dolna sekcja) — snapshot.
      local eff_place = req.place
        or ((req.where == 'scene') and group.place or nil)
      local pos
      if req.where == 'scene' and group.scene_pos then
        if req.starts_at ~= nil and group.scene_start then
          pos = (group.scene_start + delta) + req.starts_at
        else
          pos = group.scene_pos + delta
        end
      else
        pos = reaper.GetCursorPosition()
      end
      insert_result(s, {
        path      = take.path,
        prompt    = group.prompt,
        kind      = group.kind,
        loop      = group.loop,
        scene_pos = group.scene_pos,
        -- T9: intro/outro — pozycja przeliczana w insert_result z realnej
        -- długości audio (tylko dla insertu "at scene").
        place       = eff_place,
        scene_start = group.scene_start and (group.scene_start + delta) or nil,
        scene_len   = group.scene_len,
        -- T9f: loop-fill — zapętlony ambient wstawiony "at scene" wypełnia
        -- scenę do jej końca (B_LOOPSRC), zamiast urywać się po długości
        -- źródła.
        fill_to_scene_end = (req.where == 'scene') or nil,
      }, pos)
    end
  end

  if s.req_cancel then
    s.req_cancel = nil
    -- Cancel = drop handles; curl workers dokończą w tle (niezmiennik #7),
    -- wyniki nie zostaną skonsumowane. Cache files zostają (housekeeping).
    s.gen_entries = {}
    prune_empty_groups(s)
    set_status(s, 'Generation cancelled (in-flight requests finish in background).',
      theme.COLORS.text_dim)
  end
end

----------------------------------------------------------------------------
-- Mode API (NS-A chassis).
----------------------------------------------------------------------------
function M.render(ctx, state, deps)
  sfx_panel.render(ctx, init_state(state), deps)
end

function M.render_modals(_ctx, _state, _deps)
  -- brak modali w M1
end

function M.consume_signals(state, _deps)
  local s = init_state(state)
  handle_requests(s)
  poll_scene_pipeline(s)
  poll_rephrase(s)
  poll_generation(s)

  -- T5b: dirty-detect po fingerprincie (panel mutuje stan bezpośrednio —
  -- zero mark_dirty w gui) + debounce 500 ms → flush do ProjExtState.
  local fp = state_fingerprint(s)
  if fp ~= s._last_fp then
    s._last_fp = fp
    mark_dirty(s)
  end
  if s._dirty and (util.now() - (s._dirty_at or 0)) > 0.5 then
    save_state_to_proj(s, s._loaded_proj)
    s._dirty = false
  end
end

function M.shutdown(state)
  -- T5b: synchroniczny flush przy atexit (mirror modes/tts.shutdown).
  local s = state and state.modes and state.modes.sfx
  if s and s._initialized and s._dirty then
    pcall(save_state_to_proj, s, s._loaded_proj)
    s._dirty = false
  end
end

return M
