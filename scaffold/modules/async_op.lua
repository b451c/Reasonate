-- modules/async_op.lua
-- Wspólna warstwa async (audit fix M2-1/M2-2, 2026-06-10).
--
-- Historia: wzorzec spawn/poll/retry/stale żył w ~4 rozbieżnych kopiach
-- (job_manager / tts / dubbing / repair — repair BEZ retry, stale tylko
-- w dubbing). Każdy fix hydrauliki trzeba było ręcznie portować N razy
-- (HTTP 0 diagnostics portowane >=2x per PROGRESS.md). Ten moduł jest
-- jedynym właścicielem: stałych retry/backoff/stale, detekcji martwych
-- workerów, parsowania sentineli i hintów curl exit-code.
--
-- Zależności: tylko util (pure) — moduł bezpieczny do require z każdego
-- miejsca, bez ryzyka cyklu.

local util = require 'modules.util'
local json = require 'modules.lib.json'

local M = {}

----------------------------------------------------------------------------
-- Stałe (jedyne źródło prawdy — wcześniej zduplikowane per-mode)
----------------------------------------------------------------------------
M.MAX_RETRIES   = 3             -- próby retry po HTTP 429
M.RETRY_BACKOFF = { 1, 2, 4 }   -- sekundy backoff per próba (exponential)

-- Stale timeout: ŻYWY worker zawsze pisze sentinel — curl ma --max-time
-- <=300s we wszystkich workers/*.sh (worker.sh STS=300, voice_op tts=120 /
-- dialogue=180, llm=120, forced_align=180). Brak sentinela po 330s =
-- proces martwy (kill/crash), nie wolna sieć. 330 = max(curl max-time)
-- + 30s grace na spawn/FS. NIE skracać poniżej 300 — fałszywe timeouty
-- ubiłyby joby z żywym curlem przy wolnym uploadzie.
-- M6-8 (2026-07-11): 330 → 630 = max(curl --max-time po workerach: stt 600,
-- worker.sh STS 420, music 300) + 30 s buffer. Świadoma zmiana niezmiennika
-- czasowego: legalny długi upload STT nie może być ubijany jako "stale".
M.HANDLE_STALE_TIMEOUT = 630

----------------------------------------------------------------------------
-- force_error_if_stale(handle, label) → bool
--
-- Wymuś status='error' na handle'u który wisi w 'running' dłużej niż
-- HANDLE_STALE_TIMEOUT — error branch caller'a robi fallback/cleanup.
-- Handles bez started_at (forced_align/stt/isolator) są stemplowane przy
-- pierwszym wywołaniu (_stale_t0) — timeout liczy się od pierwszego polla,
-- co dla wywołań co tick = od spawnu z dokładnością do 1 klatki.
--
-- Wzorzec wyciągnięty 1:1 z modes/dubbing.lua (PM-era local helper);
-- dubbing od 2026-06-10 używa tej wersji.
----------------------------------------------------------------------------
function M.force_error_if_stale(handle, label)
  if not handle then return false end
  -- In-flight status: 'running' (voice_admin/llm/forced_align/isolator)
  -- lub 'pending' (stt.poll_transcribe convention).
  if handle.status ~= 'running' and handle.status ~= 'pending' then return false end
  local t0 = handle.started_at or handle._stale_t0
  if not t0 then
    handle._stale_t0 = util.now()
    return false
  end
  local elapsed = util.now() - t0
  if elapsed < M.HANDLE_STALE_TIMEOUT then return false end
  handle.status = 'error'
  handle.error  = ('%s stalled — no response after %ds (worker dead?)')
    :format(label or 'handle', math.floor(elapsed))
  return true
end

----------------------------------------------------------------------------
-- schedule_retry_429(handle) → bool
--
-- Jednolite planowanie retry po rate-limit. Mutuje handle:
--   _retry_count (1..MAX_RETRIES), _retry_at (util.now() + backoff).
-- Zwraca true gdy retry zaplanowany; false gdy limit wyczerpany / błąd
-- nie jest 429. Caller respawnuje gdy util.now() >= handle._retry_at.
----------------------------------------------------------------------------
function M.is_rate_limit_error(handle)
  if not handle then return false end
  if handle.http_code == 429 then return true end
  local err = tostring(handle.error or '')
  return err:find('429', 1, true) ~= nil
end

function M.schedule_retry_429(handle)
  if not M.is_rate_limit_error(handle) then return false end
  local next_count = (handle._retry_count or 0) + 1
  if next_count > M.MAX_RETRIES then return false end
  handle._retry_count = next_count
  -- M6-4: serwerowy Retry-After (z dumpu nagłówków — read_sentinel) wygrywa
  -- z naszym backoffem, gdy jest dłuższy; 429 rate vs concurrency mają
  -- różne okna. Cap 30 s — dłużej nie blokujemy pętli edycyjnej.
  local delay = M.RETRY_BACKOFF[next_count] or 4
  local ra = tonumber(handle.retry_after)
  if ra and ra > delay then delay = math.min(ra, 30) end
  handle._retry_at = util.now() + delay
  return true
end

----------------------------------------------------------------------------
-- read_sentinel(handle) → { http_code, curl_exit, stderr }
--
-- Czyta + usuwa triplet sentinel files (<path> / .stderr / .curl_exit)
-- pisany przez KAŻDY workers/*.sh. Pre-extraction (M2-1) ten blok żył w
-- 6 kopiach: voice_admin / forced_align / llm / stt / voice_isolator /
-- job_manager — przy czym llm i job_manager USUWAŁY .stderr/.curl_exit
-- bez czytania (zero diagnostyki HTTP 0), a voice_admin nie przepisywał
-- http_code na handle (dubbing TTS retry-on-429 był przez to martwy).
----------------------------------------------------------------------------
function M.read_sentinel(handle)
  local code_raw      = util.read_file(handle.sentinel_path) or ''
  local stderr_raw    = util.read_file(handle.sentinel_path .. '.stderr') or ''
  local curl_exit_raw = util.read_file(handle.sentinel_path .. '.curl_exit') or ''
  -- M6-4/M6-6: dump nagłówków (-D w każdym workerze) → Retry-After (backoff
  -- honoruje okno serwera) + character-cost (REALNY koszt do licznika
  -- zamiast liczenia znaków po naszej stronie). Zapis na handle.
  local headers_raw = util.read_file(handle.sentinel_path .. '.headers') or ''
  handle.retry_after    = tonumber(headers_raw:match('[Rr]etry%-[Aa]fter:%s*(%d+)'))
  handle.character_cost = tonumber(headers_raw:match('[Cc]haracter%-[Cc]ost:%s*(%d+)'))
  os.remove(handle.sentinel_path)
  os.remove(handle.sentinel_path .. '.stderr')
  os.remove(handle.sentinel_path .. '.curl_exit')
  os.remove(handle.sentinel_path .. '.headers')
  return {
    http_code = tonumber((code_raw:gsub('%s', ''))) or 0,
    curl_exit = tonumber((curl_exit_raw:gsub('%s', ''))) or 0,
    stderr    = stderr_raw,
  }
end

----------------------------------------------------------------------------
-- curl_exit_hint(curl_exit) → ' (human hint)' lub ''
-- Tabela hintów była zduplikowana verbatim w voice_admin + forced_align
-- (+wariant w stt) — każdy update wymagał N portów.
----------------------------------------------------------------------------
function M.curl_exit_hint(curl_exit)
  if curl_exit == 6 then
    return ' (DNS lookup failed — check internet)'
  elseif curl_exit == 7 then
    return ' (could not connect to API host)'
  elseif curl_exit == 22 then
    return ' (HTTP error — see body)'
  elseif curl_exit == 28 then
    return ' (timeout — audio too large, slow upload, or API processing took too long)'
  elseif curl_exit == 35 or curl_exit == 60 then
    return ' (SSL/TLS error — check curl + cert chain)'
  elseif curl_exit == 56 then
    return ' (network recv failure — connection dropped)'
  elseif curl_exit ~= 0 then
    return (' (curl exit %d)'):format(curl_exit)
  end
  return ''
end

----------------------------------------------------------------------------
-- format_http_error(label, sent, body) → user-facing message
--
-- Najpierw próbuje ElevenLabs JSON {detail}; fallback = transport
-- diagnostics (curl hint + stderr + body head). label='' → 'HTTP %d: …'
-- (format voice_admin); label='forced-align' → 'HTTP %d (forced-align): …'.
----------------------------------------------------------------------------
function M.format_http_error(label, sent, body)
  body = body or ''
  local prefix = (label and label ~= '') and (' (' .. label .. ')') or ''
  local ok, decoded = pcall(json.decode, body)
  if ok and type(decoded) == 'table' and decoded.detail then
    local d = decoded.detail
    local dmsg = (type(d) == 'table') and (d.message or d.status or 'API error') or tostring(d)
    return ('HTTP %d%s: %s'):format(sent.http_code, prefix, dmsg)
  end
  local stderr_clean = (sent.stderr or ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 200)
  local body_clean   = body:sub(1, 200)
  return ('HTTP %d%s%s%s%s'):format(
    sent.http_code,
    prefix,
    M.curl_exit_hint(sent.curl_exit),
    stderr_clean ~= '' and (' — ' .. stderr_clean) or '',
    body_clean   ~= '' and (' · body: ' .. body_clean) or '')
end

return M
