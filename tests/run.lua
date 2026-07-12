-- tests/run.lua — headless unit tests dla modułów pure-logic Reasonate.
--
-- Uruchomienie:  lua5.4 tests/run.lua     (z root repo lub dowolnego cwd)
-- Exit code: 0 = wszystkie przeszły, 1 = co najmniej jedna porażka.
--
-- Zakres (M0-1 audit fix, 2026-06-10): util, lib.json, cache.compute_key,
-- tempo_math (w tym regression test odwróconego wzoru tempa z PM10).
-- Suite rośnie wraz z kolejnymi czystymi modułami (async_op retry itd.).

local THIS_DIR = (arg and arg[0] or ''):match('(.*[/\\])') or './'
package.path = THIS_DIR .. '../scaffold/?.lua;'
            .. THIS_DIR .. '?.lua;'
            .. package.path

-- Globalna atrapa reaper MUSI istnieć zanim require'niemy moduły scaffold.
_G.reaper = dofile(THIS_DIR .. 'reaper_stub.lua')

local util       = require 'modules.util'
local json       = require 'modules.lib.json'
local cache      = require 'modules.cache'
local tempo_math = require 'modules.tempo_math'
local async_op   = require 'modules.async_op'

----------------------------------------------------------------------------
-- Mini framework
----------------------------------------------------------------------------
local n_pass, n_fail = 0, 0
local failures = {}

local function record(ok, label, detail)
  if ok then
    n_pass = n_pass + 1
  else
    n_fail = n_fail + 1
    failures[#failures + 1] = ('FAIL: %s%s'):format(label, detail and (' — ' .. detail) or '')
  end
end

local function ok(cond, label)
  record(not not cond, label)
end

local function eq(actual, expected, label)
  record(actual == expected, label,
    ('expected %s, got %s'):format(tostring(expected), tostring(actual)))
end

local function near(actual, expected, eps, label)
  local good = type(actual) == 'number'
    and math.abs(actual - expected) <= (eps or 1e-6)
  record(good, label,
    ('expected ~%s (±%s), got %s'):format(tostring(expected), tostring(eps), tostring(actual)))
end

----------------------------------------------------------------------------
-- util.simple_hash
----------------------------------------------------------------------------
eq(util.simple_hash('abc'), util.simple_hash('abc'), 'simple_hash: deterministic')
ok(util.simple_hash('abc') ~= util.simple_hash('abd'), 'simple_hash: different inputs differ')
eq(util.simple_hash(''), 5381, 'simple_hash: empty string = DJB2 seed')
eq(type(util.simple_hash('x')), 'number', 'simple_hash: returns number')

----------------------------------------------------------------------------
-- util.format_duration
----------------------------------------------------------------------------
eq(util.format_duration(5), '5s', 'format_duration: seconds')
eq(util.format_duration(65), '1m 05s', 'format_duration: minutes')
eq(util.format_duration(3725), '1h 2m', 'format_duration: hours')
eq(util.format_duration(59.6), '1m 00s', 'format_duration: rounds 59.6 up to 1m')

----------------------------------------------------------------------------
-- util.shell_escape (POSIX path — stub GetOS()='OSX64')
----------------------------------------------------------------------------
eq(util.shell_escape('abc'), "'abc'", 'shell_escape: plain wrapped in single quotes')
eq(util.shell_escape("don't"), "'don'\\''t'", 'shell_escape: embedded single quote')
eq(util.shell_escape('a b c'), "'a b c'", 'shell_escape: spaces preserved')
eq(util.shell_escape(42), "'42'", 'shell_escape: non-string coerced via tostring')

----------------------------------------------------------------------------
-- util.base64_decode
----------------------------------------------------------------------------
eq(util.base64_decode('aGVsbG8='), 'hello', 'base64: simple decode')
eq(util.base64_decode('aGVsbG8gd29ybGQ='), 'hello world', 'base64: with padding')
eq(util.base64_decode('aGVs\nbG8='), 'hello', 'base64: ignores newlines')
eq(util.base64_decode('aGVsbG8'), 'hello', 'base64: works without padding')
eq(util.base64_decode('AAEC'), '\0\1\2', 'base64: binary bytes')
do
  local res, err = util.base64_decode('a$b!')
  ok(res == nil and err ~= nil, 'base64: invalid char -> nil + err')
  local res2, err2 = util.base64_decode('')
  ok(res2 == nil and err2 ~= nil, 'base64: empty -> nil + err')
end

----------------------------------------------------------------------------
-- lib.json sanity (vendored rxi/json)
----------------------------------------------------------------------------
eq(json.decode('{"a":1}').a, 1, 'json: decode object')
do
  local round = json.decode(json.encode({ x = 'ż∂é', n = 3.5, arr = { 1, 2 } }))
  eq(round.x, 'ż∂é', 'json: round-trip unicode string')
  eq(round.arr[2], 2, 'json: round-trip array')
end

----------------------------------------------------------------------------
-- cache.compute_key — determinizm + czułość na każdy param wpływający na audio
----------------------------------------------------------------------------
local BASE = {
  source_path = '/a/b.wav', source_size = 1000, source_length = 12.5,
  voice_id = 'v1', model_id = 'm1', seed = 7,
  settings = { stability = 0.5, similarity_boost = 0.75 },
  output_format = 'mp3_44100_128',
}
local function with(over)
  local t = {}
  for k, v in pairs(BASE) do t[k] = v end
  for k, v in pairs(over) do t[k] = v end
  return t
end

eq(cache.compute_key(BASE), cache.compute_key(with({})), 'compute_key: deterministic')
ok(cache.compute_key(BASE) ~= cache.compute_key(with({ voice_id = 'v2' })), 'compute_key: voice_id sensitive')
ok(cache.compute_key(BASE) ~= cache.compute_key(with({ seed = 8 })), 'compute_key: seed sensitive')
ok(cache.compute_key(BASE) ~= cache.compute_key(with({ output_format = 'pcm_44100' })), 'compute_key: format sensitive')
ok(cache.compute_key(BASE) ~= cache.compute_key(with({ settings = { stability = 0.9 } })), 'compute_key: settings sensitive')
ok(cache.compute_key(BASE) ~= cache.compute_key(with({ item_offs = 0.5, item_length = 5, playrate = 1 })), 'compute_key: trimmed item gets distinct key')
ok(cache.compute_key(BASE) ~= cache.compute_key(with({ item_offs = 0, item_length = 12.5, playrate = 1.5 })), 'compute_key: playrate != 1 gets distinct key')
eq(cache.compute_key(BASE), cache.compute_key(with({ item_offs = 0, item_length = 12.5, playrate = 1 })), 'compute_key: untrimmed explicit == omitted (backward compat)')
ok(cache.compute_key(BASE) ~= cache.compute_key(with({ isolate_audio = true })), 'compute_key: isolate flag sensitive')

----------------------------------------------------------------------------
-- M1-1 (audit 2026-07): kanoniczna serializacja settings — klucze cache
-- muszą być STABILNE między procesami (Lua 5.4 randomizuje pairs() per
-- proces; json.encode w kluczu = płatny cache-miss po każdym restarcie).
----------------------------------------------------------------------------
do
  -- Ta sama tabela zbudowana w dwóch kolejnościach wstawiania pól.
  local a = {}
  a.stability = 0.4; a.similarity_boost = 0.8; a.style = 0.1
  a.use_speaker_boost = true; a.speed = 1.05
  local b = {}
  b.speed = 1.05; b.use_speaker_boost = true; b.style = 0.1
  b.similarity_boost = 0.8; b.stability = 0.4

  eq(util.canon_voice_settings(a), util.canon_voice_settings(b),
     'canon_settings: insertion order irrelevant')
  eq(util.canon_voice_settings({}),
     'stab=0.5000|sim=0.7500|style=0.0000|boost=true|speed=1.0000',
     'canon_settings: empty table = all defaults (mirror settings_equal)')
  eq(util.canon_voice_settings(nil), '', 'canon_settings: nil → empty string')
  ok(util.canon_voice_settings({ stability = 0.9 })
     ~= util.canon_voice_settings({ stability = 0.4 }),
     'canon_settings: different values → different strings')
  eq(util.canon_voice_settings({ use_speaker_boost = false }):match('boost=(%w+)'),
     'false', 'canon_settings: boost=false serialized')

  -- util.utf8_len (M3-1): znaki, nie bajty — ElevenLabs liczy znaki.
  eq(util.utf8_len('zażółć'), 6, 'utf8_len: polskie diakrytyki = 6 znaków')
  ok(#('zażółć') > 6, 'utf8_len: #bajty > znaki dla diakrytyków (sanity)')
  eq(util.utf8_len(''), 0, 'utf8_len: pusty string')
  eq(util.utf8_len(nil), 0, 'utf8_len: nil → 0')
  eq(util.utf8_len('abc'), 3, 'utf8_len: czyste ASCII bez zmian')
  eq(util.utf8_len('\xC3\x28'), 2, 'utf8_len: invalid UTF-8 → fallback bajty')
  do -- gate 2000 znaków przechodzi dla 1999 polskich znaków (3998 bajtów)
    local t = string.rep('ż', 1999)
    ok(util.utf8_len(t) <= 2000, 'utf8_len: 1999 polskich znaków mieści się w limicie 2000')
    ok(#t > 2000, 'utf8_len: bajtowo ten sam tekst NIE mieściłby się (regression)')
  end

  -- util.iso639_1 (HOTFIX 2026-07-11, regresja M5-3): Scribe 639-3 → TTS 639-1.
  eq(util.iso639_1('eng'), 'en', 'iso639_1: eng → en (live-caught 400)')
  eq(util.iso639_1('pol'), 'pl', 'iso639_1: pol → pl')
  eq(util.iso639_1('en'), 'en', 'iso639_1: 2-literowy pass-through')
  eq(util.iso639_1('PL'), 'pl', 'iso639_1: lowercase')
  eq(util.iso639_1('pt-br'), 'pt', 'iso639_1: region strip')
  eq(util.iso639_1('deu'), 'de', 'iso639_1: deu → de')
  eq(util.iso639_1('jpn'), 'ja', 'iso639_1: jpn → ja')
  eq(util.iso639_1('fil'), 'fil', 'iso639_1: fil zostaje (ElevenLabs 3-lit)')
  eq(util.iso639_1('xyz'), nil, 'iso639_1: nieznany → nil (pole pomijane)')
  eq(util.iso639_1(''), nil, 'iso639_1: pusty → nil')
  eq(util.iso639_1(nil), nil, 'iso639_1: nil → nil')

  -- api.merge_voices_page (M3-2): merge 2 stron /v2/voices + type-guard.
  do
    local api = require 'modules.api'
    local page1 = { voices = {
      { voice_id = 'a1', name = 'Anna',  category = 'premade' },
      { voice_id = 'b2', name = 'Bruno', category = 'cloned',
        fine_tuning = { state = 'fine_tuned' } },
    }, has_more = true, next_page_token = 'tok2' }
    local page2 = { voices = {
      { voice_id = 'c3', name = 'Cleo', category = 'cloned',
        -- state jako TABLE (per-language map) — type-guard musi dać nil
        fine_tuning = { state = { en = 'fine_tuned' } } },
    }, has_more = false }
    local acc = api.merge_voices_page({}, page1)
    api.merge_voices_page(acc, page2)
    eq(#acc, 3, 'merge_voices_page: 2 strony → 3 głosy')
    eq(acc[1].voice_id, 'a1', 'merge_voices_page: kolejność zachowana (strona 1)')
    eq(acc[3].voice_id, 'c3', 'merge_voices_page: strona 2 doklejona na końcu')
    eq(acc[2].fine_tuning_state, 'fine_tuned', 'merge_voices_page: state string przechodzi')
    eq(acc[3].fine_tuning_state, nil, 'merge_voices_page: state TABLE → nil (type-guard)')
    eq(#api.merge_voices_page({}, nil), 0, 'merge_voices_page: nil page → pusty wynik')
    ok(api.MAX_VOICES_PAGES >= 10, 'merge_voices_page: cap stron >= 10 (1000 głosów)')
  end
  eq(cache.compute_key(with({ settings = a })), cache.compute_key(with({ settings = b })),
     'compute_key: settings insertion order irrelevant (M1-1)')

  -- tts.cache_key: determinizm + language_code w kluczu (M4-6)
  local tts = require 'modules.tts'
  local T = { voice_id = 'v1', text = 'zażółć', prev_text = 'a', next_text = 'b',
              voice_settings = a, seed = 3 }
  local function twith(over)
    local t = {}
    for k, v in pairs(T) do t[k] = v end
    for k, v in pairs(over) do t[k] = v end
    return t
  end
  eq(tts.cache_key(T), tts.cache_key(twith({})), 'tts.cache_key: deterministic')
  eq(tts.cache_key(twith({ voice_settings = b })), tts.cache_key(T),
     'tts.cache_key: settings insertion order irrelevant')
  ok(tts.cache_key(twith({ language_code = 'pl' })) ~= tts.cache_key(T),
     'tts.cache_key: language_code sensitive (M4-6)')
  ok(tts.cache_key(twith({ language_code = 'pl' }))
     ~= tts.cache_key(twith({ language_code = 'en' })),
     'tts.cache_key: pl vs en differ')
  ok(tts.cache_key(twith({ seed = 4 })) ~= tts.cache_key(T),
     'tts.cache_key: seed sensitive (regression)')

  -- dialogue_cache_key: determinizm + settings kanonicznie
  local D = { inputs = { { voice_id = 'v1', text = 'Hi' }, { voice_id = 'v2', text = 'Yo' } },
              settings = { stability = 0.5 }, seed = 1 }
  eq(tts.dialogue_cache_key(D), tts.dialogue_cache_key(D), 'dialogue_cache_key: deterministic')
  ok(tts.dialogue_cache_key(D) ~= tts.dialogue_cache_key({
       inputs = D.inputs, settings = { stability = 0.9 }, seed = 1 }),
     'dialogue_cache_key: settings sensitive')
end

----------------------------------------------------------------------------
-- stt.cache_key — I10 (M0 2026-06-10): language fold w geometry seed.
-- Kontrakt: callers BEZ pola .language (Dubbing) zachowują legacy keys;
-- Repair zawsze poda .language ('' = auto-detect) → klucz language-aware.
----------------------------------------------------------------------------
do
  local stt = require 'modules.stt'
  local function ri(lang)
    return { item_offs = 0.5, item_length = 10, playrate = 1, language = lang }
  end
  eq(stt.cache_key('/a.wav', ri('pl')), stt.cache_key('/a.wav', ri('pl')),
    'stt.cache_key: deterministic')
  eq(stt.cache_key('/a.wav', ri(nil)),
     stt.cache_key('/a.wav', { item_offs = 0.5, item_length = 10, playrate = 1 }),
    'stt.cache_key: nil language == legacy seed (Dubbing backward compat)')
  ok(stt.cache_key('/a.wav', ri('')) ~= stt.cache_key('/a.wav', ri(nil)),
    'stt.cache_key: auto-detect ("") differs from legacy (one-time Repair invalidation)')
  ok(stt.cache_key('/a.wav', ri('pl')) ~= stt.cache_key('/a.wav', ri('')),
    'stt.cache_key: forced lang differs from auto')
  ok(stt.cache_key('/a.wav', ri('pl')) ~= stt.cache_key('/a.wav', ri('en')),
    'stt.cache_key: pl differs from en')
end

----------------------------------------------------------------------------
-- tempo_math — REGRESSION GUARD na odwrócony wzór z PM10
-- ("strasznie przyspiesza": baseline/source zamiast source/baseline)
-- Jednostka od 2026-06-10 (W1.2): SYLABY/sec (chars/sec było złym proxy —
-- inwersja percepcji edit 7 + #text liczy bajty UTF-8).
----------------------------------------------------------------------------
-- Trace 1 (PM10 bug case przeskalowany): wolne źródło 3.5 syl/s, baseline 4.7.
-- Poprawnie: speed < 1.0 (TTS ma mówić WOLNIEJ). Buggy formula dawała >1 → clamp 1.2.
near(tempo_math.matched_speed(3.5, 4.7), 3.5 / 4.7, 1e-9, 'tempo: speed = source/baseline (PM10 trace 1)')
ok(tempo_math.matched_speed(3.5, 4.7) < 1.0, 'tempo: slow source -> speed < 1.0 (DIRECTION)')
-- Trace 2: source szybszy niż baseline → speed > 1.0.
ok(tempo_math.matched_speed(5.5, 4.7) > 1.0, 'tempo: fast source -> speed > 1.0 (DIRECTION)')
eq(tempo_math.matched_speed(6.5, 4.7), tempo_math.SPEED_MAX, 'tempo: clamp max')
eq(tempo_math.matched_speed(2.5, 4.7), tempo_math.SPEED_MIN, 'tempo: clamp min')
eq(tempo_math.matched_speed(nil, 4.7), 1.0, 'tempo: nil source -> neutral 1.0')
eq(tempo_math.matched_speed(4.0, 0), 1.0, 'tempo: zero baseline -> neutral 1.0')

near(tempo_math.normalize_observed(4.0, 0.8), 5.0, 1e-9, 'tempo: observed/applied normalization')
eq(tempo_math.normalize_observed(0, 1), nil, 'tempo: zero observed -> nil')
eq(tempo_math.normalize_observed(4.0, 0), nil, 'tempo: zero applied -> nil')

ok(tempo_math.is_outlier(1.0, 4.7), 'tempo outlier: below sanity bound')
ok(tempo_math.is_outlier(13, 4.7), 'tempo outlier: above sanity bound')
ok(tempo_math.is_outlier(7.5, 4.7), 'tempo outlier: drift ratio 1.60 rejected')
ok(not tempo_math.is_outlier(5.8, 4.7), 'tempo outlier: ratio 1.23 accepted')
ok(tempo_math.is_outlier(nil, 4.7), 'tempo outlier: nil observed rejected')

do
  local v, updated = tempo_math.ema_update(4.7, 5.3)
  near(v, 0.7 * 4.7 + 0.3 * 5.3, 1e-9, 'tempo EMA: (1-0.3)*4.7 + 0.3*5.3')
  ok(updated, 'tempo EMA: update flag true')
  local v2, updated2 = tempo_math.ema_update(4.7, 13)
  eq(v2, 4.7, 'tempo EMA: sanity reject keeps current')
  ok(not updated2, 'tempo EMA: reject flag false')
  local v3, updated3 = tempo_math.ema_update(nil, 5.0)
  near(v3, 0.7 * tempo_math.DEFAULT_BASELINE + 0.3 * 5.0, 1e-9,
    'tempo EMA: nil current falls back to DEFAULT_BASELINE')
  ok(updated3, 'tempo EMA: nil-current update flag true')
end

----------------------------------------------------------------------------
-- tempo_math.stretch_playrate — I9-narrow (W1 sesja 2, 2026-06-10).
-- DIRECTION GUARD: rate = target/measured (<1 zwalnia). Trace z live-testu:
-- głos przy podłodze 0.7 renderuje ~4.0 syl/s, wolna narracja 3.2.
----------------------------------------------------------------------------
near(tempo_math.stretch_playrate(4.0, 3.2, 0.12), 0.8, 1e-9,
  'stretch: rate = target/measured (clamp-floor trace: 4.0 -> 3.2 = 0.8)')
ok((tempo_math.stretch_playrate(4.0, 3.2, 0.12) or 1) < 1.0,
  'stretch: too-fast render -> rate < 1.0 (DIRECTION: slow down)')
near(tempo_math.stretch_playrate(5.0, 3.0, 0.12), 1 / tempo_math.STRETCH_MAX_RATIO, 1e-9,
  'stretch: ratio 1.67 capped at 1/STRETCH_MAX_RATIO (~0.74, gentle only)')
eq(tempo_math.stretch_playrate(3.4, 3.2, 0.12), nil,
  'stretch: dev +6% within tolerance -> nil (no stretch)')
eq(tempo_math.stretch_playrate(3.0, 3.2, 0.12), nil,
  'stretch: render SLOWER than target -> nil (never speed up)')
eq(tempo_math.stretch_playrate(nil, 3.2, 0.12), nil, 'stretch: nil measured -> nil')
eq(tempo_math.stretch_playrate(4.0, 0, 0.12), nil, 'stretch: zero target -> nil')
near(tempo_math.stretch_playrate(4.0, 3.2), 0.8, 1e-9,
  'stretch: default tolerance 0.12 when omitted')

----------------------------------------------------------------------------
-- tempo_math.voiced_pace — W1 stretch fix (2026-06-10, live-evidence).
-- Block pace źródła zawiera pauzy (wolna narracja = wolna PAUZAMI) —
-- stretch porównuje words-only po obu stronach.
----------------------------------------------------------------------------
do
  -- 3 słowa (1+2+1 syl), 0.4s każde, pauzy 0.6s między nimi:
  -- block pace = 4 syl / 2.4s ≈ 1.67; voiced = 4 / 1.2 ≈ 3.33.
  local words = {
    { text = 'ktoś',  start = 0.0, ['end'] = 0.4 },
    { text = 'dawał', start = 1.0, ['end'] = 1.4 },
    { text = 'nam',   start = 2.0, ['end'] = 2.4 },
  }
  near(tempo_math.voiced_pace(words), 4 / 1.2, 1e-9,
    'voiced_pace: pauzy między słowami NIE wchodzą do czasu')
  eq(tempo_math.voiced_pace({}), nil, 'voiced_pace: empty -> nil')
  eq(tempo_math.voiced_pace(nil), nil, 'voiced_pace: nil -> nil')
  near(tempo_math.voiced_pace({
    { text = 'w',   start = 0,   ['end'] = 0.1 },
    { text = 'las', start = 0.2, ['end'] = 0.5 },
  }), 1 / 0.3, 1e-9, 'voiced_pace: klityka (0 syl) pominięta')
  -- Trace złego live edita ("informacje"): words-only src ~4.8 vs tts 3.64 —
  -- render już WOLNIEJSZY od słów źródła → stretch NIE rusza (pre-fix block
  -- pace 3.13 jako target dawał playrate 0.859 → "strasznie wolno").
  eq(tempo_math.stretch_playrate(3.64, 4.8, 0.12), nil,
    'stretch regression: drawl render slower than source WORDS -> no stretch')
end

----------------------------------------------------------------------------
-- tempo_math.syllable_count — W1.2 (2026-06-10): grupy samogłoskowe, UTF-8.
-- Przykłady z live-test session (edit 7/8 material).
----------------------------------------------------------------------------
eq(tempo_math.syllable_count('przy'), 1, 'syl: przy = 1')
eq(tempo_math.syllable_count('dziesięć'), 2, 'syl: dzie-sięć = 2 (i+vowel glide, ę multibyte)')
eq(tempo_math.syllable_count('strasznego'), 3, 'syl: stra-szne-go = 3')
eq(tempo_math.syllable_count('minut'), 2, 'syl: mi-nut = 2')
eq(tempo_math.syllable_count('Bohater'), 3, 'syl: Bo-ha-ter = 3 (uppercase)')
eq(tempo_math.syllable_count('Janek'), 2, 'syl: Ja-nek = 2')
eq(tempo_math.syllable_count('nie'), 1, 'syl: nie = 1 (ie group)')
eq(tempo_math.syllable_count('żółć'), 1, 'syl: żółć = 1 (multibyte ó)')
eq(tempo_math.syllable_count('w'), 0, 'syl: klityka w = 0 (no vowels)')
eq(tempo_math.syllable_count(''), 0, 'syl: empty = 0')
eq(tempo_math.syllable_count('audio'), 2, 'syl: au-dio = 2 (vowel groups)')
eq(tempo_math.syllable_count('time'), 2, 'syl: time = 2 (EN silent-e overcount — documented bias)')
eq(tempo_math.syllable_count(nil), 0, 'syl: nil = 0')

----------------------------------------------------------------------------
-- tempo_math.dub_fit_plan — W2 M1 tempo-fit ladder (PHASE-W2 §2).
-- Rate na REGIONIE MOWY; BRZMIENIE > TIMING: granice 0.88/1.12, gap jawny
-- za mową, slack przed kompresją, overrun zamiast zniekształcenia.
----------------------------------------------------------------------------
do
  -- 1. Strefa zielona: fit dokładnie do spanu (lead ściśnięty do 20ms).
  local p = tempo_math.dub_fit_plan{
    span = 4.0, audio_len = 4.2, speech_start = 0.1, speech_end = 4.0 }
  eq(p.strategy, 'fit', 'dub_fit: green zone -> fit')
  near(p.applied_rate, 3.98 / 3.9, 1e-9, 'dub_fit: rate = avail/speech_len')
  near(p.item_len, 4.0, 1e-9, 'dub_fit: green zone item_len = span exactly')
  near(p.gap_secs, 0, 1e-9, 'dub_fit: green zone no gap')
  eq(#p.markers, 3, 'dub_fit: markers start + lead + speech_end')
  near(p.markers[2][1], 0.02, 1e-9, 'dub_fit: lead squeezed to 20ms take')
  near(p.markers[2][2], 0.1, 1e-9, 'dub_fit: lead marker src = speech_start')
  near(p.markers[3][1], 4.0, 1e-9, 'dub_fit: speech end marker at span')

  -- 2. Audio za krótkie -> gap za mową (user decision), amber warn.
  local g = tempo_math.dub_fit_plan{
    span = 5.0, audio_len = 3.0, speech_start = 0, speech_end = 3.0 }
  eq(g.strategy, 'gap', 'dub_fit: too-short -> gap strategy')
  near(g.applied_rate, 1.12, 1e-9, 'dub_fit: gap stretches only to R_MAX')
  near(g.gap_secs, 5.0 - 3.36, 1e-9, 'dub_fit: gap = span - speech_take')
  ok(g.gap_warn, 'dub_fit: gap 1.64s > 25% of 5s span -> warn')
  near(g.item_len, 3.36, 1e-9, 'dub_fit: no trail -> item ends with speech')

  -- 3. Gap z naturalnym trailem source'a (oddech/decay w rate 1.0).
  local t = tempo_math.dub_fit_plan{
    span = 5.0, audio_len = 3.5, speech_start = 0, speech_end = 3.0 }
  near(t.item_len, 3.36 + 0.5, 1e-9, 'dub_fit: natural trail included in item')
  near(t.markers[#t.markers][2], 3.5, 1e-9, 'dub_fit: trail marker src = audio_len')
  eq(t.strategy, 'gap', 'dub_fit: trail does not change gap label')

  -- 4. Za długie + duży slack -> naturalne tempo, przelew do slacku.
  local s1 = tempo_math.dub_fit_plan{
    span = 3.0, audio_len = 4.0, slack = 1.5 }
  eq(s1.strategy, 'fit', 'dub_fit: slack absorbs -> fit')
  near(s1.applied_rate, 1.0, 1e-9, 'dub_fit: natural rate when slack suffices')
  near(s1.slack_used, 1.0, 1e-9, 'dub_fit: slack_used = overflow beyond span')
  near(s1.overrun_secs, 0, 1e-9, 'dub_fit: no overrun with enough slack')

  -- 5. Za długie + częściowy slack -> kompresja w paśmie.
  local s2 = tempo_math.dub_fit_plan{
    span = 3.0, audio_len = 4.0, slack = 0.6 }
  near(s2.applied_rate, 0.9, 1e-9, 'dub_fit: rate = (span+slack)/speech_len in band')
  eq(s2.strategy, 'fit', 'dub_fit: partial slack still fits')

  -- 6. Za długie bez slacku -> R_MIN + OVERRUN (nie zniekształcamy dalej).
  local o = tempo_math.dub_fit_plan{
    span = 3.0, audio_len = 4.0, slack = 0 }
  eq(o.strategy, 'overrun', 'dub_fit: beyond R_MIN -> overrun')
  near(o.applied_rate, 0.88, 1e-9, 'dub_fit: overrun keeps rate at R_MIN')
  near(o.overrun_secs, 3.52 - 3.0, 1e-9, 'dub_fit: overrun amount explicit')

  -- 7. rate_override (anti-skok / suwak M2) wymusza rate, geometria uczciwa.
  local r = tempo_math.dub_fit_plan{
    span = 3.0, audio_len = 4.0, slack = 0, rate_override = 1.0 }
  near(r.applied_rate, 1.0, 1e-9, 'dub_fit: override rate respected')
  near(r.overrun_secs, 1.0, 1e-9, 'dub_fit: override geometry honest (overrun)')
  -- 7b. Override wolniejszy niż trzeba (suwak M2) -> uczciwy gap za mową.
  local r2 = tempo_math.dub_fit_plan{
    span = 5.0, audio_len = 3.0, rate_override = 1.0 }
  eq(r2.strategy, 'gap', 'dub_fit: slow override -> honest gap strategy')
  near(r2.gap_secs, 2.0, 1e-9, 'dub_fit: slow override gap = span - speech_take')
  -- 7c. Override poza strefą zieloną (świadoma decyzja usera) honorowany.
  local r3 = tempo_math.dub_fit_plan{
    span = 5.0, audio_len = 3.0, rate_override = 1.30 }
  near(r3.applied_rate, 1.30, 1e-9, 'dub_fit: override beyond R_MAX honored')
  near(r3.gap_secs, 5.0 - 3.9, 1e-9, 'dub_fit: beyond-band override geometry honest')

  -- 8. Zdegenerowany region mowy -> całe audio traktowane jako mowa.
  local d = tempo_math.dub_fit_plan{
    span = 3.0, audio_len = 3.0, speech_start = 1.0, speech_end = 1.0 }
  near(d.speech_len, 3.0, 1e-9, 'dub_fit: degenerate alignment -> full audio')

  -- 9. Markery monotoniczne, start zawsze (0,0).
  for _, plan in ipairs({ p, g, t, s1, o }) do
    near(plan.markers[1][1], 0, 1e-12, 'dub_fit: first marker take=0')
    near(plan.markers[1][2], 0, 1e-12, 'dub_fit: first marker src=0')
    local mono = true
    for i = 2, #plan.markers do
      if plan.markers[i][1] <= plan.markers[i-1][1]
         or plan.markers[i][2] <= plan.markers[i-1][2] then mono = false end
    end
    ok(mono, 'dub_fit: markers strictly monotonic')
  end

  -- 10. Złe inputy.
  eq(tempo_math.dub_fit_plan{ span = 0, audio_len = 3 }, nil, 'dub_fit: zero span -> nil')
  eq(tempo_math.dub_fit_plan{ span = 3, audio_len = 0 }, nil, 'dub_fit: zero audio -> nil')
  eq(tempo_math.dub_fit_plan(nil), nil, 'dub_fit: nil opts -> nil')
end

----------------------------------------------------------------------------
-- tempo_math.dub_fit_smooth — W2 M1 §2.4 anti-skok sąsiadów speakera.
----------------------------------------------------------------------------
do
  -- Symetryczny kompromis wokół średniej do Δ=0.12.
  local na, nb = tempo_math.dub_fit_smooth(0.90, 1.10, 0.88, 1.12, 0.88, 1.12)
  near(na, 0.94, 1e-9, 'dub_smooth: lower rises toward mean')
  near(nb, 1.06, 1e-9, 'dub_smooth: higher falls toward mean')
  -- Kolejność argumentów zachowana przy odwróconym wejściu.
  local xa, xb = tempo_math.dub_fit_smooth(1.10, 0.90, 0.88, 1.12, 0.88, 1.12)
  near(xa, 1.06, 1e-9, 'dub_smooth: order preserved (a stays a)')
  near(xb, 0.94, 1e-9, 'dub_smooth: order preserved (b stays b)')
  -- Δ w granicy -> nil (bez smoothingu).
  eq(tempo_math.dub_fit_smooth(1.0, 1.1, 0.88, 1.12, 0.88, 1.12), nil,
    'dub_smooth: delta within max -> nil')
  -- Bound jednej strony -> druga dociągana dalej.
  local ba, bb = tempo_math.dub_fit_smooth(0.90, 1.10, 0.88, 0.92, 0.88, 1.12)
  near(ba, 0.92, 1e-9, 'dub_smooth: bound-capped side stops at hi')
  near(bb, 1.04, 1e-9, 'dub_smooth: other side compensates to delta')
  -- Nie da się zejść do Δ w przedziałach -> nil (fit ma priorytet).
  eq(tempo_math.dub_fit_smooth(0.88, 1.12, 0.88, 0.88, 1.12, 1.12), nil,
    'dub_smooth: infeasible -> nil (keep own rates)')
end

----------------------------------------------------------------------------
-- dubbing_splicer.resolve_speech_pitchmode — W2 M2 (PHASE-W2 §3): élastique
-- Soloist:Speech po NAZWIE (sloty I_PITCHMODE wersjo-zależne). Enum zawiera
-- 2.2.8 ORAZ 3.3.3 — ostatni match wygrywa (nowsza wersja dalej w liście);
-- brak matcha -> -1 (project default); brak enum API -> hardcoded fallback.
----------------------------------------------------------------------------
do
  local splicer = require 'modules.dubbing_splicer'
  -- Realistyczna lista REAPER 7.x (skrócona); [1]=nil symuluje mode
  -- "currently unsupported" (enum zwraca true + nil name — scan nie staje).
  local names = {
    [0] = 'SoundTouch',
    [1] = nil,
    [2] = '\xC3\xA9lastique 2.2.8 Soloist',
    [3] = '\xC3\xA9lastique 3.3.3 Pro',
    [4] = '\xC3\xA9lastique 3.3.3 Soloist',
    [5] = 'Rubber Band Library',
  }
  local subs = {
    [2] = { [0] = 'Monophonic', [1] = 'Speech' },
    [4] = { [0] = 'Monophonic', [1] = 'Speech' },
  }
  local function enum_modes(m)
    if m > 5 then return false end
    return true, names[m]
  end
  local function enum_submodes(m, sm)
    return subs[m] and subs[m][sm] or nil
  end
  eq(splicer.resolve_speech_pitchmode{
       enum_modes = enum_modes, enum_submodes = enum_submodes },
     (4 << 16) | 1, 'pitchmode: newest Soloist Speech wins (last match)')
  eq(splicer.resolve_speech_pitchmode{
       enum_modes = function() return false end, enum_submodes = enum_submodes },
     -1, 'pitchmode: empty enum -> -1 (project default)')
  -- Soloist bez submodu Speech -> -1 (nie strzelamy w obcy submode).
  eq(splicer.resolve_speech_pitchmode{
       enum_modes = enum_modes,
       enum_submodes = function(m, sm)
         return subs[m] and sm == 0 and 'Monophonic' or nil
       end },
     -1, 'pitchmode: Soloist without Speech submode -> -1')
  -- Brak enum API (stare REAPER / brak w stubie) -> hardcoded fallback.
  local saved_em, saved_es = reaper.EnumPitchShiftModes, reaper.EnumPitchShiftSubModes
  reaper.EnumPitchShiftModes, reaper.EnumPitchShiftSubModes = nil, nil
  eq(splicer.resolve_speech_pitchmode{}, 0xB0002,
    'pitchmode: enum API missing -> hardcoded elastique Soloist:Speech')
  reaper.EnumPitchShiftModes, reaper.EnumPitchShiftSubModes = saved_em, saved_es
end

----------------------------------------------------------------------------
-- cast_registry — W2 M3 (PHASE-W2 §4): pure core wspólnego katalogu postaci.
----------------------------------------------------------------------------
do
  local registry = require 'modules.cast_registry'
  local stt      = require 'modules.stt'

  -- normalize_label: trim + collapse spaces + fold case (ASCII + polskie).
  eq(registry.normalize_label('  Anna  Nowak '), 'anna nowak',
    'cast: label trim + collapse + lower')
  eq(registry.normalize_label('ŻÓŁĆ'), 'żółć', 'cast: polish diacritics folded')
  eq(registry.normalize_label('ANNA'), registry.normalize_label('anna'),
    'cast: case-insensitive match key')
  eq(registry.normalize_label(nil), '', 'cast: nil label safe')

  -- geometry_key — DECYZJA M3 (2026-06-11): kanoniczny klucz materiału BEZ
  -- języka. Parity ze stt.cache_key(path, render_info bez .language) —
  -- geometry-stable diarize cache dubbingu linkuje się 1:1; klucz Repair
  -- (z '|lang=') celowo INNY niż kanoniczny.
  local gk = registry.geometry_key('/a/b.wav', 21.6, 30.0, 1.0)
  eq(gk, stt.cache_key('/a/b.wav', { item_offs = 21.6, item_length = 30.0, playrate = 1.0 }),
    'cast: geometry_key == stt geometry cache_key (no lang)')
  ok(gk ~= stt.cache_key('/a/b.wav',
       { item_offs = 21.6, item_length = 30.0, playrate = 1.0, language = 'pl' }),
    'cast: lang-ed STT key differs from canonical (by design)')
  eq(registry.geometry_key(nil), nil, 'cast: geometry_key nil path -> nil')

  -- upsert: nowa postać + merge głosów per lang + opis nie kasowany pustym.
  local reg = registry.new_registry('cast_test')
  ok(registry.is_empty(reg), 'cast: fresh registry empty')
  local ch = registry.upsert_character(reg,
    { label = 'Anna', voices = { en = { voice_id = 'v1', voice_name = 'Rachel' } },
      description = 'calm narrator', source_mode = 'dubbing' }, { now = 100 })
  eq(ch.label, 'Anna', 'cast: upsert creates character')
  eq(#reg.characters, 1, 'cast: one character after first upsert')
  eq(ch.updated_at, 100, 'cast: injected now respected')
  -- Drugi upsert po foldzie ('anna') = ta sama postać; nowy lang dochodzi,
  -- en zostaje; brak description NIE kasuje istniejącego.
  registry.upsert_character(reg,
    { label = 'anna', voices = { pl = { voice_id = 'v2', voice_name = 'Bea' } } },
    { now = 200 })
  eq(#reg.characters, 1, 'cast: folded label upsert = same character')
  eq(ch.voices.en.voice_id, 'v1', 'cast: existing lang voice preserved')
  eq(ch.voices.pl.voice_id, 'v2', 'cast: new lang voice merged')
  eq(ch.description, 'calm narrator', 'cast: empty description does not clobber')
  -- Pusty voice_id ignorowany (nie nadpisuje istniejącego głosu).
  registry.upsert_character(reg,
    { label = 'Anna', voices = { en = { voice_id = '' } } }, { now = 300 })
  eq(ch.voices.en.voice_id, 'v1', 'cast: empty voice_id ignored on merge')
  eq(registry.upsert_character(reg, { label = '  ' }), nil,
    'cast: blank label rejected')

  -- pick_voice: preferred -> default -> pierwszy alfabetycznie.
  local vid = registry.pick_voice(ch, 'pl')
  eq(vid, 'v2', 'cast: pick_voice preferred lang')
  eq(registry.pick_voice(ch, 'de'), 'v1', 'cast: no preferred -> first sorted lang (en<pl)')
  local ch2 = registry.upsert_character(reg,
    { label = 'Bob', voices = { default = { voice_id = 'vd', voice_name = 'D' } } })
  eq(registry.pick_voice(ch2, 'pl'), 'vd', 'cast: default voice fallback')
  eq(registry.pick_voice({ voices = {} }), nil, 'cast: no voices -> nil')

  eq(registry.find_character(reg, 'ANNA'), ch, 'cast: find by folded label')
  eq(registry.find_character(reg, 'nobody'), nil, 'cast: find miss -> nil')

  -- M3 cz.2: linki (geom_key, scribe_id) ↔ postać. Set sidów per materiał
  -- (diarization potrafi rozbić jedną osobę na 2 sidy) + uniqueness pary.
  local gk1 = registry.geometry_key('/a/b.wav', 0, 10, 1)
  ok(registry.link_item_speaker(reg, ch, gk1, 'speaker_0', { now = 400 }),
    'cast link: link ok')
  eq(registry.find_by_link(reg, gk1, 'speaker_0'), ch, 'cast link: find by pair')
  eq(registry.find_by_link(reg, gk1, 'speaker_1'), nil, 'cast link: miss sid -> nil')
  eq(registry.find_by_link(reg, 'deadbeef', 'speaker_0'), nil,
    'cast link: miss material -> nil')
  -- Ta sama postać, drugi sid na tym samym materiale (osoba rozbita przez
  -- diarize) — oba sidy wskazują ch.
  registry.link_item_speaker(reg, ch, gk1, 'speaker_2', { now = 401 })
  local mat = registry.characters_for_material(reg, gk1)
  eq(mat.speaker_0, ch, 'cast link: material map sid0')
  eq(mat.speaker_2, ch, 'cast link: material map sid2 (same char, split person)')
  -- Uniqueness: przeniesienie pary do innej postaci zdejmuje ją ze starej.
  registry.link_item_speaker(reg, ch2, gk1, 'speaker_0', { now = 402 })
  eq(registry.find_by_link(reg, gk1, 'speaker_0'), ch2, 'cast link: pair moved to ch2')
  eq(registry.characters_for_material(reg, gk1).speaker_2, ch,
    'cast link: other pair untouched by move')
  -- Legacy scalar shape (plan §4 zapisywał string) tolerowany przy odczycie.
  local ch3 = registry.upsert_character(reg, { label = 'Cezary' })
  ch3.links.item_diarize['feed0001'] = 'speaker_5'
  eq(registry.find_by_link(reg, 'feed0001', 'speaker_5'), ch3,
    'cast link: legacy scalar readable')
  eq(registry.characters_for_material(reg, 'feed0001').speaker_5, ch3,
    'cast link: legacy scalar in material map')
  -- unlink: para znika, pusta mapa sprzątnięta.
  ok(registry.unlink_item_speaker(reg, gk1, 'speaker_2'), 'cast unlink: ok')
  eq(registry.find_by_link(reg, gk1, 'speaker_2'), nil, 'cast unlink: pair gone')
  ok(not registry.unlink_item_speaker(reg, gk1, 'speaker_2'),
    'cast unlink: second unlink -> false')
  -- JSON round-trip setu linków (persystencja rejestru).
  do
    local js = require 'modules.lib.json'
    local rt = js.decode(js.encode(reg))
    ok(registry.find_by_link(rt, gk1, 'speaker_0') ~= nil,
      'cast link: survives JSON round-trip')
  end

  -- M3 cz.2: link_material — marker obecności postaci w materiale (dubbing;
  -- BEZ sidów — chunk-lokalna numeracja nie pokrywa się z diarize itemu).
  ok(registry.link_material(reg, ch, 'beef0002', { now = 500 }),
    'cast material: link ok')
  ok(registry.is_material_linked(ch, 'beef0002'), 'cast material: linked')
  ok(not registry.is_material_linked(ch, 'beef0003'), 'cast material: other key not linked')
  ok(not registry.link_material(reg, ch, 'beef0002', { now = 501 }),
    'cast material: re-link = no-op (false, no dirty)')
  -- item_diarize link też liczy się jako "materiał zlinkowany" (Repair).
  ok(registry.is_material_linked(ch2, gk1),
    'cast material: item_diarize link counts as material link')

  -- M3 cz.2: rename_character — relabel w miejscu + merge przy kolizji
  -- (cleanup upsert-only rejestru).
  local r2 = registry.new_registry('cast_rn')
  local sp1 = registry.upsert_character(r2, { label = 'Speaker 1' }, { now = 10 })
  registry.link_item_speaker(r2, sp1, gk1, 'speaker_0', { now = 11 })
  local surv = registry.rename_character(r2, sp1, 'Anna', { now = 12 })
  eq(surv, sp1, 'cast rename: relabel in place (no collision)')
  eq(sp1.label, 'Anna', 'cast rename: label updated')
  eq(#r2.characters, 1, 'cast rename: no duplicate created')
  eq(registry.rename_character(r2, sp1, '  '), nil, 'cast rename: blank -> nil no-op')
  eq(registry.rename_character(r2, sp1, 'ANNA', { now = 13 }), sp1,
    'cast rename: spelling variant same char')
  eq(sp1.label, 'ANNA', 'cast rename: spelling variant applied')
  -- Kolizja → merge: zwycięża istniejąca postać pod nowym labelem; jej głosy
  -- wygrywają, brakujące dokładane, linki przeniesione, duplikat usunięty.
  local anna2 = registry.upsert_character(r2,
    { label = 'Speaker 2',
      voices = { en = { voice_id = 'vB', voice_name = 'B' },
                 pl = { voice_id = 'vP', voice_name = 'P' } },
      ivc_clone_id = 'clone_sp2', description = 'old desc' }, { now = 14 })
  registry.link_item_speaker(r2, anna2, gk1, 'speaker_1', { now = 15 })
  registry.upsert_character(r2, { label = 'ANNA',
    voices = { en = { voice_id = 'vA', voice_name = 'A' } } }, { now = 16 })
  local merged = registry.rename_character(r2, anna2, 'Anna', { now = 17 })
  eq(merged, sp1, 'cast rename: collision merges into existing')
  eq(#r2.characters, 1, 'cast rename: duplicate removed after merge')
  eq(merged.voices.en.voice_id, 'vA', 'cast rename: existing lang voice wins')
  eq(merged.voices.pl.voice_id, 'vP', 'cast rename: missing lang filled from source')
  eq(merged.ivc_clone_id, 'clone_sp2', 'cast rename: empty ivc filled from source')
  eq(merged.description, 'old desc', 'cast rename: empty description filled')
  eq(registry.find_by_link(r2, gk1, 'speaker_1'), merged,
    'cast rename: links moved to survivor')
  eq(registry.find_by_link(r2, gk1, 'speaker_0'), merged,
    'cast rename: survivor keeps own links')
end

----------------------------------------------------------------------------
-- async_op — retry 429 + stale-handle detection (audit M1-2/M1-3/M2-2)
----------------------------------------------------------------------------
eq(async_op.MAX_RETRIES, 3, 'async: 3 retries')
eq(async_op.RETRY_BACKOFF[1], 1, 'async: backoff[1] = 1s')
eq(async_op.RETRY_BACKOFF[3], 4, 'async: backoff[3] = 4s')
-- Guard: stale timeout MUSI być >= 300 (curl --max-time we wszystkich
-- workers) — niżej = fałszywe timeouty ubijające joby z żywym curlem.
ok(async_op.HANDLE_STALE_TIMEOUT >= 300, 'async: stale timeout >= curl max-time (300)')

ok(async_op.is_rate_limit_error({ http_code = 429 }), 'async 429: detect via http_code')
ok(async_op.is_rate_limit_error({ error = 'HTTP 429: too many requests' }), 'async 429: detect via error text')
ok(not async_op.is_rate_limit_error({ error = 'HTTP 500: server' }), 'async 429: 500 is not rate limit')
ok(not async_op.is_rate_limit_error(nil), 'async 429: nil handle safe')

do
  local h = { http_code = 429, error = 'HTTP 429' }
  ok(async_op.schedule_retry_429(h), 'async retry: 1st scheduled')
  eq(h._retry_count, 1, 'async retry: count 1')
  ok(h._retry_at and h._retry_at > 0, 'async retry: _retry_at set')
  ok(async_op.schedule_retry_429(h), 'async retry: 2nd scheduled')
  ok(async_op.schedule_retry_429(h), 'async retry: 3rd scheduled')
  ok(not async_op.schedule_retry_429(h), 'async retry: 4th refused (budget exhausted)')
  ok(not async_op.schedule_retry_429({ http_code = 500 }), 'async retry: non-429 refused')
end

do
  local now = reaper.time_precise()
  local fresh = { status = 'running', started_at = now }
  ok(not async_op.force_error_if_stale(fresh, 'x'), 'async stale: fresh handle not killed')
  eq(fresh.status, 'running', 'async stale: fresh stays running')

  local dead = { status = 'running', started_at = now - (async_op.HANDLE_STALE_TIMEOUT + 10) }
  ok(async_op.force_error_if_stale(dead, 'TTS'), 'async stale: dead worker detected')
  eq(dead.status, 'error', 'async stale: status forced to error')
  ok(tostring(dead.error):find('TTS', 1, true) ~= nil, 'async stale: label in error message')

  local done_h = { status = 'done', started_at = now - 9999 }
  ok(not async_op.force_error_if_stale(done_h, 'x'), 'async stale: done handle untouched')

  -- Handles bez started_at (forced_align/stt/isolator): self-stamping
  local nostamp = { status = 'running' }
  ok(not async_op.force_error_if_stale(nostamp, 'x'), 'async stale: first poll stamps, no kill')
  ok(nostamp._stale_t0 ~= nil, 'async stale: _stale_t0 stamped')
  nostamp._stale_t0 = now - (async_op.HANDLE_STALE_TIMEOUT + 1)
  ok(async_op.force_error_if_stale(nostamp, 'x'), 'async stale: stamped handle times out')

  -- stt.poll_transcribe używa status='pending' dla in-flight — też objęty
  local pending_h = { status = 'pending', started_at = now - (async_op.HANDLE_STALE_TIMEOUT + 5) }
  ok(async_op.force_error_if_stale(pending_h, 'STT'), "async stale: 'pending' status (stt) covered")
end

----------------------------------------------------------------------------
-- async_op — diagnostyka curl + formatowanie błędów HTTP (M2-1)
----------------------------------------------------------------------------
ok(async_op.curl_exit_hint(28):find('timeout', 1, true) ~= nil, 'curl hint: 28 = timeout')
ok(async_op.curl_exit_hint(6):find('DNS', 1, true) ~= nil, 'curl hint: 6 = DNS')
eq(async_op.curl_exit_hint(0), '', 'curl hint: 0 = clean (no hint)')
ok(async_op.curl_exit_hint(99):find('99', 1, true) ~= nil, 'curl hint: unknown code echoed')

do
  -- JSON detail path (ElevenLabs error shape)
  local sent = { http_code = 401, curl_exit = 0, stderr = '' }
  local msg = async_op.format_http_error(nil, sent, '{"detail":{"message":"invalid api key"}}')
  eq(msg, 'HTTP 401: invalid api key', 'http error: JSON detail extracted')

  local msg2 = async_op.format_http_error('forced-align', sent, '{"detail":"bad request"}')
  eq(msg2, 'HTTP 401 (forced-align): bad request', 'http error: label + string detail')

  -- Transport path (HTTP 0, curl exit 7, stderr)
  local tsent = { http_code = 0, curl_exit = 7, stderr = '  curl: (7) Failed to connect  ' }
  local tmsg = async_op.format_http_error(nil, tsent, '')
  ok(tmsg:find('could not connect', 1, true) ~= nil, 'http error: transport hint present')
  ok(tmsg:find('Failed to connect', 1, true) ~= nil, 'http error: stderr included (trimmed)')
end

do
  -- read_sentinel: round-trip na realnych plikach tmp + cleanup verification
  local base = os.tmpname()
  util.write_file(base, '429\n')
  util.write_file(base .. '.stderr', 'some warning')
  util.write_file(base .. '.curl_exit', '22')
  local sent = async_op.read_sentinel({ sentinel_path = base })
  eq(sent.http_code, 429, 'read_sentinel: http code parsed')
  eq(sent.curl_exit, 22, 'read_sentinel: curl exit parsed')
  eq(sent.stderr, 'some warning', 'read_sentinel: stderr read')
  ok(not util.file_exists(base), 'read_sentinel: sentinel removed')
  ok(not util.file_exists(base .. '.stderr'), 'read_sentinel: stderr removed')
  ok(not util.file_exists(base .. '.curl_exit'), 'read_sentinel: curl_exit removed')
end

----------------------------------------------------------------------------
-- housekeeping.sweep_tmp_orphans — kasuje TYLKO stare artefakty jobów
----------------------------------------------------------------------------
do
  local housekeeping = require 'modules.housekeeping'
  local tmp = '/tmp/reasonate-test-resource/Scripts/reasonate_tmp'
  os.execute(("rm -rf '%s' && mkdir -p '%s'"):format(tmp, tmp))

  local now = os.time()
  local old_ts  = now - 8 * 24 * 3600   -- 8 dni — powyżej progu 7 dni
  local old_hex = ('%x'):format(old_ts)
  local now_hex = ('%x'):format(now)

  local kill_sentinel = tmp .. '/stt_' .. old_hex .. '_abc123.done'
  local kill_output   = tmp .. '/align_' .. old_hex .. '_def456.json'
  local keep_fresh    = tmp .. '/stt_' .. now_hex .. '_abc123.done'
  local keep_cache    = tmp .. '/stt_a1b2c3d4.json'        -- cache (1 grupa hex)
  local keep_iso      = tmp .. '/isolated_deadbeef.mp3'    -- cache audio
  local keep_key      = tmp .. '/.reasonate_key'           -- dotfile
  for _, p in ipairs({ kill_sentinel, kill_output, keep_fresh, keep_cache, keep_iso, keep_key }) do
    util.write_file(p, 'x')
  end

  local removed = housekeeping.sweep_tmp_orphans(now)
  eq(removed, 2, 'sweep: removes exactly 2 old job artifacts')
  ok(not util.file_exists(kill_sentinel), 'sweep: old sentinel gone')
  ok(not util.file_exists(kill_output), 'sweep: old align output gone')
  ok(util.file_exists(keep_fresh), 'sweep: fresh sentinel kept')
  ok(util.file_exists(keep_cache), 'sweep: stt cache kept (single hex group)')
  ok(util.file_exists(keep_iso), 'sweep: isolated cache kept (mp3 not in whitelist)')
  ok(util.file_exists(keep_key), 'sweep: key dotfile kept')
end

----------------------------------------------------------------------------
-- cache.evict_to_cap — LRU approx przez sidecar index
----------------------------------------------------------------------------
do
  local cdir = '/tmp/reasonate-test-resource/Scripts/reasonate_cache'
  os.execute(("rm -rf '%s' && mkdir -p '%s'"):format(cdir, cdir))
  util.write_file(cdir .. '/aaa.mp3', string.rep('x', 1000))
  util.write_file(cdir .. '/bbb.mp3', string.rep('x', 1000))
  util.write_file(cdir .. '/ccc.mp3', string.rep('x', 1000))
  -- Index: aaa najstarsze, ccc najświeższe (zapis PRZED pierwszym load_index)
  util.write_file(cdir .. '/cache_index.json',
    json.encode({ aaa = 100, bbb = 200, ccc = 300 }))

  eq(cache.evict_to_cap(0), 0, 'evict: cap 0 = unlimited, no eviction')
  eq(cache.evict_to_cap(10000), 0, 'evict: under cap = no eviction')
  local evicted = cache.evict_to_cap(2500)
  eq(evicted, 1, 'evict: one file evicted to fit 2500B cap')
  ok(not util.file_exists(cdir .. '/aaa.mp3'), 'evict: oldest-used evicted first')
  ok(util.file_exists(cdir .. '/ccc.mp3'), 'evict: newest kept')
end

----------------------------------------------------------------------------
-- forced_align.sanitize_text — markup TTS nie jest wypowiadany (2026-06-10)
----------------------------------------------------------------------------
do
  local fa = require 'modules.forced_align'
  eq(fa.sanitize_text('Hello <break time="1.0s" /> world'), 'Hello world',
    'sanitize: break tag stripped')
  eq(fa.sanitize_text('<break time="0.5s"/>Start'), 'Start',
    'sanitize: leading break stripped')
  eq(fa.sanitize_text('[whispers] secret [long pause] end'), 'secret end',
    'sanitize: audio tags stripped')
  eq(fa.sanitize_text('Wait... what?'), 'Wait... what?',
    'sanitize: ellipsis preserved (spoken punctuation)')
  eq(fa.sanitize_text('plain text'), 'plain text', 'sanitize: plain text untouched')
  eq(fa.sanitize_text('  spaced   out  '), 'spaced out', 'sanitize: whitespace collapsed')
  eq(fa.sanitize_text('[whispers]'), '', 'sanitize: markup-only → empty string')
end

----------------------------------------------------------------------------
-- llm.translate_cache_key — PROMPT_VERSION fold (2026-06-10)
----------------------------------------------------------------------------
do
  local llm = require 'modules.llm'
  ok(type(llm.PROMPT_VERSION) == 'number' and llm.PROMPT_VERSION >= 2,
    'llm: PROMPT_VERSION present (>=2)')
  local key1 = llm.translate_cache_key({ source_text = 'abc', target_lang = 'pl' })
  eq(key1, llm.translate_cache_key({ source_text = 'abc', target_lang = 'pl' }),
    'translate_cache_key: deterministic')
  local saved = llm.PROMPT_VERSION
  llm.PROMPT_VERSION = saved + 1
  ok(llm.translate_cache_key({ source_text = 'abc', target_lang = 'pl' }) ~= key1,
    'translate_cache_key: PROMPT_VERSION bump changes key')
  llm.PROMPT_VERSION = saved
end

----------------------------------------------------------------------------
-- dubbing_project.STYLE_PRESETS — schema guard (rozbudowa 2026-06-10).
-- Enum values MUSZĄ mieścić się w opcjach dropdownów dubbing_context.lua.
----------------------------------------------------------------------------
do
  local dp = require 'modules.dubbing_project'
  local TONES = { neutral=1, formal=1, informal=1, conversational=1, dramatic=1 }
  local ERAS  = { modern=1, classical=1, period=1, scifi=1, fantasy=1, historical=1 }
  local AUDS  = { kids=1, teen=1, adult=1, mixed=1, professional=1 }
  local MEDIA = { drama_film=1, documentary=1, podcast=1, animation=1, training=1,
                  commercial=1, audiobook=1, game=1 }
  local HONS  = { formal=1, informal=1, mix=1 }
  ok(#dp.STYLE_PRESET_ORDER >= 12, 'presets: ORDER lists >= 12 entries')
  local all_ok = true
  for _, key in ipairs(dp.STYLE_PRESET_ORDER) do
    local p = dp.STYLE_PRESETS[key]
    if not (p and type(p.label) == 'string' and type(p.brief) == 'string'
            and TONES[p.tone] and ERAS[p.era] and AUDS[p.audience]
            and MEDIA[p.media_type] and HONS[p.honorific]) then
      all_ok = false
      record(false, 'preset schema invalid: ' .. key)
    end
  end
  ok(all_ok, 'presets: all ORDER entries valid (label+brief+enum fields)')
  ok(dp.STYLE_PRESETS.podcast_scifi ~= nil, 'presets: legacy podcast_scifi resolvable')
  ok(dp.is_stock_style_text(''), 'is_stock_style_text: empty = stock')
  ok(dp.is_stock_style_text(dp.STYLE_PRESETS.comedy.brief),
    'is_stock_style_text: known brief = stock')
  ok(not dp.is_stock_style_text('my own notes'), 'is_stock_style_text: user text detected')
end

----------------------------------------------------------------------------
-- util.soft_wrap_text / normalize_whitespace (2026-06-10 — moved z
-- dubbing_panel do util; konsumenci: dubbing inline edit + dialogue lines)
----------------------------------------------------------------------------
do
  eq(util.soft_wrap_text('', 10), '', 'soft_wrap: empty input')
  eq(util.soft_wrap_text('aa bb cc', 5), 'aa bb\ncc', 'soft_wrap: breaks at word boundary')
  eq(util.soft_wrap_text('aa bb cc', 80), 'aa bb cc', 'soft_wrap: short text untouched')
  eq(util.soft_wrap_text('p1 p1\np2', 80), 'p1 p1\np2', 'soft_wrap: existing newline preserved')
  eq(util.normalize_whitespace('  a\n b\t c  '), 'a b c', 'normalize: collapse + trim')
  eq(util.normalize_whitespace(nil), '', 'normalize: nil → empty')
  local txt = 'to jest test test test to jest test'
  eq(util.normalize_whitespace(util.soft_wrap_text(txt, 10)), txt,
    'wrap → normalize roundtrip = identity')
end

----------------------------------------------------------------------------
-- NS-SFX (2026-06-10): voice_admin.sfx_cache_path_for — determinism + folds
----------------------------------------------------------------------------
do
  local va = require 'modules.voice_admin'
  local base = { text = 'glass shattering', duration_seconds = 3, prompt_influence = 0.3,
                 loop = false, variant_n = 1 }
  local k1 = va.sfx_cache_path_for(base)
  eq(k1, va.sfx_cache_path_for(base), 'sfx cache: deterministic')
  ok(k1 ~= va.sfx_cache_path_for({ text = 'glass shattering', duration_seconds = 3,
      prompt_influence = 0.3, loop = false, variant_n = 2 }),
    'sfx cache: variant_n changes key')
  ok(k1 ~= va.sfx_cache_path_for({ text = 'glass shattering', duration_seconds = 5,
      prompt_influence = 0.3, loop = false, variant_n = 1 }),
    'sfx cache: duration changes key')
  ok(k1 ~= va.sfx_cache_path_for({ text = 'glass shattering', duration_seconds = 3,
      prompt_influence = 0.3, loop = true, variant_n = 1 }),
    'sfx cache: loop changes key')
  ok(k1:find('sfx_', 1, true) ~= nil, 'sfx cache: filename prefix sfx_')
end

----------------------------------------------------------------------------
-- NS-MUSIC (2026-06-10): voice_admin.music_cache_path_for — determinism + folds
----------------------------------------------------------------------------
do
  local va = require 'modules.voice_admin'
  local base = { text = 'lo-fi chill beat, 70 BPM', duration_seconds = 60,
                 instrumental = true, variant_n = 1 }
  local k1 = va.music_cache_path_for(base)
  eq(k1, va.music_cache_path_for(base), 'music cache: deterministic')
  ok(k1 ~= va.music_cache_path_for({ text = 'lo-fi chill beat, 70 BPM', duration_seconds = 60,
      instrumental = true, variant_n = 2 }),
    'music cache: variant_n changes key')
  ok(k1 ~= va.music_cache_path_for({ text = 'lo-fi chill beat, 70 BPM', duration_seconds = 120,
      instrumental = true, variant_n = 1 }),
    'music cache: duration changes key')
  ok(k1 ~= va.music_cache_path_for({ text = 'lo-fi chill beat, 70 BPM', duration_seconds = 60,
      instrumental = false, variant_n = 1 }),
    'music cache: instrumental changes key')
  ok(k1 ~= va.music_cache_path_for({ text = 'lo-fi chill beat, 70 BPM',
      instrumental = true, variant_n = 1 }),
    'music cache: auto (nil) duration differs from explicit')
  eq(va.music_cache_path_for({ text = 'x', variant_n = 1 }),
     va.music_cache_path_for({ text = 'x', instrumental = true, variant_n = 1 }),
    'music cache: default instrumental=true folds same as explicit')
  ok(k1:find('music_', 1, true) ~= nil, 'music cache: filename prefix music_')
  ok(k1 ~= va.sfx_cache_path_for(base), 'music cache: distinct from sfx namespace')
end

----------------------------------------------------------------------------
-- NS-SFX: LLM adapter generalizacja — build_body z opts.task + raw parse
----------------------------------------------------------------------------
do
  local llm       = require 'modules.llm'
  local anthropic = require 'modules.llm.anthropic'
  local openai    = require 'modules.llm.openai'
  local gemini    = require 'modules.llm.gemini'
  local deepseek  = require 'modules.llm.deepseek'

  local CUSTOM = {
    name = 'emit_test', description = 'test tool',
    schema = { type = 'object', properties = { foo = { type = 'string' } }, required = { 'foo' } },
  }

  -- anthropic: tool z task; translate default niezmieniony
  local b = anthropic.build_body({ task = llm.TASK_TRANSLATE, user_prompt = 'x' })
  eq(b.tools[1].name, 'emit_translation', 'anthropic: translate tool name preserved')
  eq(b.tool_choice.name, 'emit_translation', 'anthropic: translate tool_choice preserved')
  b = anthropic.build_body({ task = CUSTOM, user_prompt = 'x' })
  eq(b.tools[1].name, 'emit_test', 'anthropic: custom task tool name')

  -- anthropic parse → raw {data, usage}
  local out, perr = anthropic.parse_success({
    content = { { type = 'tool_use', input = { foo = 'bar' } } },
    usage   = { input_tokens = 5 },
  })
  ok(out and out.data and out.data.foo == 'bar', 'anthropic: parse returns raw data, err=' .. tostring(perr))
  eq(out.usage.input_tokens, 5, 'anthropic: parse returns usage')

  -- openai: translate strict z openai_schema; custom fallback strict=false
  b = openai.build_body({ task = llm.TASK_TRANSLATE, user_prompt = 'x' })
  eq(b.response_format.json_schema.name, 'translation_result', 'openai: translate schema name preserved')
  eq(b.response_format.json_schema.strict, true, 'openai: translate strict preserved')
  b = openai.build_body({ task = CUSTOM, user_prompt = 'x' })
  eq(b.response_format.json_schema.name, 'emit_test', 'openai: custom fallback name')
  eq(b.response_format.json_schema.strict, false, 'openai: custom fallback strict=false')

  -- gemini: responseSchema = task.schema
  b = gemini.build_body({ task = CUSTOM, user_prompt = 'x' })
  eq(b.generationConfig.responseSchema, CUSTOM.schema, 'gemini: responseSchema = task.schema')

  -- deepseek: instrukcja per task (translate ma swoją, custom dostaje generic)
  b = deepseek.build_body({ task = llm.TASK_TRANSLATE, system_prompt = 'SYS', user_prompt = 'x' })
  ok(b.messages[1].content:find('"translation"', 1, true) ~= nil, 'deepseek: translate instruction embedded')
  b = deepseek.build_body({ task = CUSTOM, system_prompt = 'SYS', user_prompt = 'x' })
  ok(b.messages[1].content:find('OUTPUT FORMAT', 1, true) ~= nil, 'deepseek: generic instruction fallback')

  -- W2 s6: anthropic temperature gate — Opus 4.7/4.8 i Fable/Mythos ODRZUCAJĄ
  -- sampling params (HTTP 400, verified oficjalna referencja 2026-06-11);
  -- Sonnet/Haiku/starsze akceptują. Regression guard na martwy "Opus premium".
  b = anthropic.build_body({ task = CUSTOM, user_prompt = 'x' })
  near(b.temperature, 0.7, 1e-9, 'anthropic: default sonnet keeps temperature')
  b = anthropic.build_body({ task = CUSTOM, user_prompt = 'x', model = 'claude-haiku-4-5' })
  near(b.temperature, 0.7, 1e-9, 'anthropic: haiku keeps temperature')
  b = anthropic.build_body({ task = CUSTOM, user_prompt = 'x', model = 'claude-opus-4-8' })
  ok(b.temperature == nil, 'anthropic: opus-4-8 omits temperature (sampling removed)')
  b = anthropic.build_body({ task = CUSTOM, user_prompt = 'x', model = 'claude-opus-4-7' })
  ok(b.temperature == nil, 'anthropic: opus-4-7 omits temperature (sampling removed)')
  b = anthropic.build_body({ task = CUSTOM, user_prompt = 'x', model = 'claude-fable-5' })
  ok(b.temperature == nil, 'anthropic: fable omits temperature (sampling removed)')

  -- W2 s6: openai NIE wysyła temperature (reasoning warianty GPT-5.x
  -- odrzucają parametr — wsparcie per model nieprzewidywalne).
  b = openai.build_body({ task = CUSTOM, user_prompt = 'x' })
  ok(b.temperature == nil, 'openai: temperature omitted (reasoning-safe)')
  ok(b.max_completion_tokens ~= nil, 'openai: uses max_completion_tokens')

  -- W2 s6: grok — OpenAI-compatible + json_schema strict (verified docs.x.ai)
  local grok = require 'modules.llm.grok'
  b = grok.build_body({ task = llm.TASK_TRANSLATE, system_prompt = 'SYS', user_prompt = 'x' })
  eq(b.model, 'grok-4.3', 'grok: default model')
  eq(b.response_format.type, 'json_schema', 'grok: response_format json_schema')
  eq(b.response_format.json_schema.name, 'translation_result', 'grok: reuses openai_schema')
  eq(b.response_format.json_schema.strict, true, 'grok: strict from openai_schema')
  ok(b.max_tokens ~= nil and b.max_completion_tokens == nil, 'grok: classic max_tokens param')
  ok(b.temperature == nil, 'grok: temperature omitted (reasoning-safe)')
  local gout, gerr = grok.parse_success({
    choices = { { message = { content = '{"foo":"bar"}' } } },
    usage   = { prompt_tokens = 3 },
  })
  ok(gout and gout.data and gout.data.foo == 'bar', 'grok: parse returns raw data, err=' .. tostring(gerr))
  ok(grok.parse_success({ choices = {} }) == nil, 'grok: empty choices rejected')
  ok(grok.format_error(400, { error = 'plain string error' }):find('plain string', 1, true) ~= nil,
    'grok: string-shaped error formatted')

  -- W2 s6: mistral — json_schema {name, schema} DOKŁADNIE jak oficjalny
  -- przykład (bez 'strict'); temperature wspierane → wysyłane.
  local mistral = require 'modules.llm.mistral'
  b = mistral.build_body({ task = CUSTOM, system_prompt = 'SYS', user_prompt = 'x' })
  eq(b.model, 'mistral-medium-latest', 'mistral: default model')
  eq(b.response_format.type, 'json_schema', 'mistral: response_format json_schema')
  eq(b.response_format.json_schema.name, 'emit_test', 'mistral: schema name = task name')
  eq(b.response_format.json_schema.schema, CUSTOM.schema, 'mistral: schema = canonical task.schema')
  ok(b.response_format.json_schema.strict == nil, 'mistral: no strict field (matches documented wire)')
  near(b.temperature, 0.7, 1e-9, 'mistral: temperature supported and sent')
  local mout, merr = mistral.parse_success({
    choices = { { message = { content = '{"foo":"baz"}' } } },
    usage   = { prompt_tokens = 2 },
  })
  ok(mout and mout.data and mout.data.foo == 'baz', 'mistral: parse returns raw data, err=' .. tostring(merr))
  ok(mistral.format_error(422, { message = 'bad schema', type = 'invalid_request' })
    :find('bad schema', 1, true) ~= nil, 'mistral: message-shaped error formatted')

  -- W2 s6: nowi providerzy zarejestrowani end-to-end (priorytet + default + adapter)
  local cfg_t = require 'modules.config'
  eq(cfg_t.LLM_PROVIDERS_PRIORITY[5], 'grok', 'config: grok appended to priority')
  eq(cfg_t.LLM_PROVIDERS_PRIORITY[6], 'mistral', 'config: mistral appended to priority')
  eq(cfg_t.LLM_DEFAULT_MODELS.grok, 'grok-4.3', 'config: grok default model')
  eq(cfg_t.LLM_DEFAULT_MODELS.mistral, 'mistral-medium-latest', 'config: mistral default model')
end

----------------------------------------------------------------------------
-- NS-SFX: modes/sfx.validate_sfx_candidates (pure)
----------------------------------------------------------------------------
do
  local sfx = require 'modules.modes.sfx'
  local cands, cerr = sfx.validate_sfx_candidates({ candidates = {
    { prompt = 'rain on tin roof', duration_seconds = 12, starts_at_seconds = 0,
      kind = 'ambience', loop = true, why = 'rain' },
    { prompt = 'door slam', duration_seconds = 99, starts_at_seconds = 55, kind = 'one_shot' },
    { prompt = 'owl call', duration_seconds = 2, starts_at_seconds = -3, kind = 'one_shot' },
    { prompt = '' },   -- invalid → dropped
  } }, 20)
  ok(cands ~= nil, 'sfx candidates: valid input accepted, err=' .. tostring(cerr))
  eq(#cands, 3, 'sfx candidates: invalid entry dropped')
  eq(cands[1].loop, true, 'sfx candidates: ambience loop preserved')
  eq(cands[1].starts_at, 0, 'sfx candidates: bed starts at 0')
  eq(cands[2].duration_seconds, 30, 'sfx candidates: duration clamped to 30')
  eq(cands[2].starts_at, 20, 'sfx candidates: starts_at clamped to fragment length')
  eq(cands[2].kind, 'one_shot', 'sfx candidates: kind defaulted')
  ok(not cands[2].loop, 'sfx candidates: one_shot never loops')
  eq(cands[3].starts_at, 0, 'sfx candidates: negative starts_at clamped to 0')
  local nilres, err2 = sfx.validate_sfx_candidates({ candidates = {} })
  ok(nilres == nil and err2 ~= nil, 'sfx candidates: empty list rejected')
  ok(sfx.validate_sfx_candidates(nil) == nil, 'sfx candidates: nil input rejected')
end

----------------------------------------------------------------------------
-- NS-MUSIC: validate_sfx_candidates — kind=music (clampy, max 1, instrumental)
----------------------------------------------------------------------------
do
  local sfx = require 'modules.modes.sfx'
  local cands, cerr = sfx.validate_sfx_candidates({ candidates = {
    { prompt = 'tense underscore, sparse piano, in D minor', duration_seconds = 90,
      starts_at_seconds = 0, kind = 'music', loop = true, why = 'mood' },
    { prompt = 'door slam', duration_seconds = 2, starts_at_seconds = 5, kind = 'one_shot' },
    { prompt = 'second bed — should be dropped', duration_seconds = 30,
      starts_at_seconds = 0, kind = 'music' },
  } }, 120)
  ok(cands ~= nil, 'music candidates: accepted, err=' .. tostring(cerr))
  eq(cands[1].kind, 'music', 'music candidates: kind preserved')
  eq(cands[1].duration_seconds, 90, 'music candidates: duration >30 s allowed (no SFX cap)')
  ok(not cands[1].loop, 'music candidates: loop forced false (music engine cannot loop)')
  eq(cands[1].instrumental, true, 'music candidates: scene beds always instrumental')
  ok(cands[2].instrumental == nil, 'music candidates: sfx entries carry no instrumental flag')
  ok(not cands[2].loop, 'music candidates: one_shot never loops')
  eq(#cands, 2, 'music candidates: 2nd music bed dropped (max 1 per analysis)')

  -- Clamp krótkiej muzyki do MUSIC_DUR_MIN (osobne wywołanie — max-1 nie przeszkadza)
  local c2 = sfx.validate_sfx_candidates({ candidates = {
    { prompt = 'ambient pad', duration_seconds = 1, starts_at_seconds = 0, kind = 'music' },
  } }, 120)
  eq(c2[1].duration_seconds, sfx.MUSIC_DUR_MIN,
    'music candidates: short music clamped to MUSIC_DUR_MIN')
  eq(c2[1].duration_seconds, 3, 'music candidates: MUSIC_DUR_MIN = 3 s (API floor)')

  -- T9 (UX-POLISH): placement intro/at/outro + fills_scene (czołówki i
  -- realny czas — user 2026-07-11: "utwór ma wypełnić scenę i wybrzmieć").
  local c3 = sfx.validate_sfx_candidates({ candidates = {
    { prompt = 'podcast opening theme, upbeat, clean outro', duration_seconds = 12,
      starts_at_seconds = 7, kind = 'music', placement = 'intro' },
    { prompt = 'warm underscore bed', duration_seconds = 20,
      starts_at_seconds = 0, kind = 'music', placement = 'at', fills_scene = true },
    { prompt = 'closing sting', duration_seconds = 8,
      starts_at_seconds = 0, kind = 'music', placement = 'outro' },
    { prompt = 'rain bed', duration_seconds = 20, starts_at_seconds = 0,
      kind = 'ambience', loop = true, fills_scene = true },
  } }, 120)
  eq(c3[1].placement, 'intro', 'T9: intro placement preserved')
  eq(c3[1].starts_at, 0, 'T9: starts_at zeroed for intro (ignored)')
  eq(c3[2].placement, 'at', 'T9: at placement preserved')
  eq(c3[2].duration_seconds, 120 + sfx.FILL_SCENE_TAIL_SECS,
    'T9: fills_scene music bumped to scene length + tail')
  eq(c3[3].placement, 'outro', 'T9: outro allowed as 2nd+ music (different placement)')
  eq(#c3, 4, 'T9: 3 music (intro+bed+outro) + ambience all kept')
  eq(c3[4].duration_seconds, 20,
    'T9: fills_scene ambience NOT bumped (loop covers the scene, 30 s cap stays)')
  local c3b = sfx.validate_sfx_candidates({ candidates = {
    { prompt = 'weird place', duration_seconds = 2, starts_at_seconds = 3,
      kind = 'one_shot', placement = 'sideways' },
  } }, 120)
  eq(c3b[1].placement, 'at', 'T9: unknown placement defaults to at')

  -- T9: drugi music w TYM SAMYM placemencie = drop (max 1 per placement).
  local c4 = sfx.validate_sfx_candidates({ candidates = {
    { prompt = 'bed A', duration_seconds = 30, starts_at_seconds = 0,
      kind = 'music', placement = 'at' },
    { prompt = 'bed B', duration_seconds = 30, starts_at_seconds = 0,
      kind = 'music', placement = 'at' },
  } }, 60)
  eq(#c4, 1, 'T9: second music in the SAME placement dropped')

  -- T9: fills_scene nie przekracza MUSIC_DUR_MAX.
  local c5 = sfx.validate_sfx_candidates({ candidates = {
    { prompt = 'epic bed', duration_seconds = 30, starts_at_seconds = 0,
      kind = 'music', placement = 'at', fills_scene = true },
  } }, 900)
  eq(c5[1].duration_seconds, sfx.MUSIC_DUR_MAX,
    'T9: fills_scene capped at MUSIC_DUR_MAX')

  -- T9b (user-caught: bed wypchnięty przez limit 4): cap podniesiony do 6 —
  -- pełna oprawa (opener+bed+outro+ambience+2 akcenty) mieści się; 7. drop.
  eq(sfx.MAX_CANDIDATES, 10, 'T9c: MAX_CANDIDATES = 10 (rich audio-drama scenes)')
  local pkg = { candidates = {} }
  for n = 1, 11 do
    pkg.candidates[n] = { prompt = 'fx ' .. n, duration_seconds = 2,
                          starts_at_seconds = n, kind = 'one_shot' }
  end
  local c6 = sfx.validate_sfx_candidates(pkg, 60)
  eq(#c6, 10, 'T9c: 11th candidate dropped at the cap')
end

----------------------------------------------------------------------------
-- NS-MUSIC: modes/sfx.apply_rephrase (pure) — podmiana promptu kandydata
----------------------------------------------------------------------------
do
  local sfx = require 'modules.modes.sfx'
  local cand = { prompt = 'old door creak', kind = 'one_shot',
                 duration_seconds = 3, starts_at = 6.5, why = 'door opens',
                 gen_count = 2 }
  local applied = sfx.apply_rephrase(cand, { prompt = 'rusty hinge groan, sharp', duration_seconds = 99 })
  ok(applied, 'rephrase: applied')
  eq(cand.prompt, 'rusty hinge groan, sharp', 'rephrase: prompt replaced')
  eq(cand.prompt_history[1], 'old door creak', 'rephrase: old prompt kept in history')
  eq(cand.duration_seconds, 30, 'rephrase: duration clamped to SFX cap')
  eq(cand.starts_at, 6.5, 'rephrase: position untouched')
  eq(cand.kind, 'one_shot', 'rephrase: kind untouched')
  ok(cand.gen_count == nil, 'rephrase: generated marker reset (new idea not generated yet)')

  cand.gen_count = 1
  local failed, ferr = sfx.apply_rephrase(cand, { prompt = '' })
  ok(failed == false and ferr ~= nil, 'rephrase: empty prompt rejected')
  eq(cand.prompt, 'rusty hinge groan, sharp', 'rephrase: prompt unchanged after reject')
  eq(#cand.prompt_history, 1, 'rephrase: history unchanged after reject')
  eq(cand.gen_count, 1, 'rephrase: generated marker kept after reject')

  -- Drugi rephrase: history rośnie chronologicznie
  sfx.apply_rephrase(cand, { prompt = 'iron gate squeal, metallic' })
  eq(#cand.prompt_history, 2, 'rephrase: history grows per rephrase')
  eq(cand.prompt_history[2], 'rusty hinge groan, sharp', 'rephrase: history chronological')
  eq(cand.duration_seconds, 30, 'rephrase: duration kept when LLM omits it')

  -- Music: clamp dolny per kind
  local mc = { prompt = 'pad', kind = 'music', duration_seconds = 60, why = '' }
  sfx.apply_rephrase(mc, { prompt = 'warm analog pad, slow swells', duration_seconds = 1 })
  eq(mc.duration_seconds, 3, 'rephrase: music duration clamped to MUSIC_DUR_MIN')
end

----------------------------------------------------------------------------
-- activity.collect (Pakiet A, W3 2026-06-10 — pasek aktywności w stopce)
----------------------------------------------------------------------------
do
  local activity = require 'modules.activity'

  local function find(acts, id)
    for _, a in ipairs(acts) do if a.id == id then return a end end
    return nil
  end

  eq(#activity.collect(nil), 0, 'activity: nil state → empty')
  eq(#activity.collect({ modes = {} }, {}), 0, 'activity: idle state → empty')

  -- VR batch convert przez deps (job_manager reaper-zależny — wstrzyknięty)
  local acts = activity.collect({ modes = {} },
    { job_stats = { total = 5, done = 2, error = 1 } })
  local vr = find(acts, 'vr_batch')
  ok(vr ~= nil, 'activity: batch convert visible')
  eq(vr and vr.done, 3, 'activity: batch done = done+error+cancelled')
  eq(vr and vr.total, 5, 'activity: batch total')

  -- Recording timer
  acts = activity.collect({ modes = {} }, { recording = { elapsed = 83 } })
  local rec = find(acts, 'rec')
  eq(rec and rec.label, 'REC 1:23', 'activity: recording timer label')
  eq(rec and rec.kind, 'record', 'activity: recording kind')
  acts = activity.collect({ modes = {} }, { recording = { elapsed = 0, pre_roll = true } })
  rec = find(acts, 'rec')
  eq(rec and rec.label, 'REC · pre-roll', 'activity: pre-roll label')

  -- TTS: single gen + variants + regen map
  acts = activity.collect({ modes = { tts = {
    gen_handle = { status = 'running' }, variants_remaining = 2,
    row_handles = { g1 = { status = 'running' } },
  } } })
  local gen = find(acts, 'tts_gen')
  ok(gen and gen.label:find('2 left', 1, true) ~= nil, 'activity: tts variants count in label')
  ok(find(acts, 'tts_regen') ~= nil, 'activity: tts regen map counted')

  -- Dubbing: translate i/n (excluded pomijany) + failed → error chip z retry
  acts = activity.collect({ modes = { dubbing = {
    phase = 'ready',
    translate_pending = true,
    translate_handles = {}, tts_handles = {}, align_handles = {},
    project = {
      active_target_language = 'en',
      segments = {
        { id = 's1', translation_status = { en = 'translated' },
          translations = { en = 'hi' }, dub_status = { en = 'pending' } },
        { id = 's2', translation_status = { en = 'pending' } },
        { id = 's3', dub_excluded = true, translation_status = { en = 'pending' } },
        { id = 's4', translation_status = { en = 'failed' },
          translation_error = { en = 'HTTP 403' } },
      },
    },
  } } })
  local tr = find(acts, 'dub_translate')
  ok(tr ~= nil, 'activity: dubbing translating visible')
  eq(tr and tr.done, 1, 'activity: translate done count')
  eq(tr and tr.total, 3, 'activity: translate total skips excluded')
  local fail = find(acts, 'dub_failed')
  ok(fail ~= nil and fail.kind == 'error', 'activity: failed translations → error chip')
  ok(fail and fail.label:find('1 translation failed', 1, true) ~= nil,
    'activity: failed count in label')
  ok(fail and type(fail.retry) == 'function', 'activity: error chip has retry')
  ok(fail and fail.tooltip and fail.tooltip:find('s4', 1, true) ~= nil,
    'activity: tooltip cites segment id')
  ok(fail and fail.tooltip and fail.tooltip:find('HTTP 403', 1, true) ~= nil,
    'activity: tooltip cites stored reason')

  -- Dubbing: failed dub generation → error chip z retry (W3 Pakiet B+)
  acts = activity.collect({ modes = { dubbing = {
    phase = 'ready',
    translate_handles = {}, tts_handles = {}, align_handles = {},
    project = {
      active_target_language = 'en',
      segments = {
        { id = 'd1', translation_status = { en = 'translated' },
          translations = { en = 'hello' }, dub_status = { en = 'generated' } },
        { id = 'd2', translation_status = { en = 'translated' },
          translations = { en = 'world' }, dub_status = { en = 'failed' },
          dub_error = { en = 'TTS: HTTP 400' } },
      },
    },
  } } })
  local dfail = find(acts, 'dub_gen_failed')
  ok(dfail ~= nil and dfail.kind == 'error', 'activity: failed dub → error chip')
  ok(dfail and dfail.label:find('1 dub failed', 1, true) ~= nil,
    'activity: dub failed count in label')
  ok(dfail and type(dfail.retry) == 'function', 'activity: dub error chip has retry')
  ok(dfail and dfail.tooltip and dfail.tooltip:find('HTTP 400', 1, true) ~= nil,
    'activity: dub failed tooltip cites stored reason')

  -- Dubbing: transcribing chunks i/n
  acts = activity.collect({ modes = { dubbing = {
    phase = 'transcribing',
    chunks_plan = { { idx = 1 }, { idx = 2 }, { idx = 3 } },
    chunks_results = { [1] = {} },
    translate_handles = {}, tts_handles = {}, align_handles = {},
  } } })
  local stt_chip = find(acts, 'dub_stt')
  eq(stt_chip and stt_chip.done, 1, 'activity: chunks done')
  eq(stt_chip and stt_chip.total, 3, 'activity: chunks total')

  -- Repair: maszyny stanów mapowane na etapy; idle → nic
  acts = activity.collect({ modes = { repair = {
    stt_state = 'transcribing', regen_state = 'splicing',
  } } })
  ok(find(acts, 'rep_stt') ~= nil, 'activity: repair stt stage visible')
  ok(find(acts, 'rep_regen') ~= nil, 'activity: repair regen stage visible')
  eq(#activity.collect({ modes = { repair = {
    stt_state = 'ready', regen_state = 'idle',
  } } }), 0, 'activity: repair idle states → no chips')

  -- SFX: gen entries + scene phase + rephrase per candidate
  acts = activity.collect({ modes = { sfx = {
    gen_entries = { {}, {} }, scene_phase = 'analyzing',
    scene_candidates = { { rephrase_handle = { status = 'running' } } },
  } } })
  local sg = find(acts, 'sfx_gen')
  ok(sg and sg.label:find('2 takes', 1, true) ~= nil, 'activity: sfx take count')
  ok(find(acts, 'sfx_scene') ~= nil, 'activity: sfx scene phase visible')
  ok(find(acts, 'sfx_rephrase') ~= nil, 'activity: sfx rephrase visible')
end

----------------------------------------------------------------------------
-- modes/repair: undo resync decision (W3 Pakiet B — lekki undo)
----------------------------------------------------------------------------
do
  local repair = require 'modules.modes.repair'
  local OURS   = 'Reasonate: Repair splice'
  local BLEND  = 'Reasonate: Repair blended splice'

  ok(repair.is_repair_undo_label(OURS),  'undo: splice label is ours')
  ok(repair.is_repair_undo_label(BLEND), 'undo: blended label is ours')
  ok(repair.is_repair_undo_label('Reasonate: Repair splice (failed)'),
     'undo: failed label matches prefix')
  ok(not repair.is_repair_undo_label('Move items'), 'undo: foreign label rejected')
  ok(not repair.is_repair_undo_label(nil), 'undo: nil label rejected')

  eq(repair.undo_resync_decision({ count = 5, prev_count = nil }), false,
     'undo: first frame seeds only')
  eq(repair.undo_resync_decision({ count = 5, prev_count = 5, redo_label = OURS }), false,
     'undo: no count change → no resync')
  eq(repair.undo_resync_decision({ count = 6, prev_count = 5, own_count = 6,
       undo_label = OURS }), false,
     'undo: own splice skipped')
  eq(repair.undo_resync_decision({ count = 7, prev_count = 6, own_count = 6,
       redo_label = OURS }), true,
     'undo: ours on redo top → resync')
  eq(repair.undo_resync_decision({ count = 8, prev_count = 7, own_count = 6,
       redo_label = BLEND }), true,
     'undo: consecutive undo → resync')
  eq(repair.undo_resync_decision({ count = 9, prev_count = 8, own_count = 6,
       undo_label = OURS, redo_label = nil, prev_redo_label = OURS }), true,
     'undo: redo of ours → resync')
  eq(repair.undo_resync_decision({ count = 10, prev_count = 9, own_count = 6,
       undo_label = 'Move items', redo_label = nil }), false,
     'undo: foreign action ignored')
  eq(repair.undo_resync_decision({ count = 11, prev_count = 10, own_count = 6,
       undo_label = OURS, redo_label = 'Move items', prev_redo_label = nil }), false,
     'undo: undo of foreign action ignored (ours stays on undo stack)')
end

----------------------------------------------------------------------------
-- housekeeping.is_sweepable (M1-3 audit 2026-07 — sieroty VR-convert:
-- job_id bez prefiksu nie łapał się na wzorzec '_<hex>_<hex>.')
----------------------------------------------------------------------------
do
  local housekeeping = require 'modules.housekeeping'
  local NOW = 0x69000000 + 30 * 24 * 3600   -- ts plików + 30 dni
  local OLD = ('conv_%x_%x.done'):format(0x69000000, 0xabcdef)

  ok(housekeeping.is_sweepable(OLD, NOW),
     'sweep: conv_<ts>_<rand>.done (VR convert, M1-3 prefix) sweepable')
  ok(housekeeping.is_sweepable(('stt_%x_%x.json'):format(0x69000000, 0x1a2b3c), NOW),
     'sweep: stt job artifact sweepable')
  ok(not housekeeping.is_sweepable(('conv_%x_%x.done'):format(NOW - 3600, 0xabcdef), NOW),
     'sweep: fresh job (1h) NOT sweepable (7-day TTL)')
  ok(not housekeeping.is_sweepable('tts_1a2b3c4d.mp3', NOW),
     'sweep: cache mp3 (single hex segment) untouched')
  ok(not housekeeping.is_sweepable('stt_deadbeef.json', NOW),
     'sweep: STT cache file (no second hex segment) untouched')
  ok(not housekeeping.is_sweepable('.reasonate_key', NOW),
     'sweep: dotfile untouched')
  ok(not housekeeping.is_sweepable('voices.json', NOW),
     'sweep: voices.json untouched')
  ok(not housekeeping.is_sweepable(('render_%x.wav'):format(0x69000000), NOW),
     'sweep: render wav untouched (ext poza SWEEP_EXT)')
end

----------------------------------------------------------------------------
-- modes/repair: should_spawn_tts_align (M0-1 audit 2026-07 — bramka przeciw
-- nieskończonej pętli płatnych forced-alignment po trwałym async erroze)
----------------------------------------------------------------------------
do
  local repair = require 'modules.modes.repair'
  local ALIGN  = { words = {} }   -- kształt nieistotny — liczy się truthiness

  eq(repair.should_spawn_tts_align({ align_tts_result = nil, align_tts_failed = false }),
     true,  'tts_align: fresh pipeline → spawn')
  eq(repair.should_spawn_tts_align({ align_tts_result = nil, align_tts_failed = true }),
     false, 'tts_align: failed → NO respawn (paid-loop guard)')
  eq(repair.should_spawn_tts_align({ align_tts_result = ALIGN, align_tts_failed = false }),
     false, 'tts_align: result present → no spawn')
  eq(repair.should_spawn_tts_align({ align_tts_result = ALIGN, align_tts_failed = true }),
     false, 'tts_align: result wins even with stale failed flag')
  eq(repair.should_spawn_tts_align({}),
     true,  'tts_align: both nil (pre-init state) → spawn')

  -- W2 M3.2: single_speaker_id — sid dla linku klon↔mówca w Branch B
  -- (legacy single-speaker flow) — nil gdy ≥2 mówców / brak speaker info.
  eq(repair.single_speaker_id({ words = {
    { text = 'a', speaker_id = 'speaker_0' },
    { text = 'b', speaker_id = 'speaker_0' } } }),
    'speaker_0', 'single_sid: one speaker → sid')
  eq(repair.single_speaker_id({ words = {
    { text = 'a', speaker_id = 'speaker_0' },
    { text = 'b', speaker_id = 'speaker_1' } } }),
    nil, 'single_sid: two speakers → nil')
  eq(repair.single_speaker_id({ words = {
    { text = 'a' }, { text = 'b' } } }),
    nil, 'single_sid: no speaker info → nil')
  eq(repair.single_speaker_id({ words = {
    { text = 'a', speaker = 'spk_legacy' } } }),
    'spk_legacy', 'single_sid: legacy .speaker field honored')
  eq(repair.single_speaker_id(nil), nil, 'single_sid: nil transcript safe')
end

----------------------------------------------------------------------------
-- tts_enhance: walidator words-preserved + prompty + plan dialogu (Enhance,
-- 2026-06-11 — gwarancja "LLM dodał tylko tagi, słowa nietknięte")
----------------------------------------------------------------------------
do
  local enh = require 'modules.tts_enhance'

  -- strip_tags / count_tags
  eq(enh.strip_tags('[excited] We won! [laughs]'), 'We won!',
     'enhance: strip_tags removes tags')
  eq(enh.strip_tags('plain text'), 'plain text', 'enhance: strip_tags no-op without tags')
  eq(enh.count_tags('[a] x [b c] y'), 2, 'enhance: count_tags')

  -- words_preserved: dokładne porównanie tokenów po zdjęciu tagów
  ok(enh.words_preserved('We won!', '[excited] We won!'),
     'enhance: tag-only insert preserved')
  ok(enh.words_preserved('Hello there.', 'Hello [dramatic pause] there.'),
     'enhance: mid-text tag preserved')
  ok(not enh.words_preserved('We won!', '[excited] We WON!'),
     'enhance: caps change rejected')
  ok(not enh.words_preserved('We won!', '[excited] We won'),
     'enhance: punctuation change rejected')
  ok(not enh.words_preserved('We won!', '[sad] We lost!'),
     'enhance: word swap rejected')
  ok(not enh.words_preserved('one two three', 'one three two'),
     'enhance: reorder rejected')
  ok(not enh.words_preserved('handle', 'han[sigh]dle'),
     'enhance: tag inside word splits token → rejected')

  -- validate_enhanced_text
  local stats = enh.validate_enhanced_text('We won!', '[excited] We won! [laughs]')
  eq(stats and stats.tags_added, 2, 'enhance: validate counts added tags')
  ok(not enh.validate_enhanced_text('We won!', '[excited We won!'),
     'enhance: stray bracket rejected')
  ok(not enh.validate_enhanced_text('We won!', '[] We won!'),
     'enhance: empty tag rejected')
  ok(not enh.validate_enhanced_text('We won!', nil),
     'enhance: non-string response rejected')
  local s4 = enh.validate_enhanced_text('keep [whispers] this',
                                        'keep [whispers] this [sighs]')
  eq(s4 and s4.tags_added, 1, 'enhance: pre-existing tags = baseline, not added')
  ok(enh.validate_enhanced_text('a [b] c', 'a [b] c') ~= nil,
     'enhance: identical text passes with 0 added')

  -- system prompt: twarde reguły + dźwignie + słownik z audio_tags
  local sp = enh.build_system_prompt('theatrical', { dialogue = true })
  ok(sp:find('NEVER alter', 1, true) ~= nil, 'enhance: prompt hard rule present')
  ok(sp:find('theatrical', 1, true) ~= nil, 'enhance: intensity brief folded')
  ok(sp:find('whispers', 1, true) ~= nil, 'enhance: curated vocabulary folded')
  ok(sp:find('whole conversation', 1, true) ~= nil, 'enhance: dialogue section present')
  ok(sp:find('PREVIOUS ATTEMPT', 1, true) == nil, 'enhance: no strict section by default')
  ok(enh.build_system_prompt('subtle', { strict_retry = true })
       :find('PREVIOUS ATTEMPT', 1, true) ~= nil,
     'enhance: strict retry section folded')
  eq(enh.find_intensity('bogus').id, 'standard', 'enhance: unknown intensity → standard')

  -- user prompty: speaker labels + director's note (pomijany gdy pusty)
  local up = enh.build_user_prompt_dialogue(
    { { id = 'l1', speaker_id = 'spA', text = 'Hi.' } },
    { spA = 'Anna' }, 'noir mood')
  ok(up:find('Anna', 1, true) ~= nil, 'enhance: speaker label in user prompt')
  ok(up:find('noir mood', 1, true) ~= nil, 'enhance: director note in user prompt')
  ok(enh.build_user_prompt_single('text here', '  ')
       :find("Director's", 1, true) == nil, 'enhance: blank note omitted')

  -- Tryb "pauses & emphasis" (loose): CAPS + … przechodzą, słowa twarde
  ok(enh.words_preserved_loose('We won!', '[excited] We WON!'),
     'enhance loose: CAPS emphasis accepted')
  ok(enh.words_preserved_loose('It was a long day.', 'It was a VERY... long day.') == false,
     'enhance loose: inserted word still rejected')
  ok(enh.words_preserved_loose('Hello there.', 'Hello... THERE!'),
     'enhance loose: ellipsis + caps + punct accepted')
  ok(enh.words_preserved_loose('Cisza teraz.', '[whispers] CISZA... teraz.'),
     'enhance loose: ascii-folded caps with tag accepted')
  ok(enh.words_preserved_loose('No świetnie.', 'No ŚWIETNIE!'),
     'enhance loose: polish diacritics fold (Ś→ś)')
  ok(enh.words_preserved_loose('one two', 'one ... two'),
     'enhance loose: standalone ellipsis token skipped')
  ok(enh.words_preserved_loose('We won!', 'We lost!') == false,
     'enhance loose: word swap rejected')
  ok(not enh.validate_enhanced_text('We won!', '[excited] We WON!'),
     'enhance strict: caps still rejected without opts')
  ok(enh.validate_enhanced_text('We won!', '[excited] We WON!',
       { allow_punct = true }) ~= nil,
     'enhance: validate honors allow_punct')

  -- plan_dialogue_apply: tylko walidne zmiany; altered → invalid; ghost id ignored
  local snap = {
    { id = 'l1', text = 'We won!' },
    { id = 'l2', text = 'Quiet now.' },
    { id = 'l3', text = 'Unchanged line.' },
  }
  local plan = enh.plan_dialogue_apply(snap, { lines = {
    { id = 'l1', text = '[excited] We won!' },
    { id = 'l2', text = '[whispers] Stay quiet now.' },
    { id = 'l3', text = 'Unchanged line.' },
    { id = 'ghost', text = '[x] not ours' },
  } })
  eq(#plan.changes, 1, 'enhance: plan accepts only valid changed lines')
  eq(plan.changes[1] and plan.changes[1].id, 'l1', 'enhance: plan change id')
  eq(plan.changes[1] and plan.changes[1].tags_added, 1, 'enhance: plan tags_added')
  eq(#plan.invalid, 1, 'enhance: plan flags altered line')
  eq(plan.unchanged, 1, 'enhance: plan counts unchanged')
  local noplan, perr = enh.plan_dialogue_apply(snap, { wrong = true })
  ok(noplan == nil and perr ~= nil, 'enhance: malformed response rejected')

  -- plan z allow_punct: linia z CAPS/… przechodzi jako zmiana
  local plan_p = enh.plan_dialogue_apply(
    { { id = 'p1', text = 'We won!' } },
    { lines = { { id = 'p1', text = '[excited] We WON... yes!' } } })
  eq(#(plan_p and plan_p.invalid or {}), 1, 'enhance: strict plan rejects CAPS line')
  plan_p = enh.plan_dialogue_apply(
    { { id = 'p1', text = 'We won yes!' } },
    { lines = { { id = 'p1', text = '[excited] We WON... yes!' } } },
    { allow_punct = true })
  eq(#(plan_p and plan_p.changes or {}), 1, 'enhance: loose plan accepts CAPS line')

  -- activity chip dla enhance handle
  local activity = require 'modules.activity'
  local acts = activity.collect(
    { modes = { tts = { enhance_handle = { status = 'running' } } } }, {})
  local found = false
  for _, a in ipairs(acts) do if a.id == 'tts_enhance' then found = true end end
  ok(found, 'activity: tts enhance chip visible')
end

----------------------------------------------------------------------------
-- llm.resolve_task: per-feature provider/model overrides (Settings → AI,
-- 2026-06-11). Stub ExtState ma storage → pełny cykl set/get.
----------------------------------------------------------------------------
do
  local cfg = require 'modules.config'
  local llm = require 'modules.llm'

  -- baseline: jeden skonfigurowany provider (gemini)
  cfg.set_llm_provider_key('gemini', 'test-key-g')
  cfg.set_llm_provider_active('')

  local p, m = llm.resolve_task(nil)
  eq(p, 'gemini', 'llm: no purpose → effective provider')
  eq(m, cfg.get_llm_provider_model('gemini'), 'llm: no purpose → provider default model')

  -- override providera bez klucza → fallback na effective
  cfg.set_llm_task_provider('enhance', 'anthropic')   -- brak klucza anthropic
  cfg.set_llm_task_model('enhance', 'claude-haiku-4-5')
  p, m = llm.resolve_task('enhance')
  eq(p, 'gemini', 'llm: override provider without key → fallback')
  eq(m, cfg.get_llm_provider_model('gemini'),
     'llm: orphaned task model NOT applied after fallback')

  -- override z kluczem → honorowany provider + model taska
  cfg.set_llm_provider_key('anthropic', 'test-key-a')
  p, m = llm.resolve_task('enhance')
  eq(p, 'anthropic', 'llm: task provider override honored')
  eq(m, 'claude-haiku-4-5', 'llm: task model override honored')

  -- model-only override (provider Default) → model na effective providerze
  cfg.set_llm_task_provider('sfx', '')
  cfg.set_llm_task_model('sfx', 'gemini-2.5-flash-lite')
  cfg.set_llm_provider_active('gemini')
  p, m = llm.resolve_task('sfx')
  eq(p, 'gemini', 'llm: model-only override keeps effective provider')
  eq(m, 'gemini-2.5-flash-lite', 'llm: model-only override applied')

  -- nieznany task w config → setter no-op
  cfg.set_llm_task_provider('bogus', 'gemini')
  eq(cfg.get_llm_task_provider('bogus'), nil, 'llm: unknown task rejected')

  -- sprzątanie (ExtState stub współdzielony między blokami testów)
  cfg.set_llm_provider_key('gemini', '')
  cfg.set_llm_provider_key('anthropic', '')
  cfg.set_llm_task_provider('enhance', '')
  cfg.set_llm_task_model('enhance', '')
  cfg.set_llm_task_model('sfx', '')
  cfg.set_llm_provider_active('')
end

----------------------------------------------------------------------------
-- dialogue_script: parser importu skryptu txt/md (W3 2026-06-11)
----------------------------------------------------------------------------
do
  local ds = require 'modules.dialogue_script'

  local lines = ds.parse('Anna: Hello there.\nMarek: Hi.\n')
  eq(#lines, 2, 'script: basic two lines')
  eq(lines[1].speaker, 'Anna', 'script: speaker name')
  eq(lines[1].text, 'Hello there.', 'script: line text')

  lines = ds.parse('# Act 1\n\n**Anna:** Hello.\n- Marek: Hi.\n---\n')
  eq(#lines, 2, 'script: md decorations tolerated')
  eq(lines[1].speaker, 'Anna', 'script: bold name stripped')
  eq(lines[1].text, 'Hello.', 'script: bold rest stripped')
  eq(lines[2].speaker, 'Marek', 'script: bullet stripped')

  lines = ds.parse('Anna: First part\nsecond part.\nMarek: Ok.')
  eq(#lines, 2, 'script: continuation merged')
  eq(lines[1].text, 'First part second part.', 'script: continuation text')

  lines = ds.parse('\239\187\191Anna: Hi.\r\nMarek: Yo.\r\n')
  eq(#lines, 2, 'script: BOM + CRLF normalized')
  eq(lines[2].text, 'Yo.', 'script: CRLF line text clean')

  lines = ds.parse('Scene description here\nAnna: Hi.')
  eq(#lines, 1, 'script: preamble before first cue ignored')

  local none, err = ds.parse('just prose\nno cues here')
  ok(none == nil and err ~= nil, 'script: no cues → error')
  local e2, err2 = ds.parse('')
  ok(e2 == nil and err2 ~= nil, 'script: empty → error')
end

----------------------------------------------------------------------------
-- Dubbing context gate (2026-06-11, live-caught deadlock): excluded
-- substantive segment w oknie kontekstu NIE może bramkować tłumaczeń
-- (pompa nigdy go nie przetłumaczy → WAITING forever). Scanner pomija
-- excluded zarówno dla gate'a jak i treści kontekstu.
----------------------------------------------------------------------------
do
  local dub = require 'modules.modes.dubbing'
  local function seg(text, excluded)
    return { source_text = text, dub_excluded = excluded or nil,
             translation_status = {} }
  end
  local segs = {
    seg('one two three four five'),        -- 1: substantive
    seg('six seven eight nine ten', true), -- 2: substantive ale EXCLUDED
    seg('hi'),                             -- 3: interjection (poniżej progu)
    seg('eleven twelve thirteen fourteen'),-- 4: target
  }
  local prevs = dub.context_prev_substantive(segs, 4, 2)
  eq(#prevs, 1, 'dub context: excluded substantive skipped (deadlock regression)')
  ok(prevs[1] == segs[1], 'dub context: prev = nearest non-excluded substantive')

  -- Sąsiedztwo bez excluded — bez zmian (2 prevs w oknie)
  local segs2 = {
    seg('one two three four five'),
    seg('six seven eight nine ten'),
    seg('eleven twelve thirteen fourteen'),
  }
  local prevs2 = dub.context_prev_substantive(segs2, 3, 2)
  eq(#prevs2, 2, 'dub context: non-excluded window unchanged')

  -- M4-5 wariant A (2026-07-11): terminalnie FAILED prev nie blokuje ogona —
  -- prev_translations_ready traktuje 'failed' jak rozstrzygnięty (pre-fix:
  -- reszta kolejki czekała wiecznie na tłumaczenie, które nie powstanie).
  local function seg_st(text, st)
    return { source_text = text, translation_status = { en = st } }
  end
  local segs3 = {
    seg_st('one two three four five', 'failed'),
    seg_st('six seven eight nine ten', 'translated'),
    seg_st('eleven twelve thirteen fourteen', 'pending'),
  }
  ok(dub.prev_translations_ready(segs3, 3, 'en'),
     'dub gate M4-5: failed prev NIE blokuje (ready=true)')
  local segs4 = {
    seg_st('one two three four five', 'translating'),
    seg_st('six seven eight nine ten', 'translated'),
    seg_st('eleven twelve thirteen fourteen', 'pending'),
  }
  ok(not dub.prev_translations_ready(segs4, 3, 'en'),
     'dub gate M4-5: in-flight prev nadal blokuje (ready=false)')
end

----------------------------------------------------------------------------
-- Phase 7 (2026-06-11): chunked STS — czyste części.
-- pick_silence_run (wydzielony rdzeń find_silence_cut) + chunk_plan_hash +
-- regression guard na twardy limit kawałka (safe+search ≤ 290; latentny
-- odpowiednik buga dubbingu 450+60>480 — patrz KNOWN-ISSUES).
----------------------------------------------------------------------------
do
  local chunker      = require 'modules.dubbing_chunker'
  local audio_render = require 'modules.audio_render'

  -- amps builder: total próbek głośnych (0.5), silent ranges → 0.001
  local function amps_with_runs(total, runs)
    local a = {}
    for i = 1, total do a[i] = 0.5 end
    for _, r in ipairs(runs) do
      for i = r[1], r[2] do a[i] = 0.001 end
    end
    return a
  end

  local RATE, LO, TARGET, THR, MINSIL = 100, 205.0, 230.0, 0.012, 0.5

  -- 1. Pojedynczy kwalifikujący run → center
  local amps = amps_with_runs(5000, { { 2400, 2500 } })
  local t = chunker.pick_silence_run(amps, RATE, LO, TARGET, THR, MINSIL)
  near(t, 229.5, 0.05, 'chunker: single silent run → center time')

  -- 2. Brak ciszy → nil
  ok(chunker.pick_silence_run(amps_with_runs(5000, {}), RATE, LO, TARGET, THR, MINSIL) == nil,
    'chunker: no silence → nil (hard cut fallback)')

  -- 3. Run krótszy niż minimum → nil
  ok(chunker.pick_silence_run(amps_with_runs(5000, { { 2400, 2430 } }), RATE, LO, TARGET, THR, MINSIL) == nil,
    'chunker: run shorter than min → nil')

  -- 4. Dwa runy → bliższy targetu wygrywa
  local t4 = chunker.pick_silence_run(
    amps_with_runs(5000, { { 2400, 2500 }, { 3000, 3100 } }), RATE, LO, TARGET, THR, MINSIL)
  near(t4, 229.5, 0.05, 'chunker: two runs → closest to target wins')

  -- 5. Trailing run (cisza do końca okna) liczony
  local t5 = chunker.pick_silence_run(
    amps_with_runs(5000, { { 4900, 5000 } }), RATE, LO, TARGET, THR, MINSIL)
  near(t5, 254.5, 0.05, 'chunker: trailing run handled')

  -- 6. chunk_plan_hash: deterministyczny + czuły na boundaries
  local plan_a = { { t_start_in_src = 0, t_end_in_src = 250.123 },
                   { t_start_in_src = 250.123, t_end_in_src = 480.0 } }
  local plan_b = { { t_start_in_src = 0, t_end_in_src = 250.124 },
                   { t_start_in_src = 250.124, t_end_in_src = 480.0 } }
  eq(audio_render.chunk_plan_hash(plan_a), audio_render.chunk_plan_hash(plan_a),
    'chunk_plan_hash: deterministic')
  ok(audio_render.chunk_plan_hash(plan_a) ~= audio_render.chunk_plan_hash(plan_b),
    'chunk_plan_hash: boundary shift changes hash')

  -- 7. Regression guard: max długość kawałka (safe + search) ≤ target 290s
  local o = audio_render.STS_CHUNK_OPTS
  ok(o.safe_secs + o.search_secs <= o.target_secs,
    'STS chunk opts: safe+search within 290s hard limit')
  eq(o.target_secs, 290, 'STS chunk opts: target == STS limit')

  -- 8. W2 M1: ten sam guard dla DOMYŚLNYCH parametrów dubbingu — 450+60
  -- dawało kawałek do 510s > limit Scribe diarize 480s (latentne od NS-B M1).
  ok(chunker.SAFE_CHUNK_SECS + chunker.SILENCE_SEARCH <= chunker.TARGET_CHUNK_SECS,
    'dubbing chunk defaults: safe+search within Scribe 480s limit')
  eq(chunker.TARGET_CHUNK_SECS, 480, 'dubbing chunk defaults: target == Scribe diarize limit')
end

----------------------------------------------------------------------------
-- util.extract_json (M4-2) — fences / preambuła / trailing proza / truncation.
----------------------------------------------------------------------------
do
  local clean = '{"translation":"Hello world"}'
  eq(util.extract_json(clean), clean, 'extract_json: czysty JSON bez zmian')
  eq(util.extract_json('```json\n' .. clean .. '\n```'), clean,
     'extract_json: markdown fence ```json zdjęty')
  eq(util.extract_json('```\n' .. clean .. '\n```'), clean,
     'extract_json: goły fence ``` zdjęty')
  eq(util.extract_json('Here is the translation:\n' .. clean), clean,
     'extract_json: preambuła ucięta do pierwszego {')
  eq(util.extract_json(clean .. '\nI hope this helps!'), clean,
     'extract_json: trailing proza ucięta po zbalansowaniu')
  eq(util.extract_json('{"a":"tekst z } w stringu","b":1}'),
     '{"a":"tekst z } w stringu","b":1}',
     'extract_json: klamra wewnątrz stringa nie psuje balansu')
  eq(util.extract_json('{"a":"esc \\" quote","b":[1,2]}'),
     '{"a":"esc \\" quote","b":[1,2]}',
     'extract_json: escapowany cudzysłów obsłużony')
  eq(util.extract_json('{"translation":"ucięte w poło'), nil,
     'extract_json: ucięty JSON → nil (nie crash)')
  eq(util.extract_json('Sorry, I cannot help with that.'), nil,
     'extract_json: brak JSON → nil')
  eq(util.extract_json(''), nil, 'extract_json: pusty string → nil')
  eq(util.extract_json('[{"x":1},{"y":2}]'), '[{"x":1},{"y":2}]',
     'extract_json: top-level array wspierany')
end

----------------------------------------------------------------------------
-- repair.refine_words_with_alignment (M5-8) — wskaźnik kroczący toleruje
-- split/merge tokenizacji (pozycyjny match 1:1 gubił refinement ogona).
----------------------------------------------------------------------------
do
  local rep = require 'modules.modes.repair'
  local words_tbl = {
    { text = 'alpha', start = 1.0, ['end'] = 1.4 },
    { text = 'beta',  start = 2.0, ['end'] = 2.5 },
    { text = 'gamma', start = 3.0, ['end'] = 3.6 },
  }
  -- Aligner rozbił 'beta' na 'be'+'ta' (split) — pozycyjny match traciłby
  -- 'gamma'; kroczący z oknem 3 znajduje ją dalej.
  local alignment = { words = {
    { text = 'alpha', start = 1.05, ['end'] = 1.45 },
    { text = ' ' },
    { text = 'be',    start = 2.05, ['end'] = 2.2 },
    { text = 'ta',    start = 2.2,  ['end'] = 2.55 },
    { text = ' ' },
    { text = 'gamma', start = 3.05, ['end'] = 3.65 },
  } }
  local r = rep.refine_words_with_alignment(words_tbl, alignment)
  ok(r[1].aligned, 'refine M5-8: slowo 1 refined')
  ok(not r[2].aligned, 'refine M5-8: split token → slowo 2 bez refinement (fallback Scribe)')
  ok(r[3].aligned, 'refine M5-8: slowo PO splicie nadal refined (ogon nie ginie)')
  near(r[3].start, 3.05, 1e-9, 'refine M5-8: czas slowa 3 z alignera')
  -- Drift guard: outlier alignera (>2s) nie nadpisuje czasu Scribe.
  local align_bad = { words = { { text = 'alpha', start = 9.0, ['end'] = 9.4 } } }
  local r2 = rep.refine_words_with_alignment(
    { { text = 'alpha', start = 1.0, ['end'] = 1.4 } }, align_bad)
  ok(not r2[1].aligned, 'refine M5-8: drift >2s odrzucony (guard zachowany)')
end

----------------------------------------------------------------------------
-- forced_align.words_from_char_alignment (M5-1) — alignment znakowy z
-- /with-timestamps → kształt forced-align (words z tokenami whitespace).
----------------------------------------------------------------------------
do
  local fa = require 'modules.forced_align'
  -- "Ala ma" — 6 znaków, spacja między słowami.
  local al = {
    characters = { 'A', 'l', 'a', ' ', 'm', 'a' },
    character_start_times_seconds = { 0.00, 0.10, 0.20, 0.30, 0.40, 0.50 },
    character_end_times_seconds   = { 0.10, 0.20, 0.30, 0.40, 0.50, 0.60 },
  }
  local r = fa.words_from_char_alignment(al)
  ok(r ~= nil, 'words_from_chars: wynik nie-nil')
  eq(#r.words, 3, 'words_from_chars: slowo + spacja + slowo = 3 tokeny')
  eq(r.words[1].text, 'Ala', 'words_from_chars: token 1 = Ala')
  eq(r.words[2].text, ' ',   'words_from_chars: token 2 = whitespace (mirror serwisu)')
  eq(r.words[3].text, 'ma',  'words_from_chars: token 3 = ma')
  near(r.words[1].start, 0.0, 1e-9, 'words_from_chars: start slowa 1')
  near(r.words[1]['end'], 0.30, 1e-9, 'words_from_chars: end slowa 1')
  near(r.words[3].start, 0.40, 1e-9, 'words_from_chars: start slowa 2')
  near(r.words[3]['end'], 0.60, 1e-9, 'words_from_chars: end slowa 2')
  -- Wielobajtowe znaki (polskie) — konkatenacja per znak, nie bajt.
  local al2 = {
    characters = { 'ż', 'ó', 'ł', 'w' },
    character_start_times_seconds = { 0, 0.1, 0.2, 0.3 },
    character_end_times_seconds   = { 0.1, 0.2, 0.3, 0.4 },
  }
  local r2 = fa.words_from_char_alignment(al2)
  eq(#r2.words, 1, 'words_from_chars: 1 słowo UTF-8')
  eq(r2.words[1].text, 'żółw', 'words_from_chars: diakrytyki sklejone poprawnie')
  eq(fa.words_from_char_alignment(nil), nil, 'words_from_chars: nil → nil')
  eq(fa.words_from_char_alignment({ characters = {} }), nil, 'words_from_chars: pusty → nil')
end

----------------------------------------------------------------------------
-- dubbing_project.speaker_sample_regions (M4-1) — sampel IVC z segmentów
-- JEDNEGO speakera: filtr, merge przyległych, cap łącznego czasu.
----------------------------------------------------------------------------
do
  local dp = require 'modules.dubbing_project'
  local proj = { segments = {
    { speaker_id = 'sp1', t_start = 0.0,  t_end = 4.0 },
    { speaker_id = 'sp2', t_start = 4.2,  t_end = 9.0 },   -- inny mówca
    { speaker_id = 'sp1', t_start = 4.5,  t_end = 8.0 },   -- gap 0.5 → merge
    { speaker_id = 'sp1', t_start = 20.0, t_end = 25.0 },  -- gap duży → osobny
    { speaker_id = 'sp1', t_start = 30.0, t_end = 31.0, dub_excluded = true },
  } }
  local r = dp.speaker_sample_regions(proj, 'sp1')
  eq(#r, 2, 'sample_regions: merge przyległych + skip cudzych/excluded → 2 regiony')
  near(r[1].start, 0.0, 1e-9, 'sample_regions: region 1 start')
  near(r[1]['end'], 8.0, 1e-9, 'sample_regions: region 1 zmergowany do 8.0')
  near(r[2].start, 20.0, 1e-9, 'sample_regions: region 2 osobny')

  -- Cap łącznego czasu: 2 regiony po 100 s, max 150 → drugi przycięty do 50 s.
  local proj2 = { segments = {
    { speaker_id = 'a', t_start = 0,   t_end = 100 },
    { speaker_id = 'a', t_start = 200, t_end = 300 },
  } }
  local r2 = dp.speaker_sample_regions(proj2, 'a', { max_secs = 150 })
  eq(#r2, 2, 'sample_regions: cap zostawia 2 regiony')
  near(r2[2]['end'] - r2[2].start, 50, 1e-9, 'sample_regions: ostatni region przycięty do capu')
  near((r2[1]['end'] - r2[1].start) + (r2[2]['end'] - r2[2].start), 150, 1e-9,
    'sample_regions: łączny czas == max_secs')

  eq(#dp.speaker_sample_regions({ segments = {} }, 'x'), 0, 'sample_regions: brak segmentów → {}')
  eq(#dp.speaker_sample_regions(nil, 'x'), 0, 'sample_regions: nil project → {}')
end

----------------------------------------------------------------------------
-- dubbing_project.add_target_language — W2 M3 cz.2: nowy język dziedziczy
-- cast (user decision 2026-07-11 nocna: kopiuj cicho + status). Źródło:
-- aktywny język jeśli ma głosy, inaczej pierwszy target z głosami.
----------------------------------------------------------------------------
do
  local dp = require 'modules.dubbing_project'
  -- Minimalny projekt ręcznie (new_project → generate_project_guid wymaga
  -- reaper.genGuid; testujemy czyste add_speaker/add_segment/add_target_language).
  local function mk_proj(langs)
    return { target_languages = langs, active_target_language = langs[1],
             speakers = {}, segments = {} }
  end
  local proj = mk_proj({ 'en', 'de' })
  local spk1 = dp.add_speaker(proj, 'Anna')
  local spk2 = dp.add_speaker(proj, 'Bob')
  dp.add_segment(proj, spk1.id, 0, 1, 'hi there you all')
  proj.active_target_language = 'en'
  spk1.voices['en']      = 'vAnnaEN'
  spk1.voice_names['en'] = 'Rachel'
  spk1.voice_settings_per_lang['en'].stability = 0.9
  -- spk2 bez głosu — nie dziedziczy (nie ma czego).

  local ok3, _, info = dp.add_target_language(proj, 'pl')
  ok(ok3, 'inherit: add lang ok')
  eq(info and info.inherited_from, 'en', 'inherit: source = active lang')
  eq(info and info.count, 1, 'inherit: 1 speaker inherited (Bob had no voice)')
  eq(spk1.voices['pl'], 'vAnnaEN', 'inherit: voice copied to new lang')
  eq(spk1.voice_names['pl'], 'Rachel', 'inherit: voice name copied')
  near(spk1.voice_settings_per_lang['pl'].stability, 0.9, 1e-9,
    'inherit: voice_settings copied')
  spk1.voice_settings_per_lang['pl'].stability = 0.1
  near(spk1.voice_settings_per_lang['en'].stability, 0.9, 1e-9,
    'inherit: settings copy is independent (deep enough)')
  eq(spk2.voices['pl'], nil, 'inherit: speaker without voice stays empty')
  -- Segmenty nowego języka nadal świeże (pending) — dziedziczenie głosów
  -- nie tyka tłumaczeń.
  eq(proj.segments[1].translation_status['pl'], 'pending',
    'inherit: segment fields still fresh for new lang')

  -- Aktywny język BEZ głosów → źródłem pierwszy target z głosami.
  local proj2 = mk_proj({ 'en', 'de' })
  local s21 = dp.add_speaker(proj2, 'Cezary')
  proj2.active_target_language = 'de'   -- de nie ma głosów
  s21.voices['en']      = 'vC'
  s21.voice_names['en'] = 'Clyde'
  local _, _, info2 = dp.add_target_language(proj2, 'fr')
  eq(info2 and info2.inherited_from, 'en',
    'inherit: fallback to first configured lang when active has no voices')
  eq(s21.voices['fr'], 'vC', 'inherit: fallback source copied')

  -- Projekt bez żadnych głosów → brak dziedziczenia, info nil, pola puste.
  local proj3 = mk_proj({ 'en' })
  dp.add_speaker(proj3, 'Dora')
  local ok4, _, info3 = dp.add_target_language(proj3, 'pl')
  ok(ok4, 'inherit: add lang ok (no voices anywhere)')
  eq(info3, nil, 'inherit: nothing to inherit → info nil')
  eq(proj3.speakers[1].voices['pl'], nil, 'inherit: fields stay empty')

  -- Duplikat nadal odrzucany.
  local ok5, err5 = dp.add_target_language(proj, 'pl')
  ok(not ok5, 'inherit: duplicate lang rejected')
  ok(tostring(err5):find('already'), 'inherit: duplicate error message intact')
end

----------------------------------------------------------------------------
-- update_check: parse_version / is_newer (PHASE-USER-GUIDE §3)
----------------------------------------------------------------------------
do
  local uc = require 'modules.update_check'

  local v = uc.parse_version('v1.2.3')
  eq(v and v[1], 1, 'parse_version: major')
  eq(v and v[2], 2, 'parse_version: minor')
  eq(v and v[3], 3, 'parse_version: patch')
  eq(v and v.pre, math.huge, 'parse_version: final release pre = huge')

  local rc = uc.parse_version('1.0.0-rc1')
  eq(rc and rc.pre, 1, 'parse_version: rc suffix number extracted')
  eq(uc.parse_version('1.0') and uc.parse_version('1.0')[3], 0,
    'parse_version: missing patch defaults to 0')
  eq(uc.parse_version('garbage'), nil, 'parse_version: malformed → nil')
  eq(uc.parse_version(nil), nil, 'parse_version: nil input → nil')
  eq(uc.parse_version('  v2.1.0  ') and uc.parse_version('  v2.1.0  ')[1], 2,
    'parse_version: whitespace + v-prefix stripped')
  eq(uc.parse_version('1.0.0-beta') and uc.parse_version('1.0.0-beta').pre, 0,
    'parse_version: numberless pre-release suffix → 0')

  ok(uc.is_newer('v1.0.1', '1.0.0'), 'is_newer: patch bump')
  ok(uc.is_newer('2.0.0', '1.9.9'), 'is_newer: major beats minor/patch')
  ok(uc.is_newer('1.0.0', '1.0.0-rc1'), 'is_newer: final > rc of same triad')
  ok(uc.is_newer('1.0.0-rc2', '1.0.0-rc1'), 'is_newer: rc2 > rc1')
  ok(uc.is_newer('1.0.0-rc10', '1.0.0-rc2'), 'is_newer: rc10 > rc2 (numeric, not lexical)')
  ok(not uc.is_newer('1.0.0', '1.0.0'), 'is_newer: equal → false')
  ok(not uc.is_newer('1.0.0-rc1', '1.0.0'), 'is_newer: rc < final → false')
  ok(not uc.is_newer('0.9.9', '1.0.0'), 'is_newer: older → false')
  ok(not uc.is_newer('garbage', '1.0.0'), 'is_newer: malformed remote → false (defensive)')
  ok(not uc.is_newer('1.0.1', 'garbage'), 'is_newer: malformed local → false (defensive)')
end

----------------------------------------------------------------------------
-- Summary
----------------------------------------------------------------------------
print(('Reasonate tests: %d passed, %d failed'):format(n_pass, n_fail))
for _, f in ipairs(failures) do print('  ' .. f) end
os.exit(n_fail == 0 and 0 or 1)
