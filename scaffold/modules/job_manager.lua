-- modules/job_manager.lua
-- Async pipeline: queue + active jobs + sentinel polling.
--
-- Lifecycle:
--   queued     — w kolejce, nie spawnięty
--   sending    — worker.sh leci (ExecProcess -1), curl POST do ElevenLabs
--   done       — sentinel pojawił się + import wykonany
--   error      — sentinel pojawił się z http_code != 2xx LUB import się wywalił
--   cancelled  — user kliknął Cancel zanim job się spawnął (queue dropped)
--
-- tick() wywoływane KAŻDY frame przez defer loop:
--   1. dla każdego active: sprawdź czy istnieje done sentinel → handle_completion
--   2. dla każdego wolnego slotu (active < max_concurrent): pop queue → spawn

local helpers   = require 'modules.reaper_helpers'
local importer  = require 'modules.importer'
local api       = require 'modules.api'
local config    = require 'modules.config'
local colors    = require 'modules.colors'
local util      = require 'modules.util'
local json      = require 'modules.lib.json'
local cache     = require 'modules.cache'
local isolator  = require 'modules.voice_isolator'
local async_op  = require 'modules.async_op'

local M = {}

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------
local queue     = {}     -- waiting jobs (FIFO)
local active    = {}     -- in-flight by id
local cancelled = false
-- batch_jobs: persistent ref do wszystkich jobów aktualnego batchu (NS-1).
-- Te same table refs co queue/active — `.status` mutuje in place. Resolved
-- jobs zostają tu nawet po usunięciu z queue/active. Reset on enqueue_batch.
-- Modal czyta to żeby pokazać per-job status (queued/sending/done/error).
local batch_jobs = {}

-- Stats batchu (resetowane przy enqueue_batch)
local stats = {
  total = 0, done = 0, error = 0, cancelled = 0, cache_hits = 0, retries = 0,
  isolate_skipped = 0,   -- NS-C: items < MIN_DURATION_SECS, fell back to raw audio
  started_at = nil, finished_at = nil,
  last_error_msg = nil,
}

-- Rate-limit retry + stale timeout — wspólne stałe z modules/async_op.lua
-- (audit M2-2, 2026-06-10). Lokalne aliasy dla istniejących call sites.
local MAX_RETRIES   = async_op.MAX_RETRIES
local RETRY_BACKOFF = async_op.RETRY_BACKOFF

M.max_concurrent = 3   -- zmienialny przez config.get_concurrency() w przyszłości

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------
local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

local function active_count()
  local n = 0
  for _ in pairs(active) do n = n + 1 end
  return n
end

-- NS-C: read isolate flag z tracku którego dotyczy source item. Auto-resolve
-- żeby callers (batch_dialog / variants) nie musieli pass'ować flagi explicit.
local function should_isolate_for_item(source_item_guid)
  if not source_item_guid or source_item_guid == '' then return false end
  local item = helpers.find_item_by_guid(source_item_guid)
  if not item then return false end
  local tr = reaper.GetMediaItem_Track(item)
  if not tr then return false end
  return helpers.get_track_isolate_flag(tr)
end

local function build_job(spec)
  -- M1-3 (audit 2026-07): prefiks 'conv_' — spójny z resztą jobów
  -- (stt_/align_/tts_...). Goły '%x_%x' nie łapał się na housekeeping regex
  -- (wymaga prefiksu przed pierwszym '_') → sieroty VR-convert żyły wiecznie.
  local job_id = ('conv_%x_%x'):format(os.time(), math.random(0, 0xFFFFFF))
  -- Per-track override (jeśli jest) lub defaults — przekazane przez spec.
  local settings = spec.settings or helpers.default_voice_settings()
  -- Seed: spec.seed_override (multi-take z random) ma pierwszeństwo;
  -- inaczej deterministic hash(item_guid + voice_id).
  local seed = spec.seed_override
            or (util.simple_hash(spec.source_item_guid .. '|' .. spec.voice_id) % 4294967295)
  local model_id = config.get_model_id()
  local output_format = config.get_output_format()
  local isolate_audio = should_isolate_for_item(spec.source_item_guid)

  -- Cache key + ścieżka. Output mp3 ZAWSZE ląduje w cache (kolejne konwersje
  -- z tymi samymi paramami → cache hit, bez API).
  local cache_key = cache.compute_key({
    source_path   = spec.source_path,
    source_size   = spec.source_size,
    source_length = spec.source_length,
    voice_id      = spec.voice_id,
    model_id      = model_id,
    seed          = seed,
    settings      = settings,
    output_format = output_format,
    isolate_audio = isolate_audio,
    -- Trimmed/playrated items rendered via AudioAccessor: distinct cache
    -- key per (offs, length, playrate) combo (untrimmed → backward compat).
    item_offs     = spec.render_info and spec.render_info.item_offs,
    item_length   = spec.render_info and spec.render_info.item_length,
    playrate      = spec.render_info and spec.render_info.playrate,
  })
  local output_path = cache.path_for(cache_key, 'mp3')

  return {
    id                = job_id,
    status            = 'queued',
    -- NS-C: phase = 'isolate' gdy track flag ON i jeszcze nie wyczyszczone.
    -- Po isolate done, phase → 'convert' + input_path swap na cleaned.
    phase             = (isolate_audio and not util.file_exists(output_path))
                        and 'isolate' or 'convert',
    isolate_audio     = isolate_audio,
    isolate_handle    = nil,
    source_item_guid  = spec.source_item_guid,
    voice_id          = spec.voice_id,
    voice_name        = spec.voice_name,
    audio_seconds     = spec.audio_seconds,
    item_label        = spec.item_label,
    input_path        = spec.input_path,
    -- source identity (do P_EXT writes)
    source_path       = spec.source_path,
    source_size       = spec.source_size,
    source_length     = spec.source_length,
    --
    model_id          = model_id,
    output_format     = output_format,
    remove_bg         = config.get_remove_bg_noise(),
    settings          = settings,
    seed              = seed,
    cache_key         = cache_key,
    cache_hit         = util.file_exists(output_path),
    output_path       = output_path,
    done_sentinel     = tmp_dir() .. path_sep() .. job_id .. '.done',
    multi_take        = spec.multi_take or false,
    -- Phase 7: {index, count, offset_secs, plan_hash} gdy item >290s pocięty
    -- na kawałki (jeden job per kawałek); nil dla zwykłych konwersji.
    chunk             = spec.chunk,
    enqueued_at       = util.now(),
    started_at        = nil,
    finished_at       = nil,
    -- expected_duration usunięte (audit M1-2, 2026-06-10): pole było pisane
    -- a nigdy czytane; stale detection używa async_op.HANDLE_STALE_TIMEOUT
    -- (oparty o curl --max-time, nie o szacunek długości audio).
    error_msg         = nil,
  }
end

----------------------------------------------------------------------------
-- Public: introspection (for GUI)
----------------------------------------------------------------------------
function M.queue_length() return #queue end
function M.active_count() return active_count() end
function M.has_active() return next(active) ~= nil or #queue > 0 end

function M.get_active_jobs()
  local out = {}
  for _, j in pairs(active) do out[#out + 1] = j end
  table.sort(out, function(a, b) return (a.started_at or 0) < (b.started_at or 0) end)
  return out
end

function M.get_queue() return queue end

function M.get_stats()
  return {
    total = stats.total, done = stats.done,
    error = stats.error, cancelled = stats.cancelled,
    cache_hits = stats.cache_hits or 0,
    retries = stats.retries or 0,
    isolate_skipped = stats.isolate_skipped or 0,
    started_at = stats.started_at, finished_at = stats.finished_at,
    last_error_msg = stats.last_error_msg,
  }
end

function M.in_flight_item_guids()
  local s = {}
  for _, job in pairs(active) do
    if job.source_item_guid then s[job.source_item_guid] = true end
  end
  return s
end

----------------------------------------------------------------------------
-- Public: enqueue batch
--
-- specs: array of { source_item_guid, voice_id, voice_name, audio_seconds,
--                   item_label, input_path }
--
-- output_dir: gdzie zapisać wyniki mp3 (zazwyczaj <project>/reasonate_output/)
----------------------------------------------------------------------------
function M.enqueue_batch(specs)
  cancelled = false
  if not M.has_active() then
    stats = {
      total = 0, done = 0, error = 0, cancelled = 0, cache_hits = 0, retries = 0,
      isolate_skipped = 0,
      started_at = util.now(), finished_at = nil, last_error_msg = nil,
    }
    batch_jobs = {}   -- fresh batch — reset NS-1 tracking
  end
  for _, spec in ipairs(specs) do
    local job = build_job(spec)
    table.insert(queue, job)
    table.insert(batch_jobs, job)
    stats.total = stats.total + 1
  end
end

----------------------------------------------------------------------------
-- NS-1: persistent batch view dla modal.
-- Returns array of job refs (queued + in-flight + resolved). `.status` field
-- reflects current state. Order = enqueue order.
----------------------------------------------------------------------------
function M.get_batch_jobs()
  return batch_jobs
end

----------------------------------------------------------------------------
-- Public: cancel
----------------------------------------------------------------------------
function M.cancel_all()
  cancelled = true
  -- Drop queue (jobs które jeszcze nie ruszyły)
  for _, job in ipairs(queue) do
    job.status = 'cancelled'
    stats.cancelled = stats.cancelled + 1
  end
  queue = {}
  -- In-flight zostaje — czekamy aż curl skończy (per user choice).
end

function M.is_cancelled() return cancelled end

----------------------------------------------------------------------------
-- Internal: handle job completion
----------------------------------------------------------------------------
local function handle_completion(job)
  -- Sentinel + curl diagnostics przez shared async_op (M2-1, 2026-06-10).
  -- Pre-fix: .stderr/.curl_exit usuwane BEZ czytania — transport error
  -- (HTTP 0) w VR convert path nie miał żadnej diagnozy dla usera.
  local sent = async_op.read_sentinel({ sentinel_path = job.done_sentinel })
  local http_code = sent.http_code
  job.finished_at = util.now()

  -- Successful HTTP response
  if http_code >= 200 and http_code < 300 then
    local sz = util.file_size(job.output_path)
    if not sz or sz < 256 then
      job.status = 'error'
      job.error_msg = 'output file empty/truncated (size=' .. tostring(sz or 0) .. ')'
      os.remove(job.output_path)
    else
      local item = helpers.find_item_by_guid(job.source_item_guid)
      if not item then
        job.status = 'error'
        job.error_msg = 'source item disappeared during conversion'
        os.remove(job.output_path)
      else
        reaper.Undo_BeginBlock()
        local import_fn = job.chunk and importer.import_chunk_result or importer.import_result
        local ok, err = pcall(import_fn, item, job.output_path, {
          voice_id       = job.voice_id,
          voice_name     = job.voice_name,
          model_id       = job.model_id,
          seed           = job.seed,
          voice_settings = job.settings,
          source_path    = job.source_path,
          source_size    = job.source_size,
          source_length  = job.source_length,
          multi_take     = job.multi_take,
          chunk          = job.chunk,
        })
        reaper.Undo_EndBlock(job.chunk
          and ('Reasonate: Convert %s (part %d/%d)'):format(
                job.voice_name or 'item', job.chunk.index, job.chunk.count)
          or  ('Reasonate: Convert %s'):format(job.voice_name or 'item'), -1)
        if ok then
          job.status = 'done'
          stats.done = stats.done + 1
          cache.touch(job.cache_key)   -- M2-3: LRU index dla eviction
        else
          job.status = 'error'
          job.error_msg = 'import failed: ' .. tostring(err)
        end
      end
    end
  else
    -- HTTP error: JSON error od ElevenLabs ląduje w output_path.part
    -- (M1-2 atomic download — worker publikuje do cache path tylko po 2xx)
    local part_path = job.output_path .. '.part'
    local body = util.read_file(part_path) or ''
    os.remove(part_path)

    -- Rate limit (429) → retry z exponential backoff (1s, 2s, 4s, max 3 razy).
    -- Job wraca do queue z `retry_at` timestamp; spawn loop pomija dopóki nie nadejdzie.
    if http_code == 429 then
      job.retry_count = (job.retry_count or 0) + 1
      if job.retry_count <= MAX_RETRIES then
        local backoff = RETRY_BACKOFF[job.retry_count] or 4
        job.status      = 'queued'
        job.started_at  = nil
        job.finished_at = nil
        job.retry_at    = util.now() + backoff
        table.insert(queue, job)
        stats.retries = (stats.retries or 0) + 1
        return  -- nie liczymy jeszcze jako error
      end
    end

    -- JSON detail / transport diagnostics (curl hint + stderr) — shared (M2-1).
    local msg = async_op.format_http_error(nil, sent, body)
    if (job.retry_count or 0) > 0 then
      msg = msg .. (' (after %d retries)'):format(job.retry_count)
    end
    job.status = 'error'
    job.error_msg = msg

    local item = helpers.find_item_by_guid(job.source_item_guid)
    if item then
      reaper.GetSetMediaItemInfo_String(item, 'P_EXT:Reasonate.error', msg, true)
      colors.apply_to_item(item, 'error')
      reaper.UpdateArrange()
    end
  end

  if job.status == 'error' then
    stats.error = stats.error + 1
    stats.last_error_msg = job.error_msg
  end
end

----------------------------------------------------------------------------
-- Internal: handle cache hit (output mp3 już istnieje, no curl needed)
----------------------------------------------------------------------------
local function handle_cache_hit(job)
  job.started_at  = util.now()
  job.finished_at = util.now()

  local item = helpers.find_item_by_guid(job.source_item_guid)
  if not item then
    job.status = 'error'
    job.error_msg = 'source item disappeared (cache hit)'
    stats.error = stats.error + 1
    stats.last_error_msg = job.error_msg
    return
  end

  reaper.Undo_BeginBlock()
  local import_fn = job.chunk and importer.import_chunk_result or importer.import_result
  local ok, err = pcall(import_fn, item, job.output_path, {
    voice_id       = job.voice_id,
    voice_name     = job.voice_name,
    model_id       = job.model_id,
    seed           = job.seed,
    voice_settings = job.settings,
    source_path    = job.source_path,
    source_size    = job.source_size,
    source_length  = job.source_length,
    chunk          = job.chunk,
  })
  reaper.Undo_EndBlock(
    ('Reasonate: Cache hit %s'):format(job.voice_name or 'item'), -1)

  if ok then
    job.status = 'done'
    stats.done = stats.done + 1
    stats.cache_hits = (stats.cache_hits or 0) + 1
    cache.touch(job.cache_key)   -- M2-3: LRU index dla eviction
  else
    job.status = 'error'
    job.error_msg = 'cache import failed: ' .. tostring(err)
    stats.error = stats.error + 1
    stats.last_error_msg = job.error_msg
  end
end

----------------------------------------------------------------------------
-- Internal: fail_stale_job — wspólny error-path dla martwego workera
-- (audit M1-2, 2026-06-10). Worker może umrzeć bez zapisania sentinela
-- (kill / crash / reboot) — pre-fix job wisiał w `active` na zawsze i
-- TRWALE zajmował slot concurrency (max 3); dwie takie śmierci = batch
-- stoi bez diagnozy. Żywy worker zawsze pisze sentinel <=~300s (curl
-- --max-time), więc brak po HANDLE_STALE_TIMEOUT (330s) = proces martwy.
-- Mirror error-path handle_completion (P_EXT error + kolor na itemie).
----------------------------------------------------------------------------
local function fail_stale_job(job, label)
  job.status      = 'error'
  job.finished_at = util.now()
  job.error_msg   = ('%s stalled — no response after %ds (worker dead?)')
    :format(label, math.floor(util.now() - (job.started_at or util.now())))
  stats.error = stats.error + 1
  stats.last_error_msg = job.error_msg
  local item = helpers.find_item_by_guid(job.source_item_guid)
  if item then
    reaper.GetSetMediaItemInfo_String(item, 'P_EXT:Reasonate.error', job.error_msg, true)
    colors.apply_to_item(item, 'error')
    reaper.UpdateArrange()
  end
end

local function job_is_stale(job)
  return job.started_at
     and (util.now() - job.started_at) > async_op.HANDLE_STALE_TIMEOUT
end

----------------------------------------------------------------------------
-- Public: tick — wywoływane KAŻDY frame z defer loop
--
-- Returns: completed (int), errored (int), spawned (int)
----------------------------------------------------------------------------
function M.tick()
  local completed, errored, spawned = 0, 0, 0

  -- 1a. NS-C: poll active isolate handles. On done, swap input_path do cleaned
  -- i re-queue z phase='convert'. On error, kill job (nie kontynuujemy convert
  -- na potencjalnie niekompletnym audio). Stale check (M1-2): martwy worker
  -- isolate → error zamiast wiecznego 'running'.
  for id, job in pairs(active) do
    if job.phase == 'isolate' and job.isolate_handle then
      isolator.poll(job.isolate_handle)
      local h = job.isolate_handle
      if h.status == 'running' and job_is_stale(job) then
        h.status = 'error'
        h.error  = 'isolate worker stalled (no sentinel)'
      end
      if h.status == 'done' then
        job.input_path     = h.result
        job.phase          = 'convert'
        job.isolate_handle = nil
        job.status         = 'queued'
        active[id]         = nil
        table.insert(queue, job)   -- re-queue dla convert spawn loop
      elseif h.status == 'error' then
        active[id]    = nil
        job.status    = 'error'
        job.error_msg = 'isolate failed: ' .. tostring(h.error)
        stats.error   = stats.error + 1
        stats.last_error_msg = job.error_msg
        errored = errored + 1
      end
    end
  end

  -- 1b. Sprawdź active convert jobs na sentinel files; bez sentinela po
  -- stale timeout → fail (M1-2, slot zwolniony, batch może się dokończyć).
  for id, job in pairs(active) do
    if job.phase == 'convert' then
      if util.file_exists(job.done_sentinel) then
        handle_completion(job)
        active[id] = nil
        if job.status == 'done' then completed = completed + 1
        elseif job.status == 'error' then errored = errored + 1 end
      elseif job_is_stale(job) then
        fail_stale_job(job, 'convert')
        active[id] = nil
        errored = errored + 1
      end
    end
  end

  -- 2. Cache hits najpierw (instant import, nie zajmują slotu concurrency)
  local i = 1
  while i <= #queue do
    local job = queue[i]
    if cancelled then
      table.remove(queue, i)
      job.status = 'cancelled'
      stats.cancelled = stats.cancelled + 1
    elseif job.cache_hit then
      table.remove(queue, i)
      handle_cache_hit(job)
      if job.status == 'done' then completed = completed + 1
      else errored = errored + 1 end
    else
      i = i + 1
    end
  end

  -- 3. API calls — concurrency limited. Pomijamy joby w retry backoff
  --    (retry_at > teraz) i zostawiamy je w queue dla późniejszego ticka.
  --    NS-C: gdy phase='isolate', spawn isolate; gdy phase='convert', spawn convert.
  local now = util.now()
  i = 1
  while i <= #queue and active_count() < M.max_concurrent do
    local job = queue[i]
    if cancelled then
      table.remove(queue, i)
      job.status = 'cancelled'
      stats.cancelled = stats.cancelled + 1
    elseif job.retry_at and job.retry_at > now then
      i = i + 1   -- not ready, skip do następnego ticka
    elseif job.phase == 'isolate' then
      table.remove(queue, i)
      job.started_at = job.started_at or util.now()
      local h = isolator.spawn_isolate(job.input_path, {
        duration_secs = job.audio_seconds,
      })
      if h.status == 'done' then
        -- Cache hit (audio już cleaned previously) — instant swap, re-queue.
        job.input_path     = h.result
        job.phase          = 'convert'
        job.isolate_handle = nil
        job.status         = 'queued'
        table.insert(queue, job)
        -- nie zwiększamy `spawned` ani nie zajmujemy slotu — instant path.
        -- nie zwiększamy `i` bo elementy się przesunęły; loop while sprawdzi #queue.
      elseif h.status == 'skipped' then
        -- NS-C: item < 4.6s — Voice Isolator API odrzuca. Fall-through z raw
        -- audio: phase='convert', input_path zostaje original, re-queue.
        -- Stats counter dla footer toast.
        job.phase             = 'convert'
        job.isolate_handle    = nil
        job.isolate_skipped   = true
        job.isolate_skip_reason = h.reason or 'unknown'
        job.status            = 'queued'
        stats.isolate_skipped = (stats.isolate_skipped or 0) + 1
        table.insert(queue, job)
      elseif h.status == 'error' then
        job.status    = 'error'
        job.error_msg = 'isolate failed: ' .. tostring(h.error)
        stats.error   = stats.error + 1
        stats.last_error_msg = job.error_msg
        errored = errored + 1
      else
        -- running — active map z handle, poll loop podejmie sentinel.
        job.status         = 'isolating'
        job.isolate_handle = h
        active[job.id]     = job
        spawned = spawned + 1
      end
    else  -- phase='convert'
      table.remove(queue, i)
      job.status = 'sending'
      job.started_at = job.started_at or util.now()
      local ok, err = api.spawn_convert(job)
      if ok then
        active[job.id] = job
        spawned = spawned + 1
      else
        job.status = 'error'
        job.error_msg = 'spawn failed: ' .. tostring(err)
        stats.error = stats.error + 1
        stats.last_error_msg = job.error_msg
        errored = errored + 1
      end
    end
  end

  -- 3. Czy batch w pełni drainęty?
  if not M.has_active() and stats.started_at and not stats.finished_at then
    stats.finished_at = util.now()
  end

  return completed, errored, spawned
end

return M
