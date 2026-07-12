-- modules/llm.lua
-- NS-B Dubbing: pluggable LLM provider abstraction.
--
-- 4 providers (Anthropic / OpenAI / Gemini / DeepSeek), każdy z osobnym
-- adapterem w modules/llm/<provider>.lua. Provider detection per config —
-- effective_provider() returns active override or first configured key.
--
-- Public:
--   M.providers()                       → list of supported provider names
--   M.effective_provider()              → resolved provider z config
--   M.provider_model(p)                 → model id z config (or adapter default)
--   M.build_system_prompt(project, lang)→ system prompt builder (English, per §11.3)
--   M.translate_cache_key(opts)         → 8-char hex
--   M.translate_cache_path(opts)        → filesystem path
--   M.spawn_translate(opts)             → handle (cache hit returns synthetic done)
--   M.poll(handle)                      → mutates handle.status, returns handle
--
-- Handle shape after spawn:
--   { op='translate', status='running'|'done'|'error',
--     provider, model, sentinel_path, output_path, body_path, cache_path,
--     started_at, args }
-- After poll done:
--   handle.result = { translation, alternatives, syllable_count, warnings, confidence, usage }

local util = require 'modules.util'
local cfg  = require 'modules.config'
local json = require 'modules.lib.json'
local async_op = require 'modules.async_op'   -- M2-1: shared sentinel/diag

local M = {}

-- Wersja szablonu system promptu. Folded w translate_cache_key — każda zmiana
-- treści build_system_prompt MUSI bumpnąć tę stałą, inaczej cache zwróci
-- tłumaczenia wygenerowane starym promptem (klucz nie zawiera samego promptu).
-- Projekt trzyma translate_prompt_version — restore porównuje i mismatch
-- markuje stored translations jako stale (modes/dubbing.try_restore).
M.PROMPT_VERSION = 3

-- Provider adapters lazy-loaded (require chain w main module → 5 require'ów upfront unnecessary).
local ADAPTERS = nil
local function get_adapter(name)
  if not ADAPTERS then
    ADAPTERS = {
      anthropic = require 'modules.llm.anthropic',
      openai    = require 'modules.llm.openai',
      gemini    = require 'modules.llm.gemini',
      deepseek  = require 'modules.llm.deepseek',
      grok      = require 'modules.llm.grok',      -- W2 s6 (2026-06-11)
      mistral   = require 'modules.llm.mistral',   -- W2 s6 (2026-06-11)
    }
  end
  return ADAPTERS[name]
end

local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

local function translate_cache_root()
  return tmp_dir() .. path_sep() .. 'translate_cache'
end

local function worker_path()
  local _, this_path = reaper.get_action_context()
  local scaffold_dir = this_path and this_path:match('(.+)[/\\]') or ''
  return util.worker_script(scaffold_dir .. path_sep() .. 'workers' .. path_sep() .. 'worker_llm.sh')
end

----------------------------------------------------------------------------
-- Per-provider chmod-600 key files. W przeciwieństwie do api.ensure_key_file
-- (jeden plik na cały session bo single ElevenLabs key), tu mamy 4 files bo
-- 4 różne header formats (x-api-key / Authorization Bearer / x-goog-api-key).
----------------------------------------------------------------------------
local _provider_key_paths = {}    -- {[provider] = path}
local _provider_key_for   = {}    -- {[provider] = cached api_key}

local function ensure_provider_key_file(provider, api_key)
  if not api_key or api_key == '' then return nil, 'empty ' .. provider .. ' key' end
  util.mkdir_p(tmp_dir())
  if _provider_key_paths[provider] and _provider_key_for[provider] == api_key then
    if util.file_exists(_provider_key_paths[provider]) then
      return _provider_key_paths[provider]
    end
  end
  local adapter = get_adapter(provider)
  if not adapter then return nil, 'unknown provider: ' .. provider end
  local header = adapter.key_header(api_key)
  local path = tmp_dir() .. path_sep() .. '.reasonate_llm_' .. provider .. '_key'
  -- M6-2: tmp → chmod → rename (koniec okna TOCTOU: plik nigdy nie jest
  -- czytelny world-readable nawet przez moment) + błąd chmod logowany
  -- zamiast połykany przez 2>/dev/null.
  local tmp_path = path .. '.tmp'
  if not util.write_file(tmp_path, header) then
    return nil, 'cannot write key file: ' .. tmp_path
  end
  if not reaper.GetOS():find('Win') then
    local ok_chmod = os.execute('chmod 600 ' .. util.shell_escape(tmp_path))
    if ok_chmod ~= true and ok_chmod ~= 0 then
      reaper.ShowConsoleMsg(('[Reasonate] warning: chmod 600 failed for %s\n'):format(tmp_path))
    end
  end
  os.remove(path)
  if not os.rename(tmp_path, path) then
    os.remove(tmp_path)
    return nil, 'cannot publish key file: ' .. path
  end
  _provider_key_paths[provider] = path
  _provider_key_for[provider]   = api_key
  return path
end

-- M3-3 (audit 2026-06-10): wipe plików kluczy przy zamknięciu pluginu
-- (reaper.atexit). Pliki są chmod-600, ale nie ma powodu trzymać ich na
-- dysku między sesjami — odtwarzane on-demand przy następnym spawn.
function M.wipe_key_files()
  -- M6-1: iteracja po pełnym rejestrze providerów (hard-lista 4 gubiła
  -- grok/mistral dodanych w W2 s6 — ich pliki kluczy zostawały na dysku).
  for _, provider in ipairs(cfg.LLM_PROVIDERS_PRIORITY) do
    os.remove(tmp_dir() .. path_sep() .. '.reasonate_llm_' .. provider .. '_key')
    _provider_key_paths[provider] = nil
    _provider_key_for[provider]   = nil
  end
end

----------------------------------------------------------------------------
-- Public surface
----------------------------------------------------------------------------
----------------------------------------------------------------------------
-- Task definitions (NS-SFX generalizacja 2026-06-10). Adapter dostaje
-- opts.task i buduje provider-specific forced-JSON: anthropic tool_use
-- (task.schema), gemini responseSchema (task.schema), openai json_schema
-- (task.openai_schema — strict wymaga required-all + additionalProperties
-- false REKURENCYJNIE, stąd jawny wariant; fallback strict=false z canonical),
-- deepseek schema w system prompcie (task.deepseek_instruction).
-- Walidacja/normalizacja per task żyje w M.poll, NIE w adapterach.
----------------------------------------------------------------------------
M.TASK_TRANSLATE = {
  name        = 'emit_translation',
  description = 'Emit the final translation as a structured JSON object. ALWAYS call this tool — never reply with plain text.',
  schema = {
    type = 'object',
    properties = {
      translation    = { type = 'string', description = 'Primary translation in target language.' },
      alternatives   = {
        type        = 'array',
        items       = { type = 'string' },
        maxItems    = 3,
        description = 'Alternative translations (0-3 items, optional).',
      },
      syllable_count = { type = 'integer', description = 'Approximate syllable count of primary translation.' },
      warnings       = {
        type        = 'array',
        items       = { type = 'string' },
        description = 'Any concerns about this translation (e.g. ambiguity, length mismatch).',
      },
      -- BEZ minimum/maximum — Gemini responseSchema subset ich nie wspiera
      -- (canonical schema idzie 1:1 do anthropic input_schema i gemini).
      confidence     = { type = 'number', description = 'Confidence 0-1.' },
    },
    required = { 'translation' },
  },
  openai_schema = {
    name   = 'translation_result',
    strict = true,
    schema = {
      type = 'object',
      properties = {
        translation    = { type = 'string', description = 'Primary translation in target language.' },
        alternatives   = { type = 'array', items = { type = 'string' }, description = 'Alternative translations (0-3 items).' },
        syllable_count = { type = 'integer', description = 'Approximate syllable count of primary translation.' },
        warnings       = { type = 'array', items = { type = 'string' }, description = 'Concerns about this translation.' },
        confidence     = { type = 'number', description = 'Confidence 0.0-1.0.' },
      },
      required             = { 'translation', 'alternatives', 'syllable_count', 'warnings', 'confidence' },
      additionalProperties = false,
    },
  },
  deepseek_instruction = [[


OUTPUT FORMAT:
Return a single JSON object matching this exact schema (no markdown fence, no preamble, no commentary):
{
  "translation": "primary translation in target language (required, string)",
  "alternatives": ["optional alternative 1", "optional alternative 2"],
  "syllable_count": 12,
  "warnings": ["optional concerns about this translation"],
  "confidence": 0.9
}

Example output (for "Where were you?" → Polish):
{"translation": "Gdzie byłeś?", "alternatives": ["Gdzieś ty był?"], "syllable_count": 4, "warnings": [], "confidence": 0.95}

You MUST always include the "translation" field. Other fields can be empty arrays/zero/1.0 if no data.]],
}

function M.providers() return cfg.LLM_PROVIDERS_PRIORITY end

function M.effective_provider()
  return cfg.effective_llm_provider()
end

----------------------------------------------------------------------------
-- resolve_task(purpose) → provider, model — z per-feature override (Settings
-- → AI, 2026-06-11). purpose ∈ translate|enhance|sfx (nil = globalne).
-- Provider z override bez klucza = cichy fallback na globalny (usunięcie
-- klucza nie może wysadzać funkcji mid-flow). Model z override aplikowany
-- TYLKO gdy provider taska faktycznie użyty lub task nie nadpisuje providera
-- (model przypisany do providera, który odpadł = gwarantowany błąd API).
----------------------------------------------------------------------------
function M.resolve_task(purpose)
  local ov_provider   = purpose and cfg.get_llm_task_provider(purpose) or nil
  local use_override  = ov_provider and cfg.has_llm_provider_key(ov_provider) or false
  local provider      = use_override and ov_provider or M.effective_provider()
  if not provider then return nil end
  local model
  if purpose and (use_override or not ov_provider) then
    model = cfg.get_llm_task_model(purpose)
  end
  if not model or model == '' then
    model = cfg.get_llm_provider_model(provider)
  end
  return provider, model
end

function M.provider_model(provider)
  if not provider then return nil end
  return cfg.get_llm_provider_model(provider)
end

----------------------------------------------------------------------------
-- build_system_prompt(project, target_lang) → string
--
-- Per spec §11.3 — English instruction language (best LLM instruction-following
-- across all 4 providers); output translation w target_lang.
-- Per Correction 4 — conditional emotion-handling section per active TTS model
-- (v3 = audio tags supported, others = descriptive language only).
----------------------------------------------------------------------------
function M.build_system_prompt(project, target_lang)
  local ctx       = (project and project.context) or {}
  local tts_model = (project and project.tts_model) or cfg.get_dubbing_default_tts_model()
  local source_lang = (project and project.source_language) or 'auto-detected'

  -- Pause syntax per model (verified 2026-06-10, elevenlabs.io docs best-practices):
  -- v3 NIE wspiera <break> — pauzy przez '...' / interpunkcję; v2/turbo/flash
  -- wspierają <break time="X.Xs"/> (max 3s, nadmiar = artefakty audio).
  local audio_tag_note
  if tts_model == 'eleven_v3' then
    audio_tag_note = 'TTS MODEL CAPABILITY: Eleven v3 active. You MAY use inline audio tags like [whispers], [laughs], [sighs], [excited], [slowly] in translations where emotionally appropriate. Use sparingly — overuse degrades audio quality.\nPAUSE SYNTAX: SSML break tags are NOT supported by this model. Insert pauses with an ellipsis "..." at natural boundaries (adds a pause plus a slight hesitation); shape rhythm with standard punctuation (periods, commas, em-dashes).'
  else
    audio_tag_note = ('TTS MODEL CAPABILITY: %s active. Audio tags ARE NOT supported by this model. Express all emotion via descriptive language and punctuation only (e.g. "she whispered", "he gasped, ...").\nPAUSE SYNTAX: insert deliberate pauses with <break time="X.Xs" /> (max 3.0s). Use AT MOST 2-3 break tags per segment — more causes audio instability and artifacts. An ellipsis "..." gives a softer, shorter pause.'):format(tts_model)
  end

  local chars = {}
  if project and project.glossary and type(project.glossary.characters) == 'table' then
    for _, c in ipairs(project.glossary.characters) do
      if c.name then
        local desc = c.speaking_style or ''
        chars[#chars + 1] = '- ' .. c.name
          .. (c.preserve_name and ' (preserve name verbatim — never translate)' or '')
          .. (desc ~= '' and (': ' .. desc) or '')
      end
    end
  end
  local chars_block = #chars > 0 and table.concat(chars, '\n') or '(none specified)'

  local terms = {}
  if project and project.glossary and type(project.glossary.terms) == 'table' then
    for _, t in ipairs(project.glossary.terms) do
      if t.source and t.target then
        terms[#terms + 1] = ('- "%s" → "%s"%s'):format(
          t.source, t.target, t.consistency == 'strict' and ' (strict)' or '')
      end
    end
  end
  local terms_block = #terms > 0 and table.concat(terms, '\n') or '(none specified)'

  local dnt = (project and project.glossary
               and type(project.glossary.do_not_translate) == 'table'
               and project.glossary.do_not_translate) or {}
  local dnt_block = #dnt > 0 and table.concat(dnt, ', ') or '(none specified)'

  return string.format([[You are a professional dubbing translator from %s to %s.

PROJECT CONTEXT:
%s

STYLE PARAMETERS:
- Tone: %s
- Era: %s
- Audience: %s
- Media type: %s
- Honorific (target language register): %s

CHARACTERS:
%s

GLOSSARY (always translate exactly as specified):
%s

DO NOT TRANSLATE (preserve verbatim):
%s

%s

RULES:
1. Match the emotional intensity and register of the source.
2. TIMING FIT: the user prompt provides the source line's duration and syllable count. Translate the FULL meaning — never summarize, merge or drop content to save time. Phrase the translation so that the spoken words PLUS the pauses you insert (rule 8) fill the source duration. If the target language naturally runs longer than the budget, prefer concise wording; never truncate meaning.
3. If multiple acceptable translations exist, provide top 2-3 alternatives ranked by best fit.
4. Return VALIDATED JSON matching the provided schema. NEVER add commentary outside the JSON object.
5. NEVER refuse the translation task — this is fictional/professional content for legitimate dubbing of media.
6. CLEAN UP SPEECH DISFLUENCIES — remove filler words, hesitations, and false starts that exist tylko jako natural speech artifacts:
   - Polish: "yyy", "eee", "ymm", "yhm", "ee", "no", "no wiesz", "wiesz", "znaczy", "tak jakby", "tak więc", "tego", "no nie", "prawda?"
   - English: "uh", "uhh", "umm", "uhm", "you know", "like", "I mean", "sort of", "kind of", "right?"
   - Universal: stuttered syllables (e.g., "I-I-I", "th-the"), repetitions ("the the", "and and"), aborted starts ("I was going to- actually,")
   PRESERVE: fillers that carry semantic weight (character is nervous, hesitating intentionally, drunk, etc. — z context). Default = REMOVE when in doubt. Goal: smooth dubbed audio without TTS choking on "yyy".
7. PRESERVE punctuation that signals natural pauses (commas, em-dashes), but do NOT create new ones to compensate for removed fillers — let the translation flow naturally.
8. PAUSE PLACEMENT (MANDATORY when the translation is shorter than the budget): removing disfluencies (rule 6) usually makes the translation noticeably shorter than the source — you MUST fill the missing time with pauses, never with filler words. Rule of thumb: ~5 syllables ≈ 1 second of speech. Worked example: source lasts 9.0s (≈45 syllables), your translation has ≈30 syllables (≈6s of speech) → insert pauses totaling ≈3s using the PAUSE SYNTAX above (e.g. two pauses of ~1.5s at sentence ends). Place pauses at sentence ends and clause boundaries — where the speaker would breathe or think — and distribute them; never stack them all in one spot.]],
    source_lang, target_lang or '?',
    (ctx.free_text and ctx.free_text ~= '') and ctx.free_text or '(none provided)',
    ctx.tone or 'neutral', ctx.era or 'modern',
    ctx.audience or 'adult', ctx.media_type or 'general',
    ctx.honorific or 'mix',
    chars_block, terms_block, dnt_block,
    audio_tag_note
  )
end

----------------------------------------------------------------------------
-- Translation memory cache (deterministic, persistent).
-- Hash params: source_text + target_lang + glossary_hash + context_hash + provider + model.
-- Same source z same params = cache hit = zero cost.
----------------------------------------------------------------------------
function M.translate_cache_key(opts)
  local input = string.format(
    '%s|%s|%s|%s|%s|%s|pv%d',
    opts.source_text  or '',
    opts.target_lang  or '',
    opts.glossary_hash or '',
    opts.context_hash  or '',
    opts.provider     or '',
    opts.model        or '',
    M.PROMPT_VERSION)
  return string.format('%08x', util.simple_hash(input))
end

function M.translate_cache_path(opts)
  util.mkdir_p(translate_cache_root())
  local lang = opts.target_lang and opts.target_lang ~= '' and opts.target_lang or 'unknown'
  -- M4-8: lang jest nazwą katalogu — sanityzacja defensywna (panel waliduje
  -- input, ale stare projekty / restore mogą nieść dowolny string).
  lang = tostring(lang):lower():gsub('[^%l%d%-]', '_'):sub(1, 8)
  if lang == '' then lang = 'unknown' end
  local lang_dir = translate_cache_root() .. path_sep() .. lang
  util.mkdir_p(lang_dir)
  return lang_dir .. path_sep() .. M.translate_cache_key(opts) .. '.json'
end

local function read_cached(cache_path)
  if not cache_path or not util.file_exists(cache_path) then return nil end
  local raw = util.read_file(cache_path)
  if not raw or raw == '' then return nil end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= 'table' then return nil end
  if type(decoded.translation) ~= 'string' then return nil end
  return decoded
end

local function write_cached(cache_path, result, provider, model)
  if not cache_path or not result then return end
  local payload = {
    translation    = result.translation,
    alternatives   = result.alternatives or {},
    syllable_count = result.syllable_count or 0,
    warnings       = result.warnings or {},
    confidence     = result.confidence or 1.0,
    cached_at_unix = os.time(),
    provider       = provider,
    model          = model,
  }
  local ok, encoded = pcall(json.encode, payload)
  if ok then util.write_file(cache_path, encoded) end
end

----------------------------------------------------------------------------
-- spawn_worker_request — wspólny ogon spawnu (NS-SFX 2026-06-10): key file +
-- adapter.build_body + body file + worker cmd + running handle. Konsumenci:
-- spawn_translate (dokłada cache_path + task='translate') i spawn_json.
----------------------------------------------------------------------------
local function spawn_worker_request(provider, model, adapter, build_opts, args)
  local api_key = cfg.get_llm_provider_key(provider)
  if not api_key then
    return {
      op     = 'translate',
      status = 'error',
      error  = ('no API key for %s — set in Settings → Dubbing'):format(provider),
    }
  end
  local key_file, kerr = ensure_provider_key_file(provider, api_key)
  if not key_file then
    return { op = 'translate', status = 'error', error = kerr or 'no key file' }
  end

  local body = adapter.build_body(build_opts)

  util.mkdir_p(tmp_dir())
  local body_path = tmp_dir() .. path_sep()
                 .. ('llm_body_%s_%x_%x.json'):format(provider, os.time(), math.random(0, 0xFFFFFF))
  local ok_b, encoded = pcall(json.encode, body)
  if not ok_b then
    return { op = 'translate', status = 'error', error = 'JSON encode body failed: ' .. tostring(encoded) }
  end
  if not util.write_file(body_path, encoded) then
    return { op = 'translate', status = 'error', error = 'cannot write llm body file' }
  end

  local job_id = ('llm_%s_%x_%x'):format(provider, os.time(), math.random(0, 0xFFFFFF))
  local sentinel_path = tmp_dir() .. path_sep() .. job_id .. '.done'
  local output_path   = tmp_dir() .. path_sep() .. job_id .. '.json'

  local url = adapter.endpoint_url(model)

  local cmd = table.concat({
    util.shell_escape(worker_path()),
    util.shell_escape(provider),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(body_path),
    util.shell_escape(output_path),
    util.shell_escape(sentinel_path),
  }, ' ')

  util.exec_worker(cmd)

  return {
    op            = 'translate',
    status        = 'running',
    provider      = provider,
    model         = model,
    sentinel_path = sentinel_path,
    output_path   = output_path,
    body_path     = body_path,
    started_at    = util.now(),
    args          = args,
  }
end

----------------------------------------------------------------------------
-- spawn_translate(opts) → handle
--
-- opts: {
--   provider           (optional, default = effective_provider())
--   model              (optional, default = provider's configured model)
--   system_prompt      (string)
--   user_prompt        (string)
--   max_tokens         (default 1024)
--   temperature        (default 0.7)
--   source_text        (for cache key — defaults to user_prompt)
--   target_lang        (for cache key + path)
--   glossary_hash      (for cache key)
--   context_hash       (for cache key)
--   cache_control      (Anthropic only — enable prompt caching, default false)
-- }
--
-- Returns handle. status='done' (cache hit, from_cache=true) OR status='running'.
----------------------------------------------------------------------------
function M.spawn_translate(opts)
  opts = opts or {}
  local provider, task_model
  if opts.provider then
    provider = opts.provider
  else
    provider, task_model = M.resolve_task('translate')
  end
  if not provider then
    return {
      op     = 'translate',
      status = 'error',
      error  = 'no LLM provider configured — open Settings → AI tab to add a key',
    }
  end
  local model = opts.model or task_model or cfg.get_llm_provider_model(provider)
  local adapter = get_adapter(provider)
  if not adapter then
    return { op = 'translate', status = 'error', error = 'unknown LLM provider: ' .. tostring(provider) }
  end

  local cache_key_opts = {
    source_text   = opts.source_text or opts.user_prompt or '',
    target_lang   = opts.target_lang or '',
    glossary_hash = opts.glossary_hash or '',
    context_hash  = opts.context_hash or '',
    provider      = provider,
    model         = model,
  }
  local cache_path = M.translate_cache_path(cache_key_opts)

  local cached = read_cached(cache_path)
  if cached then
    return {
      op         = 'translate',
      status     = 'done',
      result     = cached,
      provider   = provider,
      model      = model,
      from_cache = true,
      started_at = util.now(),
      elapsed    = 0,
      cache_path = cache_path,
      args       = opts,
    }
  end

  local handle = spawn_worker_request(provider, model, adapter, {
    task          = M.TASK_TRANSLATE,
    model         = model,
    system_prompt = opts.system_prompt,
    user_prompt   = opts.user_prompt,
    max_tokens    = opts.max_tokens,
    temperature   = opts.temperature,
    cache_control = opts.cache_control,
  }, opts)
  handle.task       = 'translate'
  handle.cache_path = cache_path
  return handle
end

----------------------------------------------------------------------------
-- spawn_json(opts) → handle — generyczny forced-JSON request (NS-SFX
-- 2026-06-10). Mirror spawn_translate BEZ translate cache; wynik w poll:
-- handle.result = { data = <surowy obiekt wg task.schema>, usage = {...} }.
--
-- opts: { task (REQUIRED — patrz M.TASK_TRANSLATE shape), system_prompt,
--         user_prompt, max_tokens, temperature, provider?, model? }
----------------------------------------------------------------------------
function M.spawn_json(opts)
  opts = opts or {}
  if type(opts.task) ~= 'table' or not opts.task.name or type(opts.task.schema) ~= 'table' then
    return { op = 'translate', status = 'error', error = 'spawn_json: opts.task {name, schema} required' }
  end
  -- opts.purpose ('enhance' | 'sfx' | ...) → per-feature override z Settings → AI
  local provider, task_model
  if opts.provider then
    provider = opts.provider
  else
    provider, task_model = M.resolve_task(opts.purpose)
  end
  if not provider then
    return {
      op     = 'translate',
      status = 'error',
      error  = 'no LLM provider configured — open Settings → AI tab to add a key',
    }
  end
  local model = opts.model or task_model or cfg.get_llm_provider_model(provider)
  local adapter = get_adapter(provider)
  if not adapter then
    return { op = 'translate', status = 'error', error = 'unknown LLM provider: ' .. tostring(provider) }
  end
  local handle = spawn_worker_request(provider, model, adapter, {
    task          = opts.task,
    model         = model,
    system_prompt = opts.system_prompt,
    user_prompt   = opts.user_prompt,
    max_tokens    = opts.max_tokens,
    temperature   = opts.temperature,
  }, opts)
  handle.task = 'json'
  return handle
end

----------------------------------------------------------------------------
-- poll(handle) — idempotent. Returns handle (in-place mutation).
----------------------------------------------------------------------------
function M.poll(handle)
  if not handle then return nil end
  if handle.status ~= 'running' then return handle end
  if not util.file_exists(handle.sentinel_path) then return handle end

  -- Sentinel przez shared async_op (M2-1, 2026-06-10) — pre-fix llm.poll
  -- USUWAŁ .stderr/.curl_exit bez czytania: transport error (HTTP 0 — DNS /
  -- timeout / SSL) pokazywał się bez żadnej diagnozy.
  local sent = async_op.read_sentinel(handle)
  local http_code = sent.http_code

  local body = util.read_file(handle.output_path) or ''
  os.remove(handle.output_path)
  if handle.body_path then os.remove(handle.body_path) end

  handle.elapsed = util.now() - handle.started_at

  local adapter = get_adapter(handle.provider)
  if not adapter then
    handle.status = 'error'
    handle.error  = 'unknown provider on poll: ' .. tostring(handle.provider)
    return handle
  end

  local ok_d, decoded = pcall(json.decode, body)
  local parsed = ok_d and decoded or nil

  if http_code < 200 or http_code >= 300 then
    handle.status    = 'error'
    handle.http_code = http_code
    if http_code == 0 then
      -- Transport error — adapter nie ma JSON do sparsowania; shared diag
      -- (curl exit hint + stderr) zamiast gołego "HTTP 0".
      handle.error = async_op.format_http_error(handle.provider, sent, body)
    else
      handle.error = adapter.format_error(http_code, parsed or body)
    end
    return handle
  end

  if not parsed then
    handle.status = 'error'
    handle.error  = ('HTTP %d %s: invalid JSON response'):format(http_code, handle.provider)
    return handle
  end

  local out, perr = adapter.parse_success(parsed)
  if not out then
    handle.status = 'error'
    handle.error  = perr or 'parse_success failed'
    return handle
  end

  -- Per-task walidacja/normalizacja (adaptery zwracają surowe {data, usage}
  -- — NS-SFX generalizacja 2026-06-10; kształt wyniku translate BEZ zmian).
  if (handle.task or 'translate') == 'translate' then
    local data = out.data
    if type(data) ~= 'table' or type(data.translation) ~= 'string' or data.translation == '' then
      handle.status = 'error'
      handle.error  = (handle.provider or 'llm') .. ': response missing required field "translation"'
      return handle
    end
    local result = {
      translation    = data.translation,
      alternatives   = type(data.alternatives) == 'table' and data.alternatives or {},
      syllable_count = tonumber(data.syllable_count) or 0,
      warnings       = type(data.warnings) == 'table' and data.warnings or {},
      confidence     = tonumber(data.confidence) or 1.0,
      usage          = out.usage or {},
    }
    write_cached(handle.cache_path, result, handle.provider, handle.model)
    handle.status = 'done'
    handle.result = result
  else
    handle.status = 'done'
    handle.result = { data = out.data, usage = out.usage or {} }
  end
  return handle
end

----------------------------------------------------------------------------
-- Key test (Settings → AI → [Test], 2026-07-12 user request): GET na
-- endpoint listy modeli providera — darmowa walidacja klucza (zero
-- tokenów). 200 = OK, 401/403 = zły klucz. key_override = klucz z bufora
-- Settings (jeszcze nie zapisany — mirror M2-2 "Test connection").
----------------------------------------------------------------------------
local KEY_TEST_URLS = {
  anthropic = 'https://api.anthropic.com/v1/models',
  openai    = 'https://api.openai.com/v1/models',
  gemini    = 'https://generativelanguage.googleapis.com/v1beta/models',
  deepseek  = 'https://api.deepseek.com/models',
  grok      = 'https://api.x.ai/v1/models',
  mistral   = 'https://api.mistral.ai/v1/models',
}

local function key_test_worker_path()
  local _, this_path = reaper.get_action_context()
  local scaffold_dir = this_path and this_path:match('(.+)[/\\]') or ''
  return util.worker_script(scaffold_dir .. path_sep() .. 'workers' .. path_sep() .. 'worker_llm_test.sh')
end

function M.spawn_key_test(provider, key_override)
  local url = KEY_TEST_URLS[provider]
  if not url then
    return { op = 'llm_key_test', status = 'error', error = 'unknown provider: ' .. tostring(provider) }
  end
  local key = key_override
  if not key or key == '' then key = cfg.get_llm_provider_key(provider) end
  if not key or key == '' then
    return { op = 'llm_key_test', status = 'error', error = 'no key to test' }
  end
  local key_file, kerr = ensure_provider_key_file(provider, key)
  if not key_file then
    return { op = 'llm_key_test', status = 'error', error = kerr or 'no key file' }
  end

  util.mkdir_p(tmp_dir())
  local job_id = ('llmtest_%s_%x_%x'):format(provider, os.time(), math.random(0, 0xFFFFFF))
  local sentinel_path = tmp_dir() .. path_sep() .. job_id .. '.done'
  local output_path   = tmp_dir() .. path_sep() .. job_id .. '.json'

  local cmd = table.concat({
    util.shell_escape(key_test_worker_path()),
    util.shell_escape(provider),
    util.shell_escape(cfg.get_curl_path()),
    util.shell_escape(url),
    util.shell_escape(key_file),
    util.shell_escape(output_path),
    util.shell_escape(sentinel_path),
  }, ' ')
  util.exec_worker(cmd)

  return {
    op            = 'llm_key_test',
    status        = 'running',
    provider      = provider,
    out_path      = output_path,
    sentinel_path = sentinel_path,
    started_at    = util.now(),
  }
end

function M.poll_key_test(handle)
  if not handle or handle.status ~= 'running' then return handle end
  async_op.force_error_if_stale(handle, 'LLM key test')
  if handle.status == 'error' then return handle end
  if not util.file_exists(handle.sentinel_path) then return handle end

  local sent = async_op.read_sentinel(handle)
  os.remove(handle.out_path)
  if sent.http_code >= 200 and sent.http_code < 300 then
    handle.status = 'done'
  elseif sent.http_code == 400 or sent.http_code == 401 or sent.http_code == 403 then
    -- 400: Gemini i Grok odrzucają zły klucz statusem 400 (nie 401) —
    -- zweryfikowane empirycznie na wszystkich 6 endpointach 2026-07-12.
    -- Request jest stały/poprawny, więc 4xx tutaj = klucz odrzucony.
    handle.status = 'error'
    handle.error = 'invalid key (HTTP ' .. sent.http_code .. ')'
  elseif sent.http_code == 0 then
    handle.status = 'error'
    handle.error = 'network error' .. async_op.curl_exit_hint(sent.curl_exit)
  else
    handle.status = 'error'
    handle.error = ('unexpected HTTP %d'):format(sent.http_code)
  end
  return handle
end

return M
