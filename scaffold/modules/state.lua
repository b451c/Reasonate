-- modules/state.lua
-- In-memory cache + dispatch GUI ↔ REAPER state.
--
-- Faza 1: cached track list (refresh co 500 ms), hardcoded voice list,
--         mutacje voice/role propagowane do P_EXT.
-- Faza 2: per-track item status counts + auto-color itemów na trackach
--         z przypisanym voice_id.

local helpers     = require 'modules.reaper_helpers'
local colors      = require 'modules.colors'
local util        = require 'modules.util'
local api         = require 'modules.api'
local job_manager = require 'modules.job_manager'
local voice_admin = require 'modules.voice_admin'

local M = {}

----------------------------------------------------------------------------
-- Voice list. Pierwszeństwo:
--   1. Świeżo pobrane przez settings_dialog → set_voices()
--   2. Cache na dysku (voices.json, TTL 24h) — załadowane na starcie
--   3. Placeholdery (jak nie ma cache i user nie wpisał klucza)
----------------------------------------------------------------------------
M.voices = {}

local PLACEHOLDER_VOICES = {
  { voice_id = 'fake-george-001', name = 'George (UK warm) [placeholder]' },
  { voice_id = 'fake-brian-002',  name = 'Brian (US deep) [placeholder]'  },
  { voice_id = 'fake-lily-003',   name = 'Lily (US soft) [placeholder]'   },
}

M.voices_source     = 'placeholder'   -- 'placeholder' | 'cache' | 'api'
M.voices_fetched_at = nil

local function load_cached_voices()
  local cached, fetched_at = api.load_voices_cache(86400)  -- 24h TTL
  if cached and #cached > 0 then
    M.voices            = cached
    M.voices_source     = 'cache'
    M.voices_fetched_at = fetched_at
    return true
  end
  M.voices            = PLACEHOLDER_VOICES
  M.voices_source     = 'placeholder'
  M.voices_fetched_at = nil
  return false
end

load_cached_voices()  -- na require'ie modułu

function M.set_voices(voices)
  M.voices            = voices or {}
  M.voices_source     = 'api'
  M.voices_fetched_at = os.time()
end

function M.reload_voices_from_cache()
  return load_cached_voices()
end

----------------------------------------------------------------------------
-- ElevenLabs account quota (PM9 iter4 — header bar indicator).
-- 2026-05-16: refactored sync → async via voice_admin.spawn_quota (mirror
-- voice op pattern). Refresh dispatcher spawn'uje handle, poll_quota w
-- defer loop pickuje result gdy sentinel arrives. UI never blocks.
-- Status: 'unknown' przed first fetch · 'fetching' w trakcie spawn/poll ·
-- 'ok' po success · 'error' gdy invalid key / network down / parse fail.
----------------------------------------------------------------------------
M.quota_used       = nil
M.quota_total      = nil
M.quota_tier       = nil
M.quota_reset_unix = nil
M.quota_fetched_at = nil
M.quota_status     = 'unknown'   -- 'unknown' | 'fetching' | 'ok' | 'error'
M.quota_error      = nil          -- string when status='error', else nil
M.quota_handle     = nil          -- voice_admin handle in flight
M.quota_voice_slots_used = nil    -- M4-3: sloty głosów (nil gdy API nie zwraca)
M.quota_voice_limit      = nil

function M.refresh_quota(api_key)
  -- api_key param historical (callsites pass it). Internal spawn uses
  -- cfg.get_api_key() so caller must have set it w config first (settings
  -- save flow does config.set_api_key BEFORE refresh_quota).
  if not api_key or api_key == '' then
    M.quota_status = 'error'
    M.quota_error  = 'no API key'
    M.quota_handle = nil
    return false
  end
  -- Orphan in-flight handle (its result will arrive at sentinel path but
  -- nobody polls → output/sentinel files cleaned by voice_admin.poll only
  -- gdy ktoś polluje. Tu po prostu zapominamy o nim i spawn nowy z bieżącym
  -- key. Edge case: stale .out / .done w tmp dir przeżyją do następnego
  -- restartu — minimalne disk leak, acceptable).
  M.quota_handle = voice_admin.spawn_quota()
  if M.quota_handle.status == 'error' then
    M.quota_status = 'error'
    M.quota_error  = M.quota_handle.error or 'spawn failed'
    M.quota_handle = nil
    return false
  end
  M.quota_status = 'fetching'
  return true
end

function M.maybe_refresh_quota(api_key, max_age_secs)
  if not api_key or api_key == '' then return false end
  if M.quota_handle then return false end          -- already in flight
  max_age_secs = max_age_secs or 300               -- 5 min default
  local age = os.time() - (M.quota_fetched_at or 0)
  if age >= max_age_secs then return M.refresh_quota(api_key) end
  return false
end

function M.poll_quota()
  if not M.quota_handle then return end
  voice_admin.poll(M.quota_handle)
  if M.quota_handle.status == 'running' then return end
  if M.quota_handle.status == 'done' then
    local r = M.quota_handle.result or {}
    M.quota_used       = r.used or 0
    M.quota_total      = r.total or 0
    M.quota_tier       = r.tier or 'unknown'
    M.quota_reset_unix = r.reset_unix or 0
    M.quota_voice_slots_used = r.voice_slots_used
    M.quota_voice_limit      = r.voice_limit
    -- M6-5: cap współbieżności wg planu (Free=2 itd.) — VR batch przestaje
    -- młócić 429 na kontach z limitem niższym niż nasze ustawienie.
    local config = require 'modules.config'
    config.note_tier(M.quota_tier)
    job_manager.max_concurrent = config.get_effective_concurrency()
    M.quota_fetched_at = os.time()
    M.quota_status     = 'ok'
    M.quota_error      = nil
  else
    M.quota_status = 'error'
    M.quota_error  = M.quota_handle.error or 'unknown error'
  end
  M.quota_handle = nil
end

----------------------------------------------------------------------------
-- Current mode (NS-A: multi-mode architecture).
-- Persisted per-project via REAPER project ExtState (leci z .rpp save/load).
-- Świeży projekt / brak save → current_mode = nil → main render pokazuje
-- mode_selector view (centered 3 karty w main window content).
----------------------------------------------------------------------------
M.current_mode = nil  -- 'voice_replacement' | 'tts' | 'dubbing' | 'repair' | 'sfx' | nil

function M.read_mode_from_project()
  local retval, val = reaper.GetProjExtState(0, 'Reasonate', 'mode')
  if retval and retval > 0 and val ~= nil and val ~= '' then
    M.current_mode = val
  else
    M.current_mode = nil
  end
  return M.current_mode
end

function M.set_mode(name)
  M.current_mode = name
  reaper.SetProjExtState(0, 'Reasonate', 'mode', name or '')
  reaper.MarkProjectDirty(0)
end

-- Per-mode in-memory state (zachowywany przy mode switch w trakcie sesji,
-- nie persistowany — każde nowe uruchomienie Reasonate startuje pusty).
-- Tylko sam `current_mode` persisted via ProjExtState.
M.modes = {
  voice_replacement = {},
  tts               = {},
  dubbing           = {},
  repair            = {},
  sfx               = {},
}

function M.mode_state(name)
  if not M.modes[name] then M.modes[name] = {} end
  return M.modes[name]
end

----------------------------------------------------------------------------
-- Track cache
----------------------------------------------------------------------------
M.tracks  = {}            -- array of track_info, każdy z .counts
M.totals  = {             -- agregat across all tracks (do header)
  total_audio = 0, new = 0, converted = 0, stale = 0, error = 0, output = 0,
  with_voice = 0,
}
local last_scan_at = 0
local SCAN_INTERVAL = 0.5

local function empty_counts()
  return { total_audio = 0, new = 0, converted = 0, stale = 0, error = 0, output = 0 }
end

local function empty_counts_with_inflight()
  return { total_audio = 0, new = 0, in_progress = 0, converted = 0,
           stale = 0, error = 0, output = 0, skipped = 0 }
end

local function rebuild_tracks()
  local out = {}
  local tot = empty_counts_with_inflight()
  tot.with_voice = 0
  local color_changed = false

  -- Set GUID-ów itemów aktualnie w pipelinie (Faza 5).
  local in_flight = job_manager.in_flight_item_guids()

  -- T1 (UX-POLISH 2026-07): output tracki ([AI]) nie noszą własnego
  -- markera — to SOURCE track ma P_EXT output_track_guid. Pre-pass buduje
  -- mapę guid outputu → nazwa źródła; wiersz outputu w tracks_table
  -- renderuje się read-only (bez voice pickera / roli / menu ⋯).
  local output_of = {}
  for tr in helpers.iter_tracks() do
    local og = helpers.get_track_output_guid(tr)
    if og then
      output_of[og] = { name = helpers.track_name(tr) or '',
                        guid = helpers.track_guid(tr) }
    end
  end
  tot.output_tracks = 0

  -- Folder depth chain: running_depth = level THIS track sits at; updates
  -- after each track per its I_FOLDERDEPTH (1=opens, -N=closes N levels).
  local running_depth = 0

  for tr in helpers.iter_tracks() do
    local info = helpers.track_info(tr)
    info.folder_depth       = helpers.get_track_folder_depth(tr)
    info.folder_indent      = math.max(0, running_depth)
    running_depth = math.max(0, running_depth + info.folder_depth)
    local out_src = output_of[info.guid]
    info.is_output_track = out_src ~= nil
    info.output_of       = out_src and out_src.name
    -- T8: guid źródła — wiersz [AI] podąża za widocznością source'a w filtrze
    info.output_src_guid = out_src and out_src.guid
    if info.is_output_track then tot.output_tracks = tot.output_tracks + 1 end
    local cs = empty_counts_with_inflight()

    -- Effective track swatch color: uniform-color across audio items, or nil
    -- (mixed / no items). Computed po itemach poniżej.
    local first_native, uniform_native, audio_count = nil, true, 0

    for it in helpers.iter_track_items(tr) do
      if helpers.is_audio_item(it) then
        cs.total_audio = cs.total_audio + 1
        local status = helpers.get_item_status(it)
        local guid = helpers.item_guid(it)

        -- Itemy w pipelinie nadpisują status (priorytetowo nad P_EXT).
        if in_flight[guid] then
          status = 'in_progress'
        elseif status == 'new' and not info.voice_id then
          -- Reklasyfikuj 'new' na 'skipped' jeśli track nie ma voice'a (UX spec L58).
          status = 'skipped'
        end
        cs[status] = (cs[status] or 0) + 1

        -- Auto-color: gdy track ma voice lub item w pipelinie. User override
        -- (per-item P_EXT.user_color flag) WYGRYWA — items z flagą zostają
        -- nietknięte, status palette omija je.
        if info.voice_id or status == 'in_progress' then
          if not helpers.get_item_user_color_flag(it) then
            if colors.apply_to_item(it, status) then color_changed = true end
          end
        end

        -- Track swatch effective color collection
        local cur_native = math.floor(reaper.GetMediaItemInfo_Value(it, 'I_CUSTOMCOLOR'))
        if audio_count == 0 then
          first_native = cur_native
        elseif cur_native ~= first_native then
          uniform_native = false
        end
        audio_count = audio_count + 1
      end
    end

    -- effective_color: nil dla mixed/empty/no-color, native int dla uniform
    if audio_count > 0 and uniform_native and first_native and first_native ~= 0 then
      info.effective_color = first_native
    else
      info.effective_color = nil
    end
    info.color_uniform = uniform_native
    info.audio_count   = audio_count

    info.counts = cs
    out[#out + 1] = info

    if info.voice_id then tot.with_voice = tot.with_voice + 1 end
    for k, v in pairs(cs) do tot[k] = (tot[k] or 0) + v end
  end

  M.tracks = out
  M.totals = tot
  if color_changed then reaper.UpdateArrange() end
  last_scan_at = util.now()
end

function M.refresh(force)
  if force or (util.now() - last_scan_at) >= SCAN_INTERVAL then
    rebuild_tracks()
  end
end

function M.find_cached(track_guid)
  return util.find(M.tracks, function(t) return t.guid == track_guid end)
end

----------------------------------------------------------------------------
-- Mutacje (zapis do P_EXT + sync cache, bez czekania na rescan)
----------------------------------------------------------------------------
function M.set_voice(track_guid, voice_id, voice_name)
  local tr = helpers.find_track_by_guid(track_guid)
  if not tr then return false, 'track not found' end
  helpers.set_track_voice(tr, voice_id, voice_name)
  local cached = M.find_cached(track_guid)
  if cached then
    cached.voice_id   = voice_id
    cached.voice_name = voice_name
  end
  -- Forsuj rescan przy następnym tick — nowo przypisany voice włącza
  -- auto-coloring itemów na tym tracku.
  last_scan_at = 0
  util.dbg('set_voice', track_guid, voice_id, voice_name)
  return true
end

function M.clear_voice(track_guid)
  local tr = helpers.find_track_by_guid(track_guid)
  if not tr then return false, 'track not found' end
  helpers.clear_track_voice(tr)
  local cached = M.find_cached(track_guid)
  if cached then
    cached.voice_id   = nil
    cached.voice_name = nil
  end
  return true
end

function M.set_role(track_guid, role)
  local tr = helpers.find_track_by_guid(track_guid)
  if not tr then return false, 'track not found' end
  helpers.set_track_role(tr, role)
  local cached = M.find_cached(track_guid)
  if cached then cached.role = (role ~= '' and role) or nil end
  return true
end

function M.set_name(track_guid, name)
  local tr = helpers.find_track_by_guid(track_guid)
  if not tr then return false, 'track not found' end
  helpers.set_track_name(tr, name)
  local cached = M.find_cached(track_guid)
  if cached then cached.name = name or '' end
  return true
end

return M
