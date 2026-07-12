-- modules/tempo_math.lua
-- Czysta matematyka NS-F tempo match — ZERO zależności od reaper.
--
-- Wydzielone z modes/repair.lua + reaper_helpers.lua (2026-06-10, audit fix
-- M0-1) żeby formuły były testowalne headless (tests/run.lua). Historia:
-- odwrócony wzór `speed = baseline / source_pace` (PM10 bug) przeszedł przez
-- syntax check i wyszedł dopiero w live teście — testy poniżej trzymają
-- kierunek wzoru na stałe.
--
-- Semantyka ElevenLabs: speed=K → TTS gra K× szybciej niż baseline głosu.
--   effective_TTS_rate = baseline × speed
-- Chcemy effective_TTS_rate == source_pace, czyli:
--   speed = source_pace / baseline        (NIGDY odwrotnie)
--
-- JEDNOSTKA (od 2026-06-10, W1.2 live-test): SYLABY na sekundę, NIE znaki.
-- Chars/sec okazały się złym perceptual proxy — edit 7 live-testu: wstawka
-- +21% szybsza w zn/s, a user słyszał "za wolno" (zbitki spółgłoskowe =
-- więcej znaków na sylabę). Plus #text w Lua liczy BAJTY (UTF-8 diakrytyki
-- = 2B) — polskie słowa z ogonkami sztucznie zawyżały "tempo".

local M = {}

M.DEFAULT_BASELINE = 4.5    -- sylaby/sec @ speed=1.0 (naturalna mowa PL/EN ~4-6)
M.EMA_ALPHA        = 0.3    -- waga nowej obserwacji w running EMA
M.SANITY_MIN       = 1.5    -- syl/sec — poniżej = mis-measurement
M.SANITY_MAX       = 12     -- syl/sec — powyżej = mis-measurement
M.SPEED_MIN        = 0.7    -- ElevenLabs safe zone (poza nią quality drop)
M.SPEED_MAX        = 1.2
M.OUTLIER_RATIO    = 0.5    -- odrzuć obserwację gdy drift >50% vs current
M.STRETCH_MAX_RATIO = 1.35  -- I9-narrow: cap łagodnego élastique stretch
                            -- (>35% wolniej = słyszalne artefakty; resztkowy
                            -- odchył zostaje zamiast degradacji)

----------------------------------------------------------------------------
-- syllable_count(word) → int
--
-- Heurystyka: liczba GRUP samogłoskowych (kolejne samogłoski = 1 sylaba).
-- Dla polskiego trafna ("nie"=1, "dziesięć"=2, "strasznego"=3); dla
-- angielskiego lekko zawyża silent-e ("time"→2) — błąd systematyczny,
-- znosi się w porównaniach source-vs-TTS tego samego tekstu/języka.
-- UTF-8 aware (utf8.codes, Lua 5.4); invalid bytes → fallback ASCII scan.
-- Słowa bez samogłosek ("w", "z") → 0 (klityki — fonetycznie poprawne).
----------------------------------------------------------------------------
local VOWEL_CP = {}
for _, cp in utf8.codes('aeiouyAEIOUY'
  .. 'ąęóĄĘÓ'                                  -- polski
  .. 'áéíúàèìòùäëïöüÁÉÍÚÀÈÌÒÙÄËÏÖÜ') do        -- zachodnioeuropejskie (auto-detect)
  VOWEL_CP[cp] = true
end

function M.syllable_count(word)
  if type(word) ~= 'string' or word == '' then return 0 end
  local ok, n = pcall(function()
    local count, prev = 0, false
    for _, cp in utf8.codes(word) do
      local v = VOWEL_CP[cp] == true
      if v and not prev then count = count + 1 end
      prev = v
    end
    return count
  end)
  if ok then return n end
  -- Invalid UTF-8 (uszkodzony token STT) → ASCII-only scan
  local count, prev = 0, false
  for i = 1, #word do
    local v = word:sub(i, i):match('[aeiouyAEIOUY]') ~= nil
    if v and not prev then count = count + 1 end
    prev = v
  end
  return count
end

----------------------------------------------------------------------------
-- matched_speed(source_pace, baseline) → speed clamped [SPEED_MIN, SPEED_MAX]
-- Fallback 1.0 gdy brak danych (nil / <=0).
----------------------------------------------------------------------------
function M.matched_speed(source_pace, baseline)
  if not source_pace or source_pace <= 0 then return 1.0 end
  if not baseline or baseline <= 0 then return 1.0 end
  local raw_speed = source_pace / baseline
  if raw_speed < M.SPEED_MIN then return M.SPEED_MIN end
  if raw_speed > M.SPEED_MAX then return M.SPEED_MAX end
  return raw_speed
end

----------------------------------------------------------------------------
-- normalize_observed(observed_pace, applied_speed) → baseline @ speed=1.0
-- observed = applied × baseline → baseline = observed / applied.
-- nil gdy inputs nieużyteczne.
----------------------------------------------------------------------------
function M.normalize_observed(observed_pace, applied_speed)
  if not observed_pace or observed_pace <= 0 then return nil end
  if not applied_speed or applied_speed <= 0 then return nil end
  return observed_pace / applied_speed
end

----------------------------------------------------------------------------
-- is_outlier(observed_baseline, current_baseline) → reject(bool), reason
-- Sanity bound [SANITY_MIN, SANITY_MAX] + drift >50% vs current.
----------------------------------------------------------------------------
function M.is_outlier(observed_baseline, current_baseline)
  if not observed_baseline then
    return true, 'observed baseline nil'
  end
  if observed_baseline < M.SANITY_MIN or observed_baseline > M.SANITY_MAX then
    return true, ('outside %.1f-%.1f syl/s sanity bound'):format(M.SANITY_MIN, M.SANITY_MAX)
  end
  if current_baseline and current_baseline > 0 then
    local ratio = observed_baseline / current_baseline
    if ratio < M.OUTLIER_RATIO or ratio > (1 + M.OUTLIER_RATIO) then
      return true, ('drift >50%% vs current (ratio %.2f)'):format(ratio)
    end
  end
  return false, nil
end

----------------------------------------------------------------------------
-- voiced_pace(words) → syl/s liczony WYŁĄCZNIE nad czasem mówienia słów
-- (suma sylab / suma trwań pojedynczych słów; pauzy MIĘDZY słowami nie
-- wchodzą). words = lista {text, start, end}. nil gdy brak danych.
--
-- W1 stretch fix (2026-06-10, live-evidence: "informacje" stretched +16% →
-- user "strasznie wolno"): block pace (last.end - first.start) zawiera
-- pauzy — wolna narracja jest wolna PAUZAMI, nie fonemami. Porównanie
-- block pace źródła z word-internal pace wstawki zawyżało stretch.
-- I9-narrow porównuje voiced_pace obu stron (ta sama rama pomiaru).
----------------------------------------------------------------------------
function M.voiced_pace(words)
  if type(words) ~= 'table' then return nil end
  local syl, dur = 0, 0
  for _, w in ipairs(words) do
    local s = tonumber(w.start)
    local e = tonumber(w['end'])
    if s and e and e > s then
      local n = M.syllable_count(w.text)
      if n > 0 then
        syl = syl + n
        dur = dur + (e - s)
      end
    end
  end
  if syl == 0 or dur <= 0 then return nil end
  return syl / dur
end

----------------------------------------------------------------------------
-- stretch_playrate(measured_pace, target_pace, tolerance) → playrate <1 | nil
--
-- I9-narrow (W1 sesja 2, USER-APPROVED 2026-06-10 — DEVIATIONS): przy
-- podłodze speed (SPEED_MIN) aktuator ElevenLabs fizycznie nie zwolni
-- renderu do tempa wolnej narracji (clamp-floor wall, KNOWN-ISSUES).
-- Domknięcie po stronie REAPER: D_PLAYRATE = target/measured (<1 = wklejka
-- gra wolniej, pitch preserved przez B_PPITCH).
--
-- Kierunek (trace): measured 4.0 syl/s vs target 3.2 → rate 0.8 →
-- timeline pace = 4.0 × 0.8 = 3.2 ✓. NIGDY odwrotnie (3.2/4.0 jako
-- mnożnik tempa GRY = poprawnie; odwrócenie dałoby przyspieszenie).
--
-- nil gdy: brak danych / measured nie przekracza targetu ponad tolerancję
-- (stretch naprawia WYŁĄCZNIE "render za szybki vs wolne źródło"; measured
-- < target przy podłodze = inny problem, zwolnienie by pogorszyło).
-- Cap: rate ≥ 1/STRETCH_MAX_RATIO (łagodny stretch per user approval).
--
-- RAMA POMIARU (W1 fix po live-evidence): oba inputy MUSZĄ być voiced-only
-- (M.voiced_pace) — block pace z pauzami jako target przeciąga słowa wstawki.
----------------------------------------------------------------------------
function M.stretch_playrate(measured_pace, target_pace, tolerance)
  if not measured_pace or measured_pace <= 0 then return nil end
  if not target_pace or target_pace <= 0 then return nil end
  tolerance = tolerance or 0.12
  if measured_pace <= target_pace * (1 + tolerance) then return nil end
  local rate = target_pace / measured_pace
  local min_rate = 1 / M.STRETCH_MAX_RATIO
  if rate < min_rate then rate = min_rate end
  return rate
end

----------------------------------------------------------------------------
-- ema_update(current, observed) → new_baseline, updated(bool)
-- Running EMA z sanity bound; przy odrzuceniu zwraca current bez zmian.
-- (Outlier-vs-current rejection robi caller przez is_outlier — tu tylko
-- sanity bound, mirror reaper_helpers.update_voice_tempo_baseline.)
----------------------------------------------------------------------------
function M.ema_update(current, observed)
  if not observed or observed <= 0 then return current, false end
  if observed < M.SANITY_MIN or observed > M.SANITY_MAX then return current, false end
  current = (current and current > 0) and current or M.DEFAULT_BASELINE
  local new_val = (1 - M.EMA_ALPHA) * current + M.EMA_ALPHA * observed
  return new_val, true
end

----------------------------------------------------------------------------
-- W2 M1: tempo-fit ladder dla dubbing full-segment splice (PHASE-W2 §2).
--
-- dub_fit_plan(opts) → plan | nil, err
--
-- Decyzja per segment PO wygenerowaniu TTS: jak ułożyć audio w spanie
-- segmentu bez zniekształcania mowy poza próg słyszalności. Rate liczony
-- na REGIONIE MOWY (speech_start..speech_end z alignmentu lub PCM lead
-- scan), NIE na pełnym audio z ciszami — inaczej bound nie odpowiadałby
-- zrealizowanemu tempu mowy. rate = take_time / source_time (>1 = wolniej).
--
-- Drabina (BRZMIENIE > TIMING):
--   1. fit_ratio ∈ [r_min, r_max] → force-fit do spanu (rate = fit_ratio).
--   2. fit_ratio > r_max (audio za krótkie) → rate = r_max, reszta spanu
--      = cisza ZA mową (gap_secs; user decision 2026-06-11 — bez split
--      lead/trail). Naturalny trail source'a wchodzi do itemu w rate 1.0
--      (oddech/decay), reszta luki = goły timeline (czysta cisza, zero
--      artefaktów stretchu ciszy).
--   3. fit_ratio < r_min (audio za długie) → najpierw slack (wolna
--      przestrzeń za spanem, user decision: ON domyślnie), potem kompresja
--      do r_min, nadal za długo → OVERRUN (rate zostaje r_min, item
--      nachodzi; jawny status zamiast zniekształcenia).
--
-- Lead cisza source'a: ściśnięta do ≤20ms take-time (LEAD_TAKE_MAX) —
-- onset mowy ląduje ~na seg.t_start (drift ≤20ms < boundary fade 20ms).
--
-- opts:
--   span          (s)  wymagane — seg.t_end - t_start
--   audio_len     (s)  wymagane — pełna długość TTS audio
--   speech_start  (s)  onset mowy w audio (alignment/PCM); default 0
--   speech_end    (s)  koniec mowy w audio; default audio_len
--   r_min, r_max       bounds (default 0.88/1.12 — config przekazuje)
--   slack         (s)  użyteczna przestrzeń ZA spanem (margines odjęty
--                      przez callera); default 0
--   gap_warn_frac      próg amber pilla GAP (default 0.25 spanu)
--   rate_override      wymuszony rate (anti-skok §2.4 / suwak M2) —
--                      pomija wybór strategii, geometria liczona normalnie
--
-- plan:
--   strategy      'fit' | 'gap' | 'overrun' (label z GEOMETRII: gap_secs
--                 > 0.05s → 'gap'; overrun_secs > 1ms → 'overrun')
--   fit_ratio     avail/speech_len (diagnostyka)
--   applied_rate  rate na regionie mowy
--   item_len      finalny D_LENGTH
--   markers       { {take, src}, ... } — take względem startu itemu,
--                 src absolutnie w source audio
--   gap_secs      cisza za mową w obrębie spanu
--   gap_warn      bool (gap_secs > gap_warn_frac × span)
--   overrun_secs  ile item wystaje poza span+slack
--   slack_used    ile slacku skonsumowane
--   speech_len, natural_len, lead_take — telemetria/dub_fit schema
----------------------------------------------------------------------------
M.DUB_FIT_R_MIN_DEFAULT = 0.88
M.DUB_FIT_R_MAX_DEFAULT = 1.12
M.DUB_FIT_GAP_WARN_FRAC = 0.25
M.DUB_FIT_LEAD_TAKE_MAX = 0.02   -- lead cisza ściśnięta do ≤20ms take-time
M.DUB_FIT_SMOOTH_DELTA  = 0.12   -- anti-skok: max |Δrate| sąsiadów speakera

function M.dub_fit_plan(opts)
  if type(opts) ~= 'table' then return nil, 'opts required' end
  local span      = tonumber(opts.span)
  local audio_len = tonumber(opts.audio_len)
  if not span or span <= 0 then return nil, 'bad span' end
  if not audio_len or audio_len <= 0 then return nil, 'bad audio_len' end

  local speech_start = tonumber(opts.speech_start) or 0
  if speech_start < 0 then speech_start = 0 end
  if speech_start > audio_len then speech_start = audio_len end
  local speech_end = tonumber(opts.speech_end) or audio_len
  if speech_end > audio_len then speech_end = audio_len end
  if speech_end < speech_start then speech_end = speech_start end
  -- Degenerate region mowy (alignment pusty/uszkodzony) → całe audio = mowa
  if (speech_end - speech_start) < 0.05 then
    speech_start, speech_end = 0, audio_len
  end
  local speech_len = math.max(0.05, speech_end - speech_start)

  local r_min = tonumber(opts.r_min) or M.DUB_FIT_R_MIN_DEFAULT
  local r_max = tonumber(opts.r_max) or M.DUB_FIT_R_MAX_DEFAULT
  local slack = math.max(0, tonumber(opts.slack) or 0)
  local gap_warn_frac = tonumber(opts.gap_warn_frac) or M.DUB_FIT_GAP_WARN_FRAC

  local lead_take = math.min(speech_start, M.DUB_FIT_LEAD_TAKE_MAX)
  local avail = math.max(0.01, span - lead_take)
  local fit_ratio = avail / speech_len

  local rate
  local override = tonumber(opts.rate_override)
  if override and override > 0 then
    rate = override
  elseif fit_ratio > r_max then
    rate = r_max
  elseif fit_ratio >= r_min then
    rate = fit_ratio
  else
    local rate_usable = (avail + slack) / speech_len
    if rate_usable >= 1.0 then
      rate = 1.0
    elseif rate_usable >= r_min then
      rate = rate_usable
    else
      rate = r_min
    end
  end

  local speech_take = speech_len * rate
  local end_take = lead_take + speech_take
  local gap_secs, slack_used, overrun_secs, trail_take = 0, 0, 0, 0
  if end_take <= span + 1e-9 then
    gap_secs = math.max(0, span - end_take)
    local trail_sil = math.max(0, audio_len - speech_end)
    trail_take = math.min(trail_sil, gap_secs)
  else
    slack_used = math.min(end_take - span, slack)
    overrun_secs = math.max(0, end_take - span - slack)
  end
  local item_len = end_take + trail_take

  local strategy = 'fit'
  if overrun_secs > 0.001 then
    strategy = 'overrun'
  elseif gap_secs > 0.05 then
    strategy = 'gap'
  end

  local markers = { { 0, 0 } }
  if speech_start > 1e-6 then
    markers[#markers + 1] = { lead_take, speech_start }
  end
  markers[#markers + 1] = { end_take, speech_end }
  if trail_take > 1e-6 then
    markers[#markers + 1] = { end_take + trail_take, speech_end + trail_take }
  end

  return {
    strategy     = strategy,
    fit_ratio    = fit_ratio,
    applied_rate = rate,
    item_len     = item_len,
    markers      = markers,
    gap_secs     = gap_secs,
    gap_warn     = gap_secs > gap_warn_frac * span,
    overrun_secs = overrun_secs,
    slack_used   = slack_used,
    speech_len   = speech_len,
    natural_len  = audio_len,
    lead_take    = lead_take,
  }
end

----------------------------------------------------------------------------
-- W2 M1 §2.4: anti-skok między sąsiednimi segmentami tego samego speakera.
--
-- dub_fit_smooth(rate_a, rate_b, lo_a, hi_a, lo_b, hi_b, max_delta)
--   → new_a, new_b | nil
--
-- Gdy |rate_a − rate_b| > max_delta → kompromis w stronę średniej, ALE
-- każdy rate tylko w swoim dozwolonym przedziale [lo, hi] (caller podaje
-- przecięcie strefy zielonej i geometrycznej wykonalności — np. hi
-- ograniczone przez slack, żeby smoothing nie tworzył NOWEGO overrunu).
-- Ruch wyłącznie ZBIEŻNY (niższy rate rośnie, wyższy maleje). Nie da się
-- zejść do max_delta w przedziałach → nil (fit ma priorytet, wartości
-- własne zostają — bez częściowego smoothingu).
----------------------------------------------------------------------------
function M.dub_fit_smooth(rate_a, rate_b, lo_a, hi_a, lo_b, hi_b, max_delta)
  max_delta = max_delta or M.DUB_FIT_SMOOTH_DELTA
  if not rate_a or not rate_b then return nil end
  if math.abs(rate_a - rate_b) <= max_delta + 1e-9 then return nil end

  -- Normalizacja: x = niższy rate (rośnie), y = wyższy (maleje)
  local swapped = rate_a > rate_b
  local x,  y  = rate_a, rate_b
  local lx, hx = lo_a or 0, hi_a or math.huge
  local ly, hy = lo_b or 0, hi_b or math.huge
  if swapped then
    x, y   = rate_b, rate_a
    lx, hx = lo_b or 0, hi_b or math.huge
    ly, hy = lo_a or 0, hi_a or math.huge
  end

  local m = (x + y) / 2
  -- Targety symetryczne wokół średniej; ruch tylko zbieżny + w przedziałach
  local nx = math.min(math.max(m - max_delta / 2, x), hx)
  local ny = math.max(math.min(m + max_delta / 2, y), ly)
  if ny - nx > max_delta + 1e-9 then
    -- Jedna strona uderzyła w bound — dociągnij drugą dalej, jeśli wolno
    local nx2 = math.min(ny - max_delta, hx)
    if nx2 >= x and ny - nx2 <= max_delta + 1e-9 then
      nx = nx2
    else
      local ny2 = math.max(nx + max_delta, ly)
      if ny2 <= y and ny2 - nx <= max_delta + 1e-9 then
        ny = ny2
      else
        return nil
      end
    end
  end

  if swapped then return ny, nx end
  return nx, ny
end

return M
