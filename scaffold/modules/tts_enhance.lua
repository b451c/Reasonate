-- modules/tts_enhance.lua
--
-- "Enhance" (2026-06-11) — LLM wstawia ElevenLabs v3 audio tagi do tekstu TTS
-- bez zmiany ani jednego słowa. Odpowiednik przycisku "Enhance" z playgroundu
-- ElevenLabs: tam to funkcja czysto UI-owa (brak endpointu API, LLM po ich
-- stronie z dyrektywą "STRICTLY preserve the original text"). U nas: pluggable
-- llm.spawn_json (4 providery) + rzeczy, których oni nie mają:
--   1. TWARDY walidator words-preserved — po odpowiedzi zdejmujemy tagi
--      i porównujemy tokeny 1:1 z oryginałem; zmienione słowo = odrzucenie
--      (ElevenLabs Enhance potrafi cicho przepisać tekst).
--   2. Kontekst całej rozmowy w trybie dialogu (spójny łuk emocji między
--      mówcami zamiast tagowania linii w próżni).
--   3. Intensywność (subtle/standard/theatrical) + wskazówka reżyserska.
--
-- Moduł jest PURE (zero reaper deps) — testowany headless w tests/run.lua.
-- Spawn/poll/apply żyją w modes/tts.lua (stan + ImGui).

local audio_tags = require 'modules.audio_tags'
local json       = require 'modules.lib.json'

local M = {}

-- Tag = krótka fraza w nawiasach kwadratowych, bez zagnieżdżeń i newline'ów
-- (ten sam kształt co rich view w tts_dialogue_panel).
local TAG_PATTERN = '%[[^%[%]\n]-%]'

----------------------------------------------------------------------------
-- Intensywność tagowania — dźwignia, której ElevenLabs nie eksponuje.
----------------------------------------------------------------------------
M.INTENSITIES = {
  { id = 'subtle',     label = 'Subtle',
    tooltip = 'Only the clearest emotional beats get a tag. Most lines stay untouched.',
    brief = 'Tag lightly: at most one tag per couple of sentences and leave plain '
         .. 'passages untouched. Only the clearest emotional beats earn a tag.' },
  { id = 'standard',   label = 'Standard',
    tooltip = 'Balanced tagging — roughly one tag per sentence where it helps.',
    brief = 'Tag where it genuinely adds expressiveness: typically one tag per '
         .. 'sentence or line, occasionally two when the moment shifts.' },
  { id = 'theatrical', label = 'Theatrical',
    tooltip = 'Rich performance: emotions, reactions, delivery shifts. Best with Stability = Creative.',
    brief = 'Direct a rich, theatrical performance: emotional shifts, non-verbal '
         .. 'reactions and delivery changes. Two or three tags per line are fine '
         .. 'where they earn their place.' },
}

function M.find_intensity(id)
  for _, it in ipairs(M.INTENSITIES) do
    if it.id == id then return it end
  end
  return M.INTENSITIES[2]  -- standard
end

----------------------------------------------------------------------------
-- LLM task definitions (kształt per llm.spawn_json — mirror TASK_SFX_REPHRASE).
----------------------------------------------------------------------------
local SINGLE_PROPS = {
  text = {
    type        = 'string',
    description = 'The original text, unchanged word for word, with audio tags '
               .. 'in square brackets inserted.',
  },
}

M.TASK_ENHANCE_SINGLE = {
  name        = 'emit_enhanced_text',
  description = 'Emit the tagged text as a structured JSON object. ALWAYS call '
             .. 'this tool — never reply with plain text.',
  schema = {
    type       = 'object',
    properties = SINGLE_PROPS,
    required   = { 'text' },
  },
  openai_schema = {
    name   = 'tts_enhance_single',
    strict = true,
    schema = {
      type                 = 'object',
      properties           = SINGLE_PROPS,
      required             = { 'text' },
      additionalProperties = false,
    },
  },
  deepseek_instruction = [[


OUTPUT FORMAT:
Return a single JSON object matching this exact schema (no markdown fence, no preamble, no commentary):
{ "text": "[excited] We won! [laughs] I can't believe it." }

"text" = the original input text with audio tags inserted; every original word unchanged.]],
}

local DIALOGUE_LINE_PROPS = {
  id = {
    type        = 'string',
    description = 'The id of the input line, copied verbatim.',
  },
  text = {
    type        = 'string',
    description = 'The line text, unchanged word for word, with audio tags inserted.',
  },
}

local DIALOGUE_PROPS = {
  lines = {
    type        = 'array',
    description = 'Every input line in the same order, each with its original '
               .. 'id and the tagged text (return unchanged lines too).',
    items = {
      type       = 'object',
      properties = DIALOGUE_LINE_PROPS,
      required   = { 'id', 'text' },
    },
  },
}

M.TASK_ENHANCE_DIALOGUE = {
  name        = 'emit_enhanced_dialogue',
  description = 'Emit every dialogue line with audio tags as a structured JSON '
             .. 'object. ALWAYS call this tool — never reply with plain text.',
  schema = {
    type       = 'object',
    properties = DIALOGUE_PROPS,
    required   = { 'lines' },
  },
  openai_schema = {
    name   = 'tts_enhance_dialogue',
    strict = true,
    schema = {
      type       = 'object',
      properties = {
        lines = {
          type  = 'array',
          items = {
            type                 = 'object',
            properties           = DIALOGUE_LINE_PROPS,
            required             = { 'id', 'text' },
            additionalProperties = false,
          },
        },
      },
      required             = { 'lines' },
      additionalProperties = false,
    },
  },
  deepseek_instruction = [[


OUTPUT FORMAT:
Return a single JSON object matching this exact schema (no markdown fence, no preamble, no commentary):
{ "lines": [
  { "id": "ln_1", "text": "[whispers] Quiet... someone is here." },
  { "id": "ln_2", "text": "[nervous] Who? I can't see anyone." }
] }

Return EVERY input line (same ids, same order). "text" = that line's original text with audio tags inserted; every original word unchanged.]],
}

----------------------------------------------------------------------------
-- Prompt builders.
--
-- Szablon per memory feedback_llm_prompt_guides_loose: twarde limity tylko
-- tam gdzie naprawdę twarde (words unchanged = kontrakt feature'a), reszta
-- jako craft guidance + opcjonalne dźwignie. Słownik tagów z audio_tags.lua
-- jako PREFEROWANY (nie wyłączny) — v3 rozumie free-form tagi.
----------------------------------------------------------------------------
local PREFERRED_CATS = { Emotions = true, Delivery = true,
                         ['Non-verbal'] = true, Narrative = true }

local function tag_vocabulary_lines()
  local preferred, sparing = {}, {}
  for _, cat in ipairs(audio_tags.CATEGORIES) do
    local names = {}
    for _, t in ipairs(cat.tags) do names[#names + 1] = t.tag end
    local line = ('%s: %s'):format(cat.name, table.concat(names, ', '))
    if PREFERRED_CATS[cat.name] then
      preferred[#preferred + 1] = line
    else
      sparing[#sparing + 1] = line
    end
  end
  return table.concat(preferred, '\n'), table.concat(sparing, '\n')
end

-- build_system_prompt(intensity_id, opts{dialogue, strict_retry}) → string
function M.build_system_prompt(intensity_id, opts)
  opts = opts or {}
  local intensity = M.find_intensity(intensity_id)
  local preferred, sparing = tag_vocabulary_lines()

  local parts = {}
  parts[#parts + 1] =
    'You are an expert voice director preparing a script for ElevenLabs Eleven v3 — '
    .. 'an expressive text-to-speech model that understands inline audio tags: short '
    .. 'English stage directions in square brackets, e.g. [whispers], [sighs], [excited].\n\n'
    .. 'Your job: insert audio tags so the spoken performance becomes vivid and '
    .. 'engaging, while STRICTLY preserving the original text.'

  if opts.allow_punct then
    parts[#parts + 1] =
      'HARD RULES (a violation makes the output unusable):\n'
      .. '1. NEVER add, remove, replace or reorder any words. Beyond inserting [tags], '
      .. 'you may ONLY: insert an ellipsis (...) where a weighted pause belongs, and '
      .. 'write an existing word in CAPITALS for emphasis. Never alter the letters of '
      .. 'a word or rewrite its punctuation otherwise.\n'
      .. '2. Do not translate or paraphrase. The text language stays as written; tags '
      .. 'themselves are always short English phrases in lowercase square brackets.\n'
      .. '3. Keep any tags already present in the text; you may add new ones.\n'
      .. '4. Never place a tag inside a word.'
  else
    parts[#parts + 1] =
      'HARD RULES (a violation makes the output unusable):\n'
      .. '1. NEVER alter, add, remove or reorder any words or punctuation of the original '
      .. 'text. The output must be the exact original text with only [tags] inserted '
      .. 'between words.\n'
      .. '2. Do not translate or paraphrase. The text language stays as written; tags '
      .. 'themselves are always short English phrases in lowercase square brackets.\n'
      .. '3. Keep any tags already present in the text; you may add new ones.\n'
      .. '4. Never place a tag inside a word.'
  end

  local craft =
    'DIRECTING CRAFT (use your judgment):\n'
    .. '- Read the emotional subtext, then place each tag immediately BEFORE the words '
    .. 'it should color. A reaction tag ([laughs], [sighs], [gasps]) may instead sit '
    .. 'right where the reaction happens, including just after a sentence.\n'
    .. '- Less is more: one well-placed tag beats three generic ones. Do not tag what '
    .. 'the words already convey.\n'
    .. '- Vary the vocabulary; avoid repeating the same tag in consecutive sentences.'
  if opts.allow_punct then
    craft = craft
      .. '\n- Punctuation drives v3 delivery: an ellipsis (...) adds a weighted pause, '
      .. 'CAPITALS add emphasis to a word. Both are seasoning, not the meal — at most '
      .. 'one CAPS word per a few lines, ellipses only where a real beat belongs. '
      .. 'Example: "It was a VERY long day [sighs] ... nobody listens anymore."'
  end
  parts[#parts + 1] = craft

  parts[#parts + 1] = 'TAGGING INTENSITY: ' .. intensity.brief

  parts[#parts + 1] =
    'PREFERRED TAGS (proven with Eleven v3 — prefer these):\n' .. preferred
    .. '\n\nUse sparingly, only when the scene clearly calls for it (experimental '
    .. 'in v3):\n' .. sparing
    .. '\n\nYou may use another short natural-language tag when none of the above '
    .. 'fits — v3 understands free-form directions — but prefer the curated list.'

  if opts.dialogue then
    parts[#parts + 1] =
      'DIALOGUE: you receive a whole conversation with speaker labels. Tag each '
      .. 'line in the context of the conversation — keep each character\'s emotional '
      .. 'arc coherent and let them react to each other. Return EVERY line with its '
      .. 'id, including lines you leave unchanged.'
  end

  if opts.strict_retry then
    parts[#parts + 1] =
      'PREVIOUS ATTEMPT REJECTED: you changed the words. Copy the original text '
      .. 'EXACTLY, character for character, inserting only [tags].'
  end

  return table.concat(parts, '\n\n')
end

local function note_section(note)
  note = (note or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if note == '' then return '' end
  return 'Director\'s note from the user (style guidance — follow it): '
      .. note .. '\n\n'
end

function M.build_user_prompt_single(text, note)
  return note_section(note)
      .. 'Add audio tags to this text:\n\n'
      .. (text or '')
end

-- lines: array {id, speaker_id, text}; speaker_labels: map speaker_id → label.
function M.build_user_prompt_dialogue(lines, speaker_labels, note)
  speaker_labels = speaker_labels or {}
  local payload = {}
  for _, ln in ipairs(lines or {}) do
    payload[#payload + 1] = {
      id      = ln.id,
      speaker = speaker_labels[ln.speaker_id] or '?',
      text    = ln.text or '',
    }
  end
  return note_section(note)
      .. 'Add audio tags to this conversation (JSON lines, "speaker" is the '
      .. 'character name):\n\n'
      .. json.encode({ lines = payload })
end

----------------------------------------------------------------------------
-- Walidacja: twarda gwarancja "tylko tagi doszły, słowa nietknięte".
----------------------------------------------------------------------------

-- Zdejmij tagi + znormalizuj whitespace (tag zastępujemy spacją, żeby
-- "word[sigh]word" NIE skleiło się w jeden token — to byłaby zmiana słowa).
function M.strip_tags(text)
  local no_tags = (text or ''):gsub(TAG_PATTERN, ' ')
  no_tags = no_tags:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
  return no_tags
end

function M.count_tags(text)
  local n = 0
  for _ in (text or ''):gmatch(TAG_PATTERN) do n = n + 1 end
  return n
end

local function words_of(text)
  local out = {}
  for w in M.strip_tags(text):gmatch('%S+') do out[#out + 1] = w end
  return out
end
M.words_of = words_of

local function compare_token_lists(a, b)
  if #a ~= #b then
    return false, ('word count changed (%d → %d)'):format(#a, #b)
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false, ('word %d changed ("%s" → "%s")'):format(i, a[i], b[i])
    end
  end
  return true
end

-- words_preserved(original, enhanced) → ok, err
-- Porównanie tokenów 1:1 (case-sensitive, interpunkcja w tokenie) — łapie
-- też zmiany kapitalizacji i kropek, bo zakres "tylko tagi" (user decision).
function M.words_preserved(original, enhanced)
  return compare_token_lists(words_of(original), words_of(enhanced))
end

----------------------------------------------------------------------------
-- Tryb "pauses & emphasis" (opt-in, 2026-06-11): LLM może też wstawiać
-- wielokropki (pauza z wagą) i WERSALIKI (akcent) — oba czyta Eleven v3
-- per oficjalny guide. Gwarancja słów zostaje: porównujemy RDZENIE tokenów
-- (bez wielkości liter i interpunkcji). Zmienione/dodane/usunięte słowo
-- nadal odpada; zmiana samej kapitalizacji / dołożony "…" przechodzi.
----------------------------------------------------------------------------

-- Case fold: ASCII przez lower(); Latin-1 Supplement regułą +0x20 (À→à…);
-- polskie Latin Extended-A jawną mapą (ĄĆĘŁŃŚŹŻ — reguła parzystości NIE
-- działa dla Ł). Inne alfabety nie foldują → CAPS na nich = odrzucenie
-- (bezpieczny kierunek: zostaje oryginał, nigdy zepsuty tekst).
local PL_FOLD = {
  ['Ą'] = 'ą', ['Ć'] = 'ć', ['Ę'] = 'ę', ['Ł'] = 'ł',
  ['Ń'] = 'ń', ['Ś'] = 'ś', ['Ź'] = 'ź', ['Ż'] = 'ż',
}

local function fold_case(s)
  s = s:lower()
  s = s:gsub('\195([\128-\158])', function(b)
    local n = b:byte()
    if n == 0x97 then return '\195' .. b end  -- × (multiplication sign)
    return '\195' .. string.char(n + 0x20)
  end)
  for up, lo in pairs(PL_FOLD) do
    s = s:gsub(up, lo)
  end
  return s
end

-- Typograficzna interpunkcja wielobajtowa do zdjęcia z rdzenia tokenu
-- (ASCII %p łapie tylko bajty <128). Egzotyczna interpunkcja, której tu
-- nie ma, zostaje w rdzeniu — identyczna po obu stronach = nadal OK.
local MB_PUNCT = {
  '\226\128\166',  -- … ellipsis
  '\226\128\147',  -- – en-dash
  '\226\128\148',  -- — em-dash
  '\226\128\152', '\226\128\153',  -- ' '
  '\226\128\156', '\226\128\157',  -- " "
  '\226\128\158',  -- „
  '\194\171', '\194\187',          -- « »
}

local function token_core(tok)
  tok = tok:gsub('%p', '')
  for _, p in ipairs(MB_PUNCT) do
    tok = tok:gsub(p, '')
  end
  return fold_case(tok)
end

local function core_words_of(text)
  local out = {}
  for w in M.strip_tags(text):gmatch('%S+') do
    local c = token_core(w)
    if c ~= '' then out[#out + 1] = c end  -- token z samej interpunkcji ("…") pomijany
  end
  return out
end
M.core_words_of = core_words_of

-- words_preserved_loose(original, enhanced) → ok, err
function M.words_preserved_loose(original, enhanced)
  return compare_token_lists(core_words_of(original), core_words_of(enhanced))
end

-- Nawiasy poza poprawnymi tagami: ich liczba nie może się zmienić względem
-- oryginału (literalne [ ] w źródle są legalne — ale LLM nie może dołożyć
-- połamanych nawiasów ani pustych tagów).
local function stray_bracket_count(text)
  local without = (text or ''):gsub(TAG_PATTERN, '')
  local n = 0
  for _ in without:gmatch('[%[%]]') do n = n + 1 end
  return n
end

local function empty_tag_count(text)
  local n = 0
  for _ in (text or ''):gmatch('%[%s*%]') do n = n + 1 end
  return n
end

-- validate_enhanced_text(original, enhanced, opts) → stats|nil, err
-- stats = { tags_added = N } (N ≥ 0).
-- opts.allow_punct: tryb "pauses & emphasis" — porównanie luźne (rdzenie
-- tokenów; dopuszcza CAPS + dołożone …/interpunkcję, słowa wciąż twarde).
function M.validate_enhanced_text(original, enhanced, opts)
  if type(enhanced) ~= 'string' then
    return nil, 'response is not text'
  end
  if stray_bracket_count(enhanced) ~= stray_bracket_count(original) then
    return nil, 'unbalanced square brackets in response'
  end
  if empty_tag_count(enhanced) > empty_tag_count(original) then
    return nil, 'empty [] tag in response'
  end
  for tag in enhanced:gmatch(TAG_PATTERN) do
    if #tag > 62 then  -- 60 znaków treści + nawiasy
      return nil, 'overlong tag in response'
    end
  end
  local okw, werr
  if opts and opts.allow_punct then
    okw, werr = M.words_preserved_loose(original, enhanced)
  else
    okw, werr = M.words_preserved(original, enhanced)
  end
  if not okw then return nil, werr end
  local added = M.count_tags(enhanced) - M.count_tags(original)
  if added < 0 then added = 0 end
  return { tags_added = added }
end

----------------------------------------------------------------------------
-- plan_dialogue_apply(snapshot_lines, result_data) → plan|nil, err
--
-- snapshot_lines: array {id, text} — teksty z MOMENTU spawn (nie aktualne!).
-- result_data: zdekodowane {lines=[{id,text}]} z LLM.
-- plan = {
--   changes   = { {id, new_text, tags_added}, ... }  -- valid + realnie różne
--   invalid   = { {id, err}, ... }                   -- words altered itd.
--   unchanged = N                                    -- zwrócone bez zmian / brak w odpowiedzi
-- }
-- Aplikacja (mutacja stanu + wrap reset + snapshot revert) w modes/tts.lua.
----------------------------------------------------------------------------
function M.plan_dialogue_apply(snapshot_lines, result_data, opts)
  if type(result_data) ~= 'table' or type(result_data.lines) ~= 'table' then
    return nil, 'malformed response (missing lines array)'
  end
  local by_id = {}
  for _, rl in ipairs(result_data.lines) do
    if type(rl) == 'table' and type(rl.id) == 'string' and type(rl.text) == 'string' then
      by_id[rl.id] = rl.text
    end
  end
  local plan = { changes = {}, invalid = {}, unchanged = 0 }
  for _, ln in ipairs(snapshot_lines or {}) do
    local new_text = by_id[ln.id]
    if not new_text or new_text == ln.text then
      plan.unchanged = plan.unchanged + 1
    else
      local stats, verr = M.validate_enhanced_text(ln.text, new_text, opts)
      if stats then
        plan.changes[#plan.changes + 1] = {
          id = ln.id, new_text = new_text, tags_added = stats.tags_added,
        }
      else
        plan.invalid[#plan.invalid + 1] = { id = ln.id, err = verr }
      end
    end
  end
  return plan
end

return M
