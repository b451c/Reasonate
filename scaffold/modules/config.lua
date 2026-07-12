-- modules/config.lua
-- Wszystkie persistent settings idą przez REAPER ExtState (sekcja "Reasonate"),
-- które są globalne (nie .rpp). Per-projekt mapping voice'ów siedzi w P_EXT.
--
-- Renamed 2026-05-10: namespace ReaCast → Reasonate (collision z built-in REAPER
-- "ReaCast" web streamer). Migracja ExtState one-shot przez M.migrate_from_reacast()
-- wywołane raz z entrypoint.

local M = {}

local NAMESPACE     = 'Reasonate'
local OLD_NAMESPACE = 'ReaCast'    -- legacy; migracja one-shot

M.NAMESPACE     = NAMESPACE
M.OLD_NAMESPACE = OLD_NAMESPACE

-- T4 (UX-POLISH): wersja user-facing (Settings → About). Phase 10 doda
-- nagłówek @version ReaPack — trzymać w synchronizacji przy release.
M.APP_VERSION = '1.0.0'

-- Update-check (PHASE-USER-GUIDE §3): GitHub Releases repo slug.
-- Puste = feature wyłączony (przycisk w About ukryty, cichy check nie
-- startuje). Ustawione przy publikacji 1.0.0 (2026-07-12).
M.UPDATE_REPO = 'b451c/Reasonate'

local function get(key, default)
  local v = reaper.GetExtState(NAMESPACE, key)
  if v == '' then return default end
  return v
end

local function set(key, value)
  -- 4. argument true = persist do ini file (przeżywa restart REAPER)
  reaper.SetExtState(NAMESPACE, key, value or '', true)
end

----------------------------------------------------------------------------
-- One-shot migration ReaCast → Reasonate (ExtState).
-- Idempotent: po pierwszym przebiegu zostawia flagę '_migrated_from_reacast=1'.
-- Każdy klucz: jeśli istnieje w starym namespace a nie ma w nowym → kopiujemy.
-- NIE czyścimy starego (bezpiecznik na rollback). Po 2-3 wersjach można dodać
-- cleanup w osobnej funkcji.
----------------------------------------------------------------------------
local MIGRATED_KEYS = {
  'api_key', 'curl_path',
  'model_id', 'output_format', 'concurrency', 'remove_bg_noise',
  'casts', 'favorites',
  'record_input', 'record_pre_roll', 'record_monitor',
  'output_layout',
  'window_dock_id', 'last_crash_count',
}

function M.migrate_from_reacast()
  local flag = reaper.GetExtState(NAMESPACE, '_migrated_from_reacast')
  if flag == '1' then return 0 end
  local count = 0
  for _, k in ipairs(MIGRATED_KEYS) do
    local old = reaper.GetExtState(OLD_NAMESPACE, k)
    local new = reaper.GetExtState(NAMESPACE, k)
    if old ~= '' and new == '' then
      reaper.SetExtState(NAMESPACE, k, old, true)
      count = count + 1
    end
  end
  reaper.SetExtState(NAMESPACE, '_migrated_from_reacast', '1', true)
  if count > 0 then
    reaper.ShowConsoleMsg(
      ('[Reasonate] Migrated %d settings from legacy ReaCast namespace.\n'):format(count))
  end
  return count
end

----------------------------------------------------------------------------
-- API key
----------------------------------------------------------------------------
function M.get_api_key()
  local k = get('api_key', '')
  if k == '' then return nil end
  return k
end

function M.set_api_key(key)
  set('api_key', key)
end

function M.has_api_key()
  return M.get_api_key() ~= nil
end

----------------------------------------------------------------------------
-- curl path (resolved by _phase0_check.lua)
----------------------------------------------------------------------------
local _curl_fallback_cache = nil
function M.get_curl_path()
  local p = get('curl_path', '')
  if p ~= '' and p ~= 'curl' then return p end
  -- Fresh-install fallback (2026-07-12, user-caught na VM): gołe 'curl'
  -- w PowerShell 5.1 to ALIAS Invoke-WebRequest — workery dostają
  -- parameter-binding error zamiast requestu → FAIL HTTP 0. Na macOS GUI
  -- ExecProcess nie rozwiązuje PATH wcale (KNOWN-ISSUES). Preferuj
  -- absolutną ścieżkę systemową; _phase0_check nadal może nadpisać.
  if _curl_fallback_cache then return _curl_fallback_cache end
  local candidates
  if reaper.GetOS():find('Win') then
    candidates = { 'C:\\Windows\\System32\\curl.exe' }
  else
    candidates = { '/usr/bin/curl', '/opt/homebrew/bin/curl', '/usr/local/bin/curl' }
  end
  for _, c in ipairs(candidates) do
    local f = io.open(c, 'rb')
    if f then f:close(); _curl_fallback_cache = c; return c end
  end
  _curl_fallback_cache = (p ~= '') and p or 'curl'
  return _curl_fallback_cache
end

----------------------------------------------------------------------------
-- Defaults dla fazy 4-5 (ustawione przez settings dialog albo defaultem)
----------------------------------------------------------------------------
function M.get_model_id()         return get('model_id',      'eleven_multilingual_sts_v2') end
function M.get_output_format()    return get('output_format', 'mp3_44100_128') end
function M.get_concurrency()      return tonumber(get('concurrency', '3')) or 3 end

-- M6-5 (audit 2026-07): limit równoległych requestów per tier ElevenLabs
-- (help 14312733311761). Default 3 > limit Free (2) = 429 churn u nowych
-- userów. state.poll_quota woła note_tier po fetchu subskrypcji; efektywna
-- wartość = min(ustawienie usera, limit planu). Settings pokazuje surowe
-- ustawienie (preferencja usera nietykana), pipeline'y biorą efektywną.
local TIER_CONCURRENCY = {
  free = 2, starter = 3, creator = 5, pro = 10, scale = 15, business = 15,
}
local _tier_cap = nil   -- in-memory (per sesja; nil = tier nieznany)

function M.note_tier(tier)
  _tier_cap = TIER_CONCURRENCY[tostring(tier or ''):lower()]
end

function M.get_effective_concurrency()
  local user = M.get_concurrency()
  if _tier_cap and _tier_cap < user then return _tier_cap end
  return user
end
function M.get_remove_bg_noise()  return get('remove_bg_noise', '0') == '1' end

function M.set_model_id(v)        set('model_id', v) end
function M.set_output_format(v)   set('output_format', v) end
function M.set_concurrency(v)     set('concurrency', tostring(math.max(1, math.min(8, tonumber(v) or 3)))) end
function M.set_remove_bg_noise(v) set('remove_bg_noise', v and '1' or '0') end

-- PM9 iter3: decorative background image (background.png) toggle. Default ON.
function M.get_bg_image_enabled() return get('bg_image_enabled', '1') == '1' end
function M.set_bg_image_enabled(flag) set('bg_image_enabled', flag and '1' or '0') end

-- M0-3 (audit 2026-07, user decision 2026-07-02): globalny toggle logów
-- diagnostycznych (ShowConsoleMsg w ścieżkach tempo/volume/pause/fit).
-- Default OFF — release czysty; kalibracja W1/W2 = checkbox Settings →
-- General. Czytane per zdarzenie (edycja/splice), nie per frame.
function M.get_debug_logging() return get('debug_logging', '0') == '1' end
function M.set_debug_logging(flag) set('debug_logging', flag and '1' or '0') end

-- M2-3 (audit 2026-06-10): limit rozmiaru output cache (GB; 0 = unlimited).
-- Egzekwowany przez cache.evict_to_cap (LRU approx) na starcie + po batch end.
local CACHE_MAX_GB_DEFAULT = 2.0
function M.get_cache_max_gb()
  local v = tonumber(get('cache_max_gb', ''))
  if v == nil or v < 0 then return CACHE_MAX_GB_DEFAULT end
  return v
end
function M.set_cache_max_gb(v)
  v = tonumber(v)
  if v == nil or v < 0 then v = CACHE_MAX_GB_DEFAULT end
  set('cache_max_gb', string.format('%.2f', v))
end
function M.get_cache_max_bytes()
  return math.floor(M.get_cache_max_gb() * 1024 * 1024 * 1024)
end

----------------------------------------------------------------------------
-- Recording (Phase 11.x — track recording z poziomu Reasonate)
-- record_input: REAPER I_RECINPUT format (0=mono ch1, 1=mono ch2, 1024=stereo 1+2)
-- record_pre_roll: secs przed start record (0/1/3/5)
-- record_monitor: 0=off, 1=on (always), 2=auto (on when recording/playing)
----------------------------------------------------------------------------
function M.get_record_input()      return tonumber(get('record_input', '0'))      or 0  end
function M.get_record_pre_roll()   return tonumber(get('record_pre_roll', '0'))   or 0  end
function M.get_record_monitor()    return tonumber(get('record_monitor', '1'))    or 1  end

function M.set_record_input(v)     set('record_input', tostring(tonumber(v) or 0)) end
function M.set_record_pre_roll(v)  set('record_pre_roll', tostring(math.max(0, math.min(10, tonumber(v) or 0)))) end
function M.set_record_monitor(v)   set('record_monitor', tostring(math.max(0, math.min(2, tonumber(v) or 1)))) end

----------------------------------------------------------------------------
-- Repair mode (NS-F M0 / I10): STT language. '' (default) = Scribe
-- auto-detect; ISO 639-1 code (np. 'pl', 'en') wymusza język. Global
-- override getter bez Settings widget (per plan — widget on demand).
-- Wartość wchodzi w seed STT cache key (repair compute_stt_cache_key).
----------------------------------------------------------------------------
function M.get_repair_language()
  local v = get('repair_language', '')
  return v or ''
end

function M.set_repair_language(code)
  set('repair_language', (code or ''):gsub('^%s+', ''):gsub('%s+$', ''):lower())
end

-- M5-1 (audit 2026-07): Repair TTS przez /with-timestamps (1 request z
-- alignmentem zamiast TTS + płatny forced-alignment). Default ON; flaga
-- '0' = legacy 2-requestowa ścieżka (fallback na 1-2 wydania, bez UI).
function M.get_repair_tts_timestamps()
  return get('repair_tts_timestamps', '1') ~= '0'
end

-- M5-6 (advanced): diarization_threshold dla Scribe diarize w dubbingu.
-- nil = default serwera; liczba steruje czułością rozdzielania mówców
-- (ważne tylko przy diarize=true bez num_speakers — docs 2026-07-11).
function M.get_dubbing_diarization_threshold()
  return tonumber(get('dubbing_diarization_threshold', ''))
end

function M.set_dubbing_diarization_threshold(v)
  set('dubbing_diarization_threshold', tonumber(v) and tostring(v) or '')
end

-- M5-9c (user decision 2026-07-11): przesuwanie downstream po splice na
-- WSZYSTKICH trackach (muzyka/SFX pod dialogiem trzymają synchron).
-- Default OFF = dzisiejsze zachowanie (tylko track źródłowy).
function M.get_repair_ripple_all_tracks()
  return get('repair_ripple_all_tracks', '0') == '1'
end

function M.set_repair_ripple_all_tracks(on)
  set('repair_ripple_all_tracks', on and '1' or '0')
end

-- User 2026-07-11: gdzie ląduje track [Dub LANG: mówca].
-- 'folder' (default, dotychczasowe) = dziecko folderu tracka źródłowego —
--   fader/mute źródła steruje też dubami (wygodne do wspólnego miksu).
-- 'flat' = zwykły track POD źródłem (poza folderem) — głośność źródła NIE
--   rusza dubów (niezależny miks, mniej niespodzianek). Dotyczy NOWO
--   tworzonych tracków; istniejące zostają gdzie są (get_or_create reuse).
function M.get_dubbing_track_layout()
  local v = get('dubbing_track_layout', 'folder')
  if v ~= 'flat' then v = 'folder' end
  return v
end

function M.set_dubbing_track_layout(v)
  set('dubbing_track_layout', (v == 'flat') and 'flat' or 'folder')
end

-- Music model (2026-07-11, user-caught: v2 JEST w API — /v1/music przyjmuje
-- model_id music_v1|music_v2, zweryfikowane w referencji + cookbooku).
-- Default v2 (nowszy model; cookbook używa wyłącznie v2). UWAGA:
-- force_instrumental działa TYLKO z v1 — dla v2 instrumental wymuszany
-- w prompcie (voice_admin.spawn_music).
function M.get_music_model()
  local v = get('music_model', 'music_v2')
  if v ~= 'music_v1' and v ~= 'music_v2' then v = 'music_v2' end
  return v
end

function M.set_music_model(v)
  set('music_model', (v == 'music_v1') and 'music_v1' or 'music_v2')
end

-- NS-SFX (2026-06-10): ile propozycji dźwięku generować na jedno kliknięcie
-- (każda = osobna generacja = osobny koszt ~40 credits/s). User-adjustable
-- w panelu (stepper), persisted globalnie. Clamp 1-10.
----------------------------------------------------------------------------
-- T10 (user 2026-07-11): własne style usera — SFX From scene ('sfx_scene':
-- {brief, package}) + Dubbing ('dubbing': snapshot kontekstu {tone, era,
-- audience, media_type, honorific, free_text}). JSON map name→fields w
-- ExtState `custom_styles_<feature>` (globalne, cross-project — mirror
-- tts_presets).
----------------------------------------------------------------------------
local function custom_styles_key(feature)
  return 'custom_styles_' .. tostring(feature)
end

function M.get_custom_styles(feature)
  local raw = get(custom_styles_key(feature), '')
  if raw == '' then return {} end
  local json_lib = require 'modules.lib.json'
  local ok, decoded = pcall(json_lib.decode, raw)
  if not ok or type(decoded) ~= 'table' then return {} end
  return decoded
end

function M.save_custom_style(feature, name, fields)
  if type(name) ~= 'string' or name == '' or type(fields) ~= 'table' then
    return false
  end
  local map = M.get_custom_styles(feature)
  map[name] = fields
  local json_lib = require 'modules.lib.json'
  local ok, encoded = pcall(json_lib.encode, map)
  if not ok then return false end
  set(custom_styles_key(feature), encoded)
  return true
end

function M.delete_custom_style(feature, name)
  local map = M.get_custom_styles(feature)
  if map[name] == nil then return false end
  map[name] = nil
  local json_lib = require 'modules.lib.json'
  local ok, encoded = pcall(json_lib.encode, map)
  if not ok then return false end
  set(custom_styles_key(feature), encoded)
  return true
end

function M.list_custom_style_names(feature)
  local out = {}
  for name in pairs(M.get_custom_styles(feature)) do out[#out + 1] = name end
  table.sort(out)
  return out
end

function M.get_sfx_variant_count()
  -- T9d (user 2026-07-11): default 1 — dwa płatne rendery per klik to za
  -- drogi start; kto chce warianty, podbija stepperem (persist globalnie).
  local v = tonumber(get('sfx_variant_count', '1')) or 1
  return math.max(1, math.min(10, math.floor(v)))
end

function M.set_sfx_variant_count(n)
  n = math.max(1, math.min(10, math.floor(tonumber(n) or 2)))
  set('sfx_variant_count', tostring(n))
end

-- Repair: auto-analiza tempa mowy (match speaker pace). Default OFF
-- (user decision 2026-06-10): głos + kontekst TTS decydują o dynamice;
-- speed ustawiany ręcznie sliderem w panelu (voice settings). ON włącza
-- pełną maszynerię W1.2: pomiar syl/s + baseline EMA + auto-korekta
-- (re-render) + I9-narrow stretch przy podłodze.
function M.get_repair_match_pace()
  return get('repair_match_pace', '0') == '1'
end

function M.set_repair_match_pace(on)
  set('repair_match_pace', on and '1' or '0')
end

----------------------------------------------------------------------------
-- TTS mode (NS-2b): edit cursor advance po Generate. Default true — kursor
-- skacze na koniec wygenerowanego itemu (płynne sekwencyjne pisanie dialogu).
-- User toggle w Settings dla manual cursor control.
----------------------------------------------------------------------------
function M.get_tts_advance_cursor()
  return get('tts_advance_cursor', '1') == '1'
end

function M.set_tts_advance_cursor(flag)
  set('tts_advance_cursor', flag and '1' or '0')
end

-- NS-2d: split dialogue master mp3 na per-speaker tracks via Scribe v2
-- diarization. Default OFF (opt-in) — wymaga +1 STT call per Generate.
function M.get_tts_dialogue_split_per_speaker()
  return get('tts_dialogue_split_per_speaker', '0') == '1'
end

function M.set_tts_dialogue_split_per_speaker(flag)
  set('tts_dialogue_split_per_speaker', flag and '1' or '0')
end

----------------------------------------------------------------------------
-- TTS char counter (NS-2b polish): all-time character count consumed by
-- TTS mode generations (Generate + Regen). Useful for billing visibility —
-- ElevenLabs charges per character. Cache hits not counted (from_cache flag
-- on handle). Phase 11 Repair TTS is NOT tracked here (separate Priority 2).
-- Reset button w Settings TTS section.
----------------------------------------------------------------------------
function M.get_tts_chars_used()
  return tonumber(get('tts_chars_used', '0')) or 0
end

function M.add_tts_chars_used(n)
  if not n or n <= 0 then return end
  local curr = M.get_tts_chars_used()
  set('tts_chars_used', tostring(curr + math.floor(n)))
end

function M.reset_tts_chars_used()
  set('tts_chars_used', '0')
end

----------------------------------------------------------------------------
-- TTS output format (NS-2b polish). ElevenLabs supports many; we expose the
-- three useful w DAW workflow:
--   mp3_44100_128 — good MP3 (free tier OK)
--   mp3_44100_192 — best MP3 (Creator+ tier — default)
--   pcm_44100     — uncompressed (Pro+ tier; largest file, best quality)
-- Whitelist guards against typos / unsupported values.
----------------------------------------------------------------------------
local TTS_OUTPUT_FORMATS = {
  mp3_44100_128 = true,
  mp3_44100_192 = true,
  pcm_44100     = true,
}

function M.get_tts_output_format()
  local v = get('tts_output_format', 'mp3_44100_192')
  if not TTS_OUTPUT_FORMATS[v] then return 'mp3_44100_192' end
  return v
end

function M.set_tts_output_format(v)
  if not TTS_OUTPUT_FORMATS[v] then return end
  set('tts_output_format', v)
end

----------------------------------------------------------------------------
-- Output layout: 'folder' (AI track jako child folder of source, default)
-- albo 'flat' (AI jako sibling track, legacy / pre-2026-05-10)
----------------------------------------------------------------------------
function M.get_output_layout()
  local v = get('output_layout', 'folder')
  if v ~= 'folder' and v ~= 'flat' then return 'folder' end
  return v
end

function M.set_output_layout(v)
  if v ~= 'folder' and v ~= 'flat' then v = 'folder' end
  set('output_layout', v)
end

----------------------------------------------------------------------------
-- Voice favorites — lokalna gwiazdka per voice_id. ElevenLabs API nie ma
-- favorites endpoint (favorited_at_unix tylko read-only przez web UI).
-- Persist jako JSON object {voice_id: true} w ExtState 'favorites'.
----------------------------------------------------------------------------
local _favorites_cache = nil
local function load_favorites()
  if _favorites_cache then return _favorites_cache end
  local raw = get('favorites', '')
  if raw == '' then _favorites_cache = {}; return _favorites_cache end
  local json_lib = require 'modules.lib.json'
  local ok, decoded = pcall(json_lib.decode, raw)
  if ok and type(decoded) == 'table' then
    _favorites_cache = decoded
  else
    _favorites_cache = {}
  end
  return _favorites_cache
end

local function save_favorites()
  local json_lib = require 'modules.lib.json'
  local ok, encoded = pcall(json_lib.encode, _favorites_cache or {})
  if ok then set('favorites', encoded) end
end

function M.is_favorite(voice_id)
  if not voice_id or voice_id == '' then return false end
  return load_favorites()[voice_id] == true
end

function M.set_favorite(voice_id, flag)
  if not voice_id or voice_id == '' then return end
  load_favorites()[voice_id] = flag and true or nil
  save_favorites()
end

function M.toggle_favorite(voice_id)
  M.set_favorite(voice_id, not M.is_favorite(voice_id))
end

function M.favorites_count()
  local n = 0
  for _ in pairs(load_favorites()) do n = n + 1 end
  return n
end

----------------------------------------------------------------------------
-- TTS voice presets (NS-2b polish B#6). Named save of voice + model + voice
-- settings — useful when a project has many characters with stable
-- voice/settings combinations. Quick-switch via dropdown next to voice
-- picker. Storage: ExtState 'tts_presets' JSON object { [name]: preset }.
-- Preset shape: { voice_id, voice_name, model_id, v3_stability, stability,
-- similarity, style, speed, speaker_boost }.
----------------------------------------------------------------------------
local function load_tts_presets()
  local raw = get('tts_presets', '')
  if raw == '' then return {} end
  local json_lib = require 'modules.lib.json'
  local ok, decoded = pcall(json_lib.decode, raw)
  if ok and type(decoded) == 'table' then return decoded end
  return {}
end

local function save_tts_presets_map(map)
  local json_lib = require 'modules.lib.json'
  local ok, encoded = pcall(json_lib.encode, map or {})
  if ok then set('tts_presets', encoded) end
end

function M.get_tts_preset(name)
  if not name or name == '' then return nil end
  return load_tts_presets()[name]
end

function M.save_tts_preset(name, preset)
  if not name or name == '' or type(preset) ~= 'table' then return false end
  local all = load_tts_presets()
  all[name] = preset
  save_tts_presets_map(all)
  return true
end

function M.delete_tts_preset(name)
  if not name or name == '' then return end
  local all = load_tts_presets()
  if all[name] == nil then return end
  all[name] = nil
  save_tts_presets_map(all)
end

function M.list_tts_preset_names()
  local names = {}
  for k in pairs(load_tts_presets()) do names[#names + 1] = k end
  table.sort(names)
  return names
end

----------------------------------------------------------------------------
-- NS-2c: dialogue cast presets — named save listy speakerów (cross-project
-- reuse). Storage: ExtState 'tts_dialogue_casts' JSON object { [name]: cast }.
-- Cast shape: array of { label, voice_id, voice_name }. speaker_id NIE
-- jest persisted — apply zwraca świeże ids per speaker.
----------------------------------------------------------------------------
local function load_dialogue_casts()
  local raw = get('tts_dialogue_casts', '')
  if raw == '' then return {} end
  local json_lib = require 'modules.lib.json'
  local ok, decoded = pcall(json_lib.decode, raw)
  if ok and type(decoded) == 'table' then return decoded end
  return {}
end

local function save_dialogue_casts_map(map)
  local json_lib = require 'modules.lib.json'
  local ok, encoded = pcall(json_lib.encode, map or {})
  if ok then set('tts_dialogue_casts', encoded) end
end

function M.get_tts_dialogue_cast(name)
  if not name or name == '' then return nil end
  return load_dialogue_casts()[name]
end

function M.save_tts_dialogue_cast(name, cast)
  if not name or name == '' or type(cast) ~= 'table' then return false end
  local all = load_dialogue_casts()
  all[name] = cast
  save_dialogue_casts_map(all)
  return true
end

function M.delete_tts_dialogue_cast(name)
  if not name or name == '' then return end
  local all = load_dialogue_casts()
  if all[name] == nil then return end
  all[name] = nil
  save_dialogue_casts_map(all)
end

function M.list_tts_dialogue_cast_names()
  local names = {}
  for k in pairs(load_dialogue_casts()) do names[#names + 1] = k end
  table.sort(names)
  return names
end

----------------------------------------------------------------------------
-- NS-B Dubbing: LLM provider configuration (4 providers pluggable).
-- Each provider has separate ExtState key entry (chmod-600 file when used by
-- workers). Active provider follows priority order if not explicitly set —
-- user nie musi konfigurować wszystkich 4 kluczy żeby zacząć.
----------------------------------------------------------------------------
-- W2 s6 (2026-06-11): + grok/mistral (user decision; pełny audyt providerów
-- z weryfikacją u źródeł — szczegóły PROGRESS s6). Nowi NA KOŃCU priorytetu:
-- auto-default istniejących userów bez zmian.
local LLM_PROVIDERS_PRIORITY = { 'anthropic', 'openai', 'gemini', 'deepseek', 'grok', 'mistral' }

-- Default model IDs verified 2026-06-11 against live API docs (poprzednia
-- weryfikacja 2026-05-12). Patrz audit findings w handover.
local LLM_DEFAULT_MODELS = {
  anthropic = 'claude-sonnet-4-6',      -- premium quality dla Polish dialogue
  openai    = 'gpt-5.4-mini',           -- sweet spot $0.75/$4.50 per 1M
  gemini    = 'gemini-2.5-flash',       -- free tier + balanced quality
  deepseek  = 'deepseek-v4-flash',      -- najtańszy ale untested PL quality
  grok      = 'grok-4.3',               -- frontier za $1.25/$2.50 per 1M
  mistral   = 'mistral-medium-latest',  -- EU data residency, $0.40/$2 per 1M
}

M.LLM_PROVIDERS_PRIORITY = LLM_PROVIDERS_PRIORITY
M.LLM_DEFAULT_MODELS     = LLM_DEFAULT_MODELS

function M.get_llm_provider_active()
  local v = get('llm_provider_active', '')
  if v == '' then return nil end
  return v
end

function M.set_llm_provider_active(name)
  if not name or name == '' then set('llm_provider_active', ''); return end
  for _, p in ipairs(LLM_PROVIDERS_PRIORITY) do
    if p == name then set('llm_provider_active', name); return end
  end
end

function M.get_llm_provider_key(name)
  if not name then return nil end
  local v = get('llm_key_' .. name, '')
  if v == '' then return nil end
  return v
end

function M.set_llm_provider_key(name, key)
  if not name then return end
  set('llm_key_' .. name, key or '')
end

function M.has_llm_provider_key(name)
  return M.get_llm_provider_key(name) ~= nil
end

function M.get_llm_provider_model(name)
  if not name then return nil end
  local v = get('llm_model_' .. name, '')
  if v == '' then return LLM_DEFAULT_MODELS[name] end
  return v
end

function M.set_llm_provider_model(name, model_id)
  if not name then return end
  set('llm_model_' .. name, model_id or '')
end

----------------------------------------------------------------------------
-- Per-feature LLM overrides (2026-06-11): funkcje używające LLM mogą mieć
-- własny provider/model — np. lekki model do TTS Enhance, mocny do tłumaczeń
-- dubbingu. '' = użyj globalnego (active provider / domyślny model providera).
-- Tasks: translate (Dubbing) · enhance (TTS) · sfx (SFX scene/rephrase).
----------------------------------------------------------------------------
local LLM_TASKS = { translate = true, enhance = true, sfx = true }
M.LLM_TASKS = LLM_TASKS

function M.get_llm_task_provider(task)
  if not LLM_TASKS[task] then return nil end
  local v = get('llm_task_provider_' .. task, '')
  if v == '' then return nil end
  return v
end

function M.set_llm_task_provider(task, name)
  if not LLM_TASKS[task] then return end
  if not name or name == '' then
    set('llm_task_provider_' .. task, '')
    return
  end
  for _, p in ipairs(LLM_PROVIDERS_PRIORITY) do
    if p == name then
      set('llm_task_provider_' .. task, name)
      return
    end
  end
end

function M.get_llm_task_model(task)
  if not LLM_TASKS[task] then return nil end
  local v = get('llm_task_model_' .. task, '')
  if v == '' then return nil end
  return v
end

function M.set_llm_task_model(task, model_id)
  if not LLM_TASKS[task] then return end
  set('llm_task_model_' .. task, model_id or '')
end

-- Returns list of providers with non-empty keys, in priority order.
function M.list_configured_llm_providers()
  local out = {}
  for _, p in ipairs(LLM_PROVIDERS_PRIORITY) do
    if M.has_llm_provider_key(p) then out[#out + 1] = p end
  end
  return out
end

-- First configured provider in priority order (auto-default per user choice).
function M.first_configured_llm_provider()
  for _, p in ipairs(LLM_PROVIDERS_PRIORITY) do
    if M.has_llm_provider_key(p) then return p end
  end
  return nil
end

-- Effective provider: active override if set & has key, else first configured.
function M.effective_llm_provider()
  local active = M.get_llm_provider_active()
  if active and M.has_llm_provider_key(active) then return active end
  return M.first_configured_llm_provider()
end

----------------------------------------------------------------------------
-- NS-B Dubbing: per-project + global defaults.
----------------------------------------------------------------------------
local DUB_TTS_MODELS = {
  eleven_multilingual_v2 = true,
  eleven_v3              = true,
  eleven_turbo_v2_5      = true,
  eleven_flash_v2_5      = true,
}

M.DUB_TTS_MODELS = DUB_TTS_MODELS

function M.get_dubbing_default_tts_model()
  local v = get('dubbing_default_tts_model', 'eleven_multilingual_v2')
  -- W2 M1: turbo_v2_5 oficjalnie deprecated (migrate → flash, funkcjonalnie
  -- równoważny, 50% taniej). Mapowanie dotyczy DEFAULTU (nowe projekty);
  -- istniejące projekty trzymają model w project.tts_model — nietykane.
  if v == 'eleven_turbo_v2_5' then return 'eleven_flash_v2_5' end
  if not DUB_TTS_MODELS[v] then return 'eleven_multilingual_v2' end
  return v
end

function M.set_dubbing_default_tts_model(v)
  if not DUB_TTS_MODELS[v] then v = 'eleven_multilingual_v2' end
  set('dubbing_default_tts_model', v)
end

function M.get_dubbing_default_style_preset()
  return get('dubbing_default_style_preset', 'drama_modern')
end

function M.set_dubbing_default_style_preset(v)
  set('dubbing_default_style_preset', v or 'drama_modern')
end

-- Forced alignment auto-trigger po Generate dub (user-confirmed AD7 = TAK auto).
function M.get_dubbing_forced_align_auto()
  return get('dubbing_forced_align_auto', '1') == '1'
end

function M.set_dubbing_forced_align_auto(flag)
  set('dubbing_forced_align_auto', flag and '1' or '0')
end

-- Voice Isolator pre-clean dla dubbing source — opt-in per project (AD8 default).
function M.get_dubbing_voice_isolator_preclean()
  return get('dubbing_voice_isolator_preclean', '0') == '1'
end

function M.set_dubbing_voice_isolator_preclean(flag)
  set('dubbing_voice_isolator_preclean', flag and '1' or '0')
end

-- Default target languages (multi-select per Correction 2) — JSON array.
-- Empty = user musi wybrać per project. NIE hardcode'ujemy 'pl'.
function M.get_dubbing_default_target_languages()
  local raw = get('dubbing_default_target_languages', '')
  if raw == '' then return {} end
  local json_lib = require 'modules.lib.json'
  local ok, decoded = pcall(json_lib.decode, raw)
  if ok and type(decoded) == 'table' then return decoded end
  return {}
end

function M.set_dubbing_default_target_languages(langs)
  if type(langs) ~= 'table' then return end
  local json_lib = require 'modules.lib.json'
  local ok, encoded = pcall(json_lib.encode, langs)
  if ok then set('dubbing_default_target_languages', encoded) end
end

-- NS-B M2.6: Anthropic prompt caching toggle. ON = 90% off na cached system prompt
-- after first call (5min TTL). OFF = full price every call. Default ON.
function M.get_dubbing_anthropic_prompt_caching()
  return get('dubbing_anthropic_prompt_caching', '1') == '1'
end

function M.set_dubbing_anthropic_prompt_caching(flag)
  set('dubbing_anthropic_prompt_caching', flag and '1' or '0')
end

-- NS-B M2.5: Cost tier alert threshold (USD). When estimated total of a single
-- Generate-dub run exceeds this, panel shows warning + requires user confirm.
-- Default $20 (close to Creator $22/mc tier limit).
function M.get_dubbing_cost_alert_threshold_usd()
  local raw = get('dubbing_cost_alert_threshold_usd', '20')
  local n = tonumber(raw)
  if not n or n < 0 then return 20 end
  return n
end

function M.set_dubbing_cost_alert_threshold_usd(usd)
  local n = tonumber(usd)
  if not n or n < 0 then n = 0 end
  set('dubbing_cost_alert_threshold_usd', tostring(n))
end

-- M3.6: per-word splice (experimental). When ON + forced alignment data available
-- + word count match w 20% tolerance → splicer creates per-word REAPER items
-- aligned do source word starts. Default OFF — typical workflow uses full-segment.
function M.get_dubbing_per_word_splice()
  return get('dubbing_per_word_splice', '0') == '1'
end

function M.set_dubbing_per_word_splice(flag)
  set('dubbing_per_word_splice', flag and '1' or '0')
end

-- Force every dub item span to equal source segment span.
-- ON  = full-segment splice stretches TTS audio (uniform) to fit source span;
--       per-word splice already matches span by construction. No item overlap
--       possible. Speech may sound slightly slower/faster than TTS native.
-- OFF = full-segment splice uses TTS audio native length (speech onset aligned
--       at seg.t_start - lead_sil). Adjacent items same speaker can overlap if
--       TTS longer than source span.
function M.get_dubbing_force_segment_span()
  return get('dubbing_force_segment_span', '1') == '1'
end

function M.set_dubbing_force_segment_span(flag)
  set('dubbing_force_segment_span', flag and '1' or '0')
end

-- Short-segment threshold (seconds). Segments shorter than this BYPASS
-- force_segment_span — short interjections ("tak", "no", "ok", "potwierdzam")
-- shouldn't be aggressively stretched even when force_span is ON. They get
-- native TTS length instead, may briefly overlap with neighbors (acceptable
-- because they're short).
function M.get_dubbing_short_segment_threshold_s()
  local raw = get('dubbing_short_segment_threshold_s', '0.8')
  local n = tonumber(raw)
  if not n or n < 0 then return 0.8 end
  return n
end

function M.set_dubbing_short_segment_threshold_s(secs)
  local n = tonumber(secs)
  if not n or n < 0 then n = 0 end
  set('dubbing_short_segment_threshold_s', tostring(n))
end

-- W2 M1: tempo-fit bounds dla full-segment splice — dopuszczalny zakres
-- rozciągnięcia REGIONU MOWY (rate = take_time / source_time; >1 = wolniej).
-- Defaults 0.88/1.12 = dokładnie clamp per-word splice (jedna mentalna skala;
-- full-segment rozciąga słowa uniformnie, pauzy nic nie amortyzują, więc band
-- nie może być luźniejszy). Kalibracja live-loop — patrz PHASE-W2 §2.
function M.get_dubbing_fit_bounds()
  local lo = tonumber(get('dubbing_fit_r_min', '0.88')) or 0.88
  local hi = tonumber(get('dubbing_fit_r_max', '1.12')) or 1.12
  if lo <= 0 or lo >= 1 then lo = 0.88 end
  if hi <= 1 or hi > 2 then hi = 1.12 end
  return lo, hi
end

function M.set_dubbing_fit_bounds(r_min, r_max)
  local lo = tonumber(r_min)
  local hi = tonumber(r_max)
  if lo and lo > 0 and lo < 1 then set('dubbing_fit_r_min', tostring(lo)) end
  if hi and hi > 1 and hi <= 2 then set('dubbing_fit_r_max', tostring(hi)) end
end

-- Sliding context window for LLM translation. ON = each segment translation
-- gets 2 previous segments (source + translation) + 1 next (source only)
-- as context. Improves continuity for cut-sentence segments, pronoun resolution,
-- register/tone preservation. Cost: ~3-4x input tokens (output unchanged).
-- Anthropic prompt cache still covers system prompt (~90% of cost preserved).
-- Sequencing: segment N waits for N-1 / N-2 to be translated (best-effort —
-- still parallel within independent groups).
function M.get_dubbing_translate_context_enabled()
  return get('dubbing_translate_context_enabled', '1') == '1'
end

function M.set_dubbing_translate_context_enabled(flag)
  set('dubbing_translate_context_enabled', flag and '1' or '0')
end

----------------------------------------------------------------------------
-- NS-F (Repair mode) settings
----------------------------------------------------------------------------
-- M1.5: auto-match volume TTS → source (RMS-based, ±12 dB clamp).
-- Wycisza "skok głośności" gdy wstawiony fragment różni się głośnością
-- od reszty nagrania (TTS jest normalized LUFS by ElevenLabs, oryginał
-- po mixingu/dynamics ma inną).
function M.get_repair_auto_volume_match()
  return get('repair_auto_volume_match', '1') == '1'
end

function M.set_repair_auto_volume_match(flag)
  set('repair_auto_volume_match', flag and '1' or '0')
end

return M
