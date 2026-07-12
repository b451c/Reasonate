-- modules/housekeeping.lua
-- Sprzątanie osieroconych plików tmp + egzekwowanie limitu cache
-- (audit fix M2-3, 2026-06-10).
--
-- Problem: workery które umarły bez polla zostawiają w reasonate_tmp/
-- sentinele, pliki body/text i outputy NA ZAWSZE (brak TTL); po godzinach
-- dubbingu = setki MB cichego przyrostu.
--
-- Strategia wieku: Lua/REAPER bez JS_ReaScriptAPI nie ma dostępu do mtime —
-- ale KAŻDY async job_id embeduje `_<hex(os.time())>_<hex(rand)>` w nazwie
-- (stt_/diarize_/align_/llm_/isolate_/voice_admin prefix_/_resp_). Parsujemy
-- timestamp z nazwy. Pliki bez tego wzorca (cache: stt_<hash>.json,
-- isolated_<key>.mp3, voices.json, render_<hash>.wav, dotfiles z kluczami,
-- podkatalogi) są NIETYKANE — celowo konserwatywnie.

local util = require 'modules.util'

local M = {}

local SWEEP_AGE_SECS = 7 * 24 * 3600   -- > tydzień = nikt po to nie wróci

-- Rozszerzenia artefaktów jobów (sentinel triplet + outputy + text files).
-- NIGDY: mp3 (isolated_ cache), wav (render_ intermediates — hash-named,
-- bez timestampu w nazwie, czyszczone na success path).
local SWEEP_EXT = {
  done = true, stderr = true, curl_exit = true,
  json = true, out = true, txt = true, bin = true,
}

-- Sanity bounds dla sparsowanego timestampu (mis-parse ochrona):
-- 2020-01-01 .. now+1dzień.
local TS_MIN = 1577836800

local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts'
      .. path_sep() .. 'reasonate_tmp'
end

----------------------------------------------------------------------------
-- is_sweepable(fname, now_unix) → bool (pure; M1-3 headless-tested).
-- Wzorzec job-artefaktu: <prefix>_<hex(os.time())>_<hex(rand)>.<ext ze
-- SWEEP_EXT>. Cache files (tts_<8hex>.mp3, stt_<hash>.json bez drugiego
-- '_<hex>' segmentu), dotfiles i inne nazwy → false.
----------------------------------------------------------------------------
function M.is_sweepable(fname, now_unix)
  if fname:sub(1, 1) == '.' then return false end
  local ts_hex = fname:match('_(%x+)_%x+%.')
  local ext = fname:match('%.([%w_]+)$')
  if not (ts_hex and ext and SWEEP_EXT[ext]) then return false end
  local ts = tonumber(ts_hex, 16)
  return (ts and ts > TS_MIN and ts < (now_unix + 86400)
          and (now_unix - ts) > SWEEP_AGE_SECS) or false
end

----------------------------------------------------------------------------
-- sweep_tmp_orphans(now_unix?) → removed_count
-- Top-level reasonate_tmp/ only (podkatalogi dub_align/translate_cache/
-- dub_chunks to nazwane cache — poza zakresem).
----------------------------------------------------------------------------
function M.sweep_tmp_orphans(now_unix)
  now_unix = now_unix or os.time()
  local dir = tmp_dir()
  local removed = 0
  for _, fname in ipairs(util.list_dir(dir)) do
    if M.is_sweepable(fname, now_unix) then
      if os.remove(dir .. path_sep() .. fname) then
        removed = removed + 1
      end
    end
  end
  return removed
end

----------------------------------------------------------------------------
-- sweep_part_orphans(dirs) → removed_count (M1-2, audit 2026-07).
-- *.part = przerwane downloady (worker pisze do $OUT.part, mv po 2xx).
-- Nazwy .part nie niosą timestampu (klucz cache 8-hex), a mtime jest
-- niedostępne — na starcie sesji KAŻDY .part jest z definicji osierocony
-- (żaden handle nie żyje). Corner: druga instancja REAPER z workerem
-- mid-flight — usunięcie .part = curl pisze do unlinked inode, mv nie
-- publikuje nic → brak zatrucia, tylko zmarnowany request (dwie instancje
-- współdzielące tmp/cache to znany KNOWN-ISSUE).
----------------------------------------------------------------------------
function M.sweep_part_orphans(dirs)
  local removed = 0
  for _, dir in ipairs(dirs or {}) do
    for _, fname in ipairs(util.list_dir(dir)) do
      if fname:sub(1, 1) ~= '.' and fname:match('%.part$') then
        if os.remove(dir .. path_sep() .. fname) then
          removed = removed + 1
        end
      end
    end
  end
  return removed
end

----------------------------------------------------------------------------
-- run_startup() — wołane raz z reasonate.lua po migration.run_once().
-- pcall-owane przez caller (housekeeping nie może zablokować startu).
-- Zwraca removed_orphans, evicted_files.
----------------------------------------------------------------------------
function M.run_startup()
  local cache  = require 'modules.cache'
  local config = require 'modules.config'
  local removed = M.sweep_tmp_orphans()
  removed = removed + M.sweep_part_orphans({ tmp_dir(), cache.cache_dir() })
  local evicted = cache.evict_to_cap(config.get_cache_max_bytes())
  return removed, evicted
end

return M
