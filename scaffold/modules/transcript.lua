-- modules/transcript.lua
-- Phase 11 (Dialog Repair) — transcript manipulation helpers (pure).
-- Brak REAPER API tutaj — testowalne sample-by-sample.
--
-- Scribe response zawiera w `words` zarówno realne słowa jak i whitespace
-- tokeny (np. " " między słowami). UI musi filtrować, ale zachowujemy raw
-- index'y żeby splice mógł odwołać się do oryginalnych timestampów.

local M = {}

----------------------------------------------------------------------------
-- M.is_word_token(w) → bool
-- True gdy entry to realne słowo (nie whitespace/space token).
----------------------------------------------------------------------------
function M.is_word_token(w)
  if type(w) ~= 'table' then return false end
  local t = w.text
  if type(t) ~= 'string' then return false end
  if t == '' then return false end
  if t:match('^%s+$') then return false end
  return true
end

----------------------------------------------------------------------------
-- M.iter_words(transcript) → iterator { display_idx, raw_idx, word_table }
-- Yields tylko realne słowa (skipuje whitespace), ale z raw_idx oryginalnym
-- indexem w transcript.words (potrzebne przy mapowaniu boundary timestamps).
----------------------------------------------------------------------------
function M.iter_words(transcript)
  local words = (transcript and transcript.words) or {}
  local i, display = 0, 0
  return function()
    while true do
      i = i + 1
      if i > #words then return nil end
      local w = words[i]
      if M.is_word_token(w) then
        display = display + 1
        return display, i, w
      end
    end
  end
end

----------------------------------------------------------------------------
-- M.is_word_in_bounds(w, bounds) → bool
-- bounds = { lo, hi } w source-time secs. Word fully within bounds (z mała
-- toleracją 0.01s na floating point) — useful przy itemach przyciętych
-- żeby ukryć słowa spoza widzialnego zakresu (Phase 11.x).
----------------------------------------------------------------------------
function M.is_word_in_bounds(w, bounds)
  if not bounds then return true end
  local s = tonumber(w.start) or 0
  local e = tonumber(w['end'])
  if not e then e = s end
  return s >= (bounds.lo or 0) - 0.01
     and e <= (bounds.hi or math.huge) + 0.01
end

----------------------------------------------------------------------------
-- M.collect_visible_words(transcript, bounds?)
-- bounds (opcjonalne): tylko słowa fully within [bounds.lo, bounds.hi]
-- (źródłowy czas w sec). Display idx są re-numbered po filtrze (1..N).
----------------------------------------------------------------------------
function M.collect_visible_words(transcript, bounds)
  local out = {}
  local display = 0
  for _, raw_idx, w in M.iter_words(transcript) do
    if M.is_word_in_bounds(w, bounds) then
      display = display + 1
      out[#out + 1] = { display = display, raw_idx = raw_idx, word = w }
    end
  end
  return out
end

----------------------------------------------------------------------------
-- Time formatting (UI captions)
----------------------------------------------------------------------------
function M.format_time(seconds)
  if not seconds or seconds < 0 then return '?' end
  if seconds < 10 then return ('%.2fs'):format(seconds) end
  if seconds < 60 then return ('%.1fs'):format(seconds) end
  return ('%dm %02ds'):format(math.floor(seconds / 60), math.floor(seconds % 60))
end

----------------------------------------------------------------------------
-- Confidence: Scribe zwraca logprob (negatywny; bliżej 0 = pewniejszy).
-- threshold default -0.5 = "low confidence" (~60% prob). Logprob = -1.0 ~= 37%.
----------------------------------------------------------------------------
function M.is_low_confidence(word, threshold)
  if type(word) ~= 'table' then return false end
  local lp = tonumber(word.logprob)
  if not lp then return false end
  return lp < (threshold or -0.5)
end

----------------------------------------------------------------------------
-- M.text_from_words(transcript) → reconstructed text z visible words +
-- single-space joins. Useful gdy transcript.text brak / chcemy normalize.
----------------------------------------------------------------------------
function M.text_from_words(transcript)
  local parts = {}
  for _, _, w in M.iter_words(transcript) do
    parts[#parts + 1] = w.text
  end
  return table.concat(parts, ' ')
end

----------------------------------------------------------------------------
-- Word table: szybki dostęp [display_idx] → { raw_idx, word, start, end }
-- Używane przez boundary detection żeby nie iterować transcript.words po
-- multiple razy.
----------------------------------------------------------------------------
function M.build_word_table(transcript, bounds)
  local out = {}
  local d = 0
  for _, raw_idx, w in M.iter_words(transcript) do
    if M.is_word_in_bounds(w, bounds) then
      d = d + 1
      out[d] = {
        raw_idx = raw_idx,
        word    = w,
        start   = tonumber(w.start) or 0,
        ['end'] = tonumber(w['end']) or 0,
        text    = w.text or '',
      }
    end
  end
  return out
end

-- find_phrase_boundary / find_sentence_boundary USUNIĘTE M5-4 (2026-07-11,
-- user OK) — jedyny konsument (okno scope w compute_scope) wycięty; git
-- history zachowuje.

----------------------------------------------------------------------------
-- M.compute_scope(words_tbl, sel_first, sel_last)
--
-- Selection (sel_first..sel_last) = słowa do PODMIANY (splice region).
-- M5-4 (audit 2026-07, user OK 2026-07-11): stara maszyneria "scope"
-- (Word/Phrase/Sentence jako okno kontekstu + prev_text/next_text) USUNIĘTA
-- — selektor nigdy nie trafił do UI, a pipeline buduje własny kontekst
-- (CONTEXT_N_WORDS w modes/repair). Zostają bounds selekcji + audio range.
--
-- Returns:
-- {
--   sel_first, sel_last,           -- selection range (= splice region)
--   audio_start, audio_end,        -- audio bounds OF SELECTION (do splice'a)
--   selected_text,                 -- tekst zaznaczonych słów (default edit buffer)
-- }
----------------------------------------------------------------------------
local function join_range(words_tbl, lo, hi)
  if lo > hi then return '' end
  local parts = {}
  for i = lo, hi do parts[#parts + 1] = words_tbl[i].text end
  return table.concat(parts, ' ')
end

function M.compute_scope(words_tbl, sel_first, sel_last)
  local n = #words_tbl
  sel_last = sel_last or sel_first
  if n == 0 or sel_first < 1 or sel_last > n or sel_first > sel_last then return nil end
  return {
    sel_first      = sel_first,
    sel_last       = sel_last,
    audio_start    = words_tbl[sel_first].start,
    audio_end      = words_tbl[sel_last]['end'],
    selected_text  = join_range(words_tbl, sel_first, sel_last),
  }
end

----------------------------------------------------------------------------
-- TTS cost estimate ($/1k chars Creator tier; rough).
-- Phase 11 future: read tier from /v1/user/subscription.
----------------------------------------------------------------------------
local DEFAULT_COST_PER_1K_CHARS = 0.30   -- Creator tier ~$0.30/1k

function M.estimate_tts_cost(text, cost_per_1k)
  local rate = cost_per_1k or DEFAULT_COST_PER_1K_CHARS
  -- Znaki, nie bajty (M3-1) — inline utf8.len żeby moduł został bez deps.
  local chars = utf8.len(text) or #text
  return (chars / 1000) * rate
end

return M
