-- @description Reasonate - AI voice tools for REAPER (TTS, voice replacement, dubbing, repair, SFX & music)
-- @author falami.studio (b4s1c)
-- @version 1.0.0
-- @about
--   # Reasonate
--
--   AI audio production toolkit built on the ElevenLabs API: generate speech
--   from text (single voice or multi-speaker dialogue), swap voices in
--   recordings, dub material into other languages, fix single words in a
--   take, and design sound effects and music beds - all inside REAPER,
--   all non-destructively. Requires ReaImGui 0.10+ and your own ElevenLabs
--   API key. Full illustrated guide: see the project website.
-- @link https://falami.studio
-- @donation https://ko-fi.com/quickmd
--
-- UWAGA: @version trzymać w sync z config.APP_VERSION (i tagiem release).
-- index.xml dla ReaPack generuje scripts/build_reapack_index.sh.
--
-- Reasonate — AI voice production for REAPER (TTS / voice replacement / dubbing).
-- Powered by ElevenLabs (S2S, TTS, IVC, Scribe STT) + LLMs for translation.
--
-- v3 multi-mode (NS-A 2026-05-11): startup → mode picker view (gdy świeży projekt
-- bez ProjExtState mode), inaczej restore mode + tabs do switching. Per-mode
-- panel renderowany w main window content area.
--
-- Load via Action List → "ReaScript: Load (action)..." → wskaż ten plik.
--
-- Renamed 2026-05-10 from "ReaCast" (collision z REAPER built-in feature).
-- Multi-mode 2026-05-11 (NS-A) — per-project mode persisted via ProjExtState.

----------------------------------------------------------------------------
-- ReaImGui presence check
----------------------------------------------------------------------------
if not reaper.ImGui_GetVersion then
  reaper.MB(
    'ReaImGui not installed.\n\nInstall via ReaPack:\n  Extensions → ReaPack → Browse packages...\n  → search "ReaImGui" → install.',
    'Reasonate — missing dependency', 0)
  return
end
if not reaper.ImGui_CreateFontFromFile then
  reaper.MB(
    'ReaImGui v0.10+ required.\n\nUpdate via ReaPack:\n  Extensions → ReaPack → Synchronize packages.',
    'Reasonate — outdated dependency', 0)
  return
end

----------------------------------------------------------------------------
-- Module loader
----------------------------------------------------------------------------
local script_path = ({reaper.get_action_context()})[2]:match('(.*[/\\])') or ''
package.path = script_path .. '?.lua;'
            .. script_path .. '?/init.lua;'
            .. package.path

local state           = require 'modules.state'
local config          = require 'modules.config'
local api             = require 'modules.api'
local util            = require 'modules.util'
local job_manager     = require 'modules.job_manager'
local activity        = require 'modules.activity'      -- Pakiet A: pasek aktywności
local recording       = require 'modules.recording'
local theme           = require 'modules.theme'
local preview         = require 'modules.preview'

-- Global modale (mode-agnostic) — settings, voice tools, casts
local settings_dialog = require 'modules.gui.settings_dialog'
local voice_picker    = require 'modules.gui.voice_picker'
local voice_manager   = require 'modules.gui.voice_manager'
local voice_library   = require 'modules.gui.voice_library'
local cast_manager    = require 'modules.gui.cast_manager'
local speaker_picker  = require 'modules.gui.speaker_picker'   -- NS-G
local batch_dialog    = require 'modules.gui.batch_dialog'     -- PM9 iter4: dispatched OUTSIDE Begin/End (regular ImGui_Begin floating window)

-- Global layout — header (top) + footer (bottom)
local header_bar      = require 'modules.gui.header_bar'
local footer          = require 'modules.gui.footer'

-- NS-A: mode dispatch UI
local mode_selector   = require 'modules.gui.mode_selector'
local mode_tabs       = require 'modules.gui.mode_tabs'

local migration       = require 'modules.migration'
local update_check    = require 'modules.update_check'  -- PHASE-USER-GUIDE §3

-- Mode modules (per-mode UI + logic). Each implements:
--   M.render(ctx, state, deps), M.render_modals(ctx, state, deps),
--   M.consume_signals(state, deps), M.shutdown()
local modes_map = {
  voice_replacement = require 'modules.modes.voice_replacement',
  tts               = require 'modules.modes.tts',
  dubbing           = require 'modules.modes.dubbing',
  repair            = require 'modules.modes.repair',
  sfx               = require 'modules.modes.sfx',
}

----------------------------------------------------------------------------
-- One-shot migration ReaCast → Reasonate (ExtState + filesystem).
-- Idempotent — przebiega tylko raz, na pierwszym launchu po update.
----------------------------------------------------------------------------
migration.run_once()

-- M2-3 (audit 2026-06-10): housekeeping na starcie — sweep osieroconych
-- plików tmp (>7 dni, timestamp z nazwy) + eviction cache do limitu
-- (Settings → Cache size limit). pcall: sprzątanie NIE może zablokować
-- startu pluginu.
pcall(function()
  local housekeeping = require 'modules.housekeeping'
  housekeeping.run_startup()
end)

-- Sync concurrency z configa
job_manager.max_concurrent = config.get_effective_concurrency()  -- M6-5: cap wg tier po fetchu quota

----------------------------------------------------------------------------
-- Context + theme init
----------------------------------------------------------------------------
local SCRIPT_NAME = 'Reasonate'
local CTX_KEY     = 'Reasonate_v1'

-- Auto-recovery: gdy poprzedni frame crashował, kasujemy ImGui state poprzez
-- generowanie unique CTX_KEY suffix. Next launch po crash → fresh context.
local crash_flag = reaper.GetExtState('Reasonate', 'last_crash_count') or '0'
local crash_count = tonumber(crash_flag) or 0
if crash_count > 0 then
  CTX_KEY = CTX_KEY .. '_r' .. tostring(crash_count)
end

local ctx = reaper.ImGui_CreateContext(CTX_KEY)
local WIN_FLAGS = reaper.ImGui_WindowFlags_NoCollapse()

-- Dock state validation (REAPER dockers -1..-16; 0=floating; positive=ImGui dockspace IGNORED)
local saved_dock_id = tonumber(reaper.GetExtState('Reasonate', 'window_dock_id')) or 0
if saved_dock_id < 0 then
  local n = -saved_dock_id
  if n < 1 or n > 16 then
    saved_dock_id = 0
  else
    local pos = reaper.DockGetPosition(n)
    if not pos or pos < 0 or pos > 3 then
      saved_dock_id = 0
    end
  end
elseif saved_dock_id > 0 then
  saved_dock_id = 0
end
if tonumber(reaper.GetExtState('Reasonate', 'window_dock_id')) ~= saved_dock_id then
  reaper.SetExtState('Reasonate', 'window_dock_id', tostring(saved_dock_id), true)
end

local last_dock_id = saved_dock_id
local pending_dock_id = (saved_dock_id ~= 0) and saved_dock_id or nil

local IS_MAC = reaper.GetOS():find('OSX') ~= nil or reaper.GetOS():find('macOS') ~= nil
local MOD_LABEL = IS_MAC and 'Cmd' or 'Ctrl'

local imgui_ver, _, reaimgui_ver = reaper.ImGui_GetVersion()
local curl_path = config.get_curl_path()

-- Init custom font (Inter Regular + SemiBold from scaffold/assets/fonts/)
theme.init(ctx, script_path)

-- (W3 2026-06-10: mode_selector.init usunięty — karty proceduralne, bez PNG.)

if not config.has_api_key() then
  settings_dialog.open()
end

-- NS-A: read mode from project ExtState (świeży projekt = nil → mode picker)
state.read_mode_from_project()

-- PM9 iter4: quota fetch DEFERRED do loop() po ~30 frames (~500ms) żeby
-- plugin startuje natychmiast (sync fetch ~200ms blokowałby first paint).
-- Header pokazuje "Quota: loading…" w międzyczasie (gdy has_api_key).

----------------------------------------------------------------------------
-- Background — W3 UI/UX (2026-06-10): proceduralna "głębia" rysowana
-- DrawList-em (user-approved wariant). Zastępuje hand-painted background.png
-- (1,4 MB) — zero plików graficznych, ostre na każdej rozdzielczości.
-- Kompozycja: pionowy gradient grafitowy + poświata w kolorze akcentu
-- aktywnego trybu przy górnej krawędzi + winieta (lewo/prawo/dół; góra bez
-- winiety — tam żyje poświata). Toggle: Settings → General →
-- "Decorative background".
----------------------------------------------------------------------------
local function draw_procedural_bg(dl, x, y, w, h, accent)
  local x2, y2 = x + w, y + h
  -- 1. Baza: gradient pionowy — głęboki grafit, lekko jaśniejszy u góry.
  reaper.ImGui_DrawList_AddRectFilledMultiColor(dl, x, y, x2, y2,
    0x16171BFF, 0x16171BFF, 0x0E0F12FF, 0x0E0F12FF)
  -- 2. Poświata akcentu trybu: pas od górnej krawędzi gasnący do zera.
  local glow = accent & 0xFFFFFF00
  local band_h = math.min(220, math.floor(h * 0.35))
  reaper.ImGui_DrawList_AddRectFilledMultiColor(dl, x, y, x2, y + band_h,
    glow | 0x1C, glow | 0x1C, glow, glow)
  -- 3. Winieta: krawędziowe gradienty przygaszające brzegi.
  local vx = math.min(140, math.floor(w * 0.16))
  local vy = math.min(110, math.floor(h * 0.16))
  local SH, TR = 0x00000048, 0x00000000
  reaper.ImGui_DrawList_AddRectFilledMultiColor(dl, x, y, x + vx, y2, SH, TR, TR, SH)
  reaper.ImGui_DrawList_AddRectFilledMultiColor(dl, x2 - vx, y, x2, y2, TR, SH, SH, TR)
  reaper.ImGui_DrawList_AddRectFilledMultiColor(dl, x, y2 - vy, x2, y2, TR, TR, SH, SH)
end

----------------------------------------------------------------------------
-- Action status (komunikat w footer)
----------------------------------------------------------------------------
local last_action_msg, last_action_color = '', theme.COLORS.text_dim
local was_batch_active = false
local last_main_geom = nil
local _quota_init_delay = 30   -- PM9 iter4: defer first quota fetch ~500ms (60Hz × 30 frames)

local function set_action(msg, color)
  last_action_msg   = msg or ''
  last_action_color = color or theme.COLORS.text_dim
end

local COL_OK   = theme.COLORS.status_done
local COL_ERR  = theme.COLORS.status_error
local COL_INFO = theme.COLORS.text_dim

----------------------------------------------------------------------------
-- Refresh voices toolbar action (dead — kept per CLAUDE.md rule 3
-- "notice dead code, mention not delete"). Wcześniej callowane z header_bar
-- "Refresh" button, który został usunięty na rzecz Voice Manager refresh.
----------------------------------------------------------------------------
local function action_refresh_voices()
  local key = config.get_api_key()
  if not key then
    set_action('No API key — open Settings first', COL_ERR)
    return
  end
  local ok, voices, err = api.fetch_voices(key)
  if ok then
    api.save_voices_cache(voices)
    state.set_voices(voices)
    set_action(('Refreshed · %d voices'):format(#voices), COL_OK)
  else
    set_action('Refresh FAILED · ' .. tostring(err), COL_ERR)
  end
end
_ = action_refresh_voices  -- suppress unused warning (kept for future header_bar refresh re-add)

----------------------------------------------------------------------------
-- Global keyboard shortcuts (mode-agnostic).
-- ⌘+,  → Settings
-- Mode-specific shortcuts (⌘+Enter Convert, Esc cancel batch) handled
-- przez per-mode process_shortcuts w modes/voice_replacement.lua.
----------------------------------------------------------------------------
local function process_global_shortcuts()
  local mod_ctrl_cmd = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
  if mod_ctrl_cmd
      and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Comma(), false) then
    settings_dialog.open()
  end
end

----------------------------------------------------------------------------
-- Frame
----------------------------------------------------------------------------
local first_frame = true

local function frame()
  reaper.ImGui_SetNextWindowSize(ctx, 980, 640, reaper.ImGui_Cond_FirstUseEver())

  if first_frame then
    -- Force floating na pierwszą klatkę (nadpisuje broken dock_id z ImGui state file)
    reaper.ImGui_SetNextWindowDockID(ctx, 0, reaper.ImGui_Cond_Always())
    first_frame = false
    if saved_dock_id ~= 0 then
      pending_dock_id = saved_dock_id
    end
  elseif pending_dock_id ~= nil then
    reaper.ImGui_SetNextWindowDockID(ctx, pending_dock_id)
    pending_dock_id = nil
  end

  theme.push(ctx)

  local visible, open = reaper.ImGui_Begin(ctx, SCRIPT_NAME, true, WIN_FLAGS)
  if visible then
    -- Capture main window geom: cx/cy = center; used przez theme.center_next_modal
    -- (PM8: all modals follow main window even on second monitor).
    local mw_x, mw_y = reaper.ImGui_GetWindowPos(ctx)
    local mw_w, mw_h = reaper.ImGui_GetWindowSize(ctx)
    last_main_geom = { cx = mw_x + mw_w / 2, cy = mw_y + mw_h / 2 }
    theme.set_main_center(last_main_geom.cx, last_main_geom.cy)

    -- Background: render PIERWSZY (pod wszystkim) — proceduralna głębia
    -- z akcentem aktywnego trybu (W3; patrz draw_procedural_bg wyżej).
    if config.get_bg_image_enabled() then
      local dl_bg = reaper.ImGui_GetWindowDrawList(ctx)
      local accent = theme.MODE_ACCENTS[state.current_mode] or theme.COLORS.primary
      draw_procedural_bg(dl_bg, mw_x, mw_y, mw_w, mw_h, accent)
    end

    -- Persist dock state na zmianę
    local cur_dock = reaper.ImGui_GetWindowDockID(ctx)
    if cur_dock ~= last_dock_id then
      last_dock_id = cur_dock
      reaper.SetExtState('Reasonate', 'window_dock_id', tostring(cur_dock), true)
    end

    -- 1. Header bar (tytuł + 4 globalne ikony akcji)
    -- PM9 iter4: tts_chars_used replaced przez quota fields (state.quota_*).
    -- Real ElevenLabs account quota > local session counter (latter incomplete:
    -- nie tracks Voice Replacement / Repair char usage).
    local hdr = header_bar.render(ctx, {
      has_api_key      = config.has_api_key(),
      voices_source    = state.voices_source,
      voices_count     = #state.voices,
      voices_age_min   = state.voices_fetched_at
        and math.floor((os.time() - state.voices_fetched_at) / 60) or 0,
      current_dock_id  = cur_dock,
      quota_used       = state.quota_used,
      quota_total      = state.quota_total,
      quota_tier       = state.quota_tier,
      quota_reset_unix = state.quota_reset_unix,
      quota_status     = state.quota_status,
      quota_error      = state.quota_error,
      update_tag       = update_check.available(),
    })
    if hdr.open_releases then
      util.open_url(update_check.releases_url())
    end
    if hdr.settings      then settings_dialog.open() end
    if hdr.voice_manager then voice_manager.open(state) end
    if hdr.library       then voice_library.open(state) end
    -- Casts moved z global header → Voice Replacement stats_strip (PM8).
    if hdr.set_dock_id ~= nil then
      pending_dock_id = hdr.set_dock_id
    end

    reaper.ImGui_Separator(ctx)

    -- 2. Mode dispatch: gdy current_mode == nil → mode picker view.
    --    Gdy current_mode != nil → mode tabs + mode panel.
    if state.current_mode == nil then
      local picked = mode_selector.render(ctx)
      if picked then
        state.set_mode(picked)
      end
    else
      local switched = mode_tabs.render(ctx, state.current_mode)
      if switched then
        state.set_mode(switched)
      end

      reaper.ImGui_Separator(ctx)

      local mode = modes_map[state.current_mode]
      if mode then
        mode.render(ctx, state, {
          action_msg_setter = set_action,
          has_api_key       = config.has_api_key(),
          mod_label         = MOD_LABEL,
          main_geom         = last_main_geom,
        })
      else
        -- Defensive: unknown mode value w ProjExtState → fallback do picker.
        reaper.ImGui_TextColored(ctx, theme.COLORS.status_error,
          ('Unknown mode: %s. Reset via Switch.'):format(tostring(state.current_mode)))
        state.set_mode(nil)
      end
    end

    -- 3. Footer (footer.render renderuje wewnętrzny Separator — nie dodajemy
    -- drugiego tutaj, inaczej duplikat 2 linii)
    footer.render(ctx, {
      -- Pakiet A: chipy aktywności (pull z stanu trybów + job_manager +
      -- recording). Pusta lista → footer pokazuje msg / 'Ready' jak dotąd.
      activities = activity.collect(state, {
        job_stats = job_manager.has_active() and job_manager.get_stats() or nil,
        recording = recording.is_active() and {
          elapsed  = recording.elapsed_secs(),
          pre_roll = recording.is_pre_roll(),
        } or nil,
      }),
      msg       = last_action_msg,
      msg_color = last_action_color,
      mod_label = MOD_LABEL,
      -- T10: skróty w stopce per tryb (statyczny "Convert" kłamał poza VR)
      current_mode = state.current_mode,
      env = {
        reaper      = reaper.GetAppVersion(),
        imgui       = imgui_ver,
        reaimgui    = reaimgui_ver,
        curl_path   = curl_path,
        concurrency = job_manager.max_concurrent,
      },
    })

    process_global_shortcuts()

    -- 4. Globalne modale (mode-agnostic) + 5. Mode-specific modale —
    -- dispatch INSIDE Begin/End głównego window (PM9 iter3 fix v3, mirror
    -- ReaImGui_Demo.lua pattern). Pre-fix był OUTSIDE End — multi-viewport
    -- z-order bug w ImGui v1.92 powodował że modal renderował się POD main
    -- panel na floating window + secondary monitor (macOS). Inside-Begin
    -- dispatch dziala na docked mode (potwierdzone PM9 iter3) — daje
    -- ImGui poprawny window hierarchy context dla modal z-stack.
    settings_dialog.render(ctx, state)
    voice_picker.render(ctx)
    voice_manager.render(ctx)
    voice_library.render(ctx)
    cast_manager.render(ctx)
    speaker_picker.render(ctx)   -- NS-G: multi-speaker IVC clone picker

    if state.current_mode and modes_map[state.current_mode] then
      modes_map[state.current_mode].render_modals(ctx, state, {
        action_msg_setter = set_action,
        has_api_key       = config.has_api_key(),
        mod_label         = MOD_LABEL,
        main_geom         = last_main_geom,
      })
    end

    reaper.ImGui_End(ctx)
  end

  -- batch_dialog dispatched OUTSIDE Begin/End głównego window (PM9 iter4).
  -- batch_dialog jest UNIQUE — używa regular ImGui_Begin (nie BeginPopupModal)
  -- jako intentional design choice (non-blocking floating window — user może
  -- kontynuować pracę podczas batch processing). Per Dear ImGui v1.92 viewport
  -- semantics, sub-Begin INSIDE main Begin/End może być treated jako nested w
  -- main viewport context → batch_dialog wpadałby pod main w z-stack. Dispatch
  -- OUTSIDE preserves top-level floating behavior + dockowalność. Modal popups
  -- (BeginPopupModal) zostają INSIDE Begin/End per fix v3 (modal stuck-behind).
  batch_dialog.render(ctx, job_manager, { main_geom = last_main_geom })

  theme.pop(ctx)

  return open
end

----------------------------------------------------------------------------
-- Defer loop
----------------------------------------------------------------------------
state.refresh(true)

----------------------------------------------------------------------------
-- Fault isolation pętli defer (audit fix M1-1, 2026-06-10).
--
-- Pre-fix: tylko frame() był w pcall — błąd w job_manager.tick / state
-- refresh / quota / consume_signals kończył defer chain → okno znikało
-- mid-batch bez diagnozy, crash recovery (counter → fresh ctx) nie firowało
-- bo obejmuje wyłącznie frame errors. consume_signals to najcięższa logika
-- (pumpy TTS/translate/dub, splice, P_EXT writes) — jedna zła odpowiedź
-- API = śmierć całej wtyczki.
--
-- guarded(): pcall + błąd do footera (set_action) + console log throttled
-- (error powtarza się co tick @~60Hz — bez throttle zalałby console).
-- Frame() zostaje na DOTYCHCZASOWYM mechanizmie (pcall + crash counter +
-- zamknięcie) — błąd mid-Begin/End zostawia niezbalansowany ImGui stack,
-- kontynuacja by assertowała; fresh ctx na next launch jest poprawnym
-- recovery. Crash countera NIE bumpujemy dla pump errors (counter służy
-- recovery ImGui state, a successful frame i tak go zeruje co tick).
----------------------------------------------------------------------------
local _last_guard_err = {}   -- label -> { msg, at }
local function guarded(label, fn, a, b)
  local ok, r1, r2, r3 = pcall(fn, a, b)
  if ok then return r1, r2, r3 end
  local msg = tostring(r1)
  set_action(('Internal error (%s): %s'):format(label, msg:sub(1, 120)), COL_ERR)
  local prev = _last_guard_err[label]
  local now = util.now()
  if not prev or prev.msg ~= msg or (now - prev.at) > 5 then
    reaper.ShowConsoleMsg(('[Reasonate] %s error: %s\n'):format(label, msg))
    _last_guard_err[label] = { msg = msg, at = now }
  end
  return nil
end

local function loop()
  guarded('preview', preview.tick)

  local completed, errored, spawned = guarded('jobs', job_manager.tick)
  completed, errored, spawned = completed or 0, errored or 0, spawned or 0

  if completed > 0 or errored > 0 or spawned > 0 then
    guarded('state', state.refresh, true)
  else
    guarded('state', state.refresh)
  end

  -- PM9 iter4: quota refresh — deferred do ~30 frames (~500ms) po startup
  -- żeby first paint nie był zablokowany. Po initial delay: periodic 5min
  -- stale check. Plus refresh immediate po batch end.
  -- 2026-05-16: refresh_quota teraz async (mirror voice_admin pattern) —
  -- maybe_refresh spawnuje handle, poll_quota pickuje result gdy sentinel
  -- arrives. Poll every tick (cheap no-op gdy nie ma handle).
  if _quota_init_delay > 0 then
    _quota_init_delay = _quota_init_delay - 1
  else
    guarded('quota', state.maybe_refresh_quota, config.get_api_key(), 300)
    -- Update-check (PHASE-USER-GUIDE §3): cichy start-check po quota
    -- warmupie (throttle 24 h + gate config.UPDATE_REPO, oba wewnątrz).
    guarded('update_check', update_check.maybe_auto_check)
  end
  guarded('quota', state.poll_quota)
  guarded('update_check', update_check.tick)

  -- Detekcja końca batchu → toast w footer (globalne — job_manager shared
  -- across modes; future TTS mode też może enqueue jobs, batch end toast
  -- relevant globalnie).
  local now_active = job_manager.has_active()
  if was_batch_active and not now_active then
    local stats = job_manager.get_stats()
    local elapsed = (stats.finished_at or util.now()) - (stats.started_at or util.now())
    local cache_suffix = (stats.cache_hits or 0) > 0
      and (' · %d cache hit%s'):format(stats.cache_hits, stats.cache_hits == 1 and '' or 's')
      or ''
    local retry_suffix = (stats.retries or 0) > 0
      and (' · %d retr%s'):format(stats.retries, stats.retries == 1 and 'y' or 'ies')
      or ''
    local isolate_skip_suffix = (stats.isolate_skipped or 0) > 0
      and (' · %d isolate skipped (too short)'):format(stats.isolate_skipped)
      or ''
    local suffix = cache_suffix .. retry_suffix .. isolate_skip_suffix
    if (stats.error or 0) > 0 then
      set_action(('Batch done in %.1fs · %d done, %d error, %d cancelled%s'):format(
        elapsed, stats.done or 0, stats.error or 0, stats.cancelled or 0, suffix), COL_ERR)
    elseif (stats.cancelled or 0) > 0 then
      set_action(('Batch done in %.1fs · %d done, %d cancelled%s'):format(
        elapsed, stats.done or 0, stats.cancelled or 0, suffix), COL_INFO)
    else
      set_action(('Batch done in %.1fs · %d / %d converted%s'):format(
        elapsed, stats.done or 0, stats.total or 0, suffix), COL_OK)
    end
  end
  if was_batch_active and not now_active then
    -- PM9 iter4: refresh quota immediately po batch end (chars consumed,
    -- bypass 5min staleness check żeby user widział fresh count od razu).
    state.refresh_quota(config.get_api_key())
    -- M2-3: batch dopisał pliki do cache → egzekwuj size cap od razu.
    guarded('cache-evict', function()
      require('modules.cache').evict_to_cap(config.get_cache_max_bytes())
    end)
  end
  was_batch_active = now_active

  local ok, open_or_err = pcall(frame)
  if not ok then
    -- Bump crash counter — next launch gets fresh CTX_KEY suffix
    local count = tonumber(reaper.GetExtState('Reasonate', 'last_crash_count') or '0') or 0
    reaper.SetExtState('Reasonate', 'last_crash_count', tostring(count + 1), true)
    reaper.ShowConsoleMsg('[Reasonate] frame error: ' .. tostring(open_or_err) .. '\n')
    return
  end

  -- Successful frame → clear crash counter
  if crash_count > 0 then
    reaper.SetExtState('Reasonate', 'last_crash_count', '0', true)
    crash_count = 0
  end

  -- Mode-specific post-frame signal consumption (batch_dialog requests,
  -- repair/sfx pipelines, variants requests — wszystko per-mode).
  -- guarded (M1-1): error w pompie pokazuje się w footerze, okno przeżywa.
  if state.current_mode and modes_map[state.current_mode] then
    guarded('signals', modes_map[state.current_mode].consume_signals, state, {
      action_msg_setter = set_action,
      has_api_key       = config.has_api_key(),
      mod_label         = MOD_LABEL,
      main_geom         = last_main_geom,
    })
  end

  -- 2026-07-11 (user-caught "wiszący chip Repair" w stopce): pompy async
  -- Repair żyły TYLKO w M.render aktywnego trybu — przełączenie trybu
  -- zamrażało in-flight STT/alignment/TTS, a chip aktywności wisiał
  -- wiecznie. Pompa tła poll'uje handle BEZ akcji na timeline (splice
  -- czeka na powrót do Repair — pending_regen zostaje).
  if state.current_mode ~= 'repair' and modes_map.repair.pump_background then
    guarded('repair_bg', modes_map.repair.pump_background, state)
  end

  if open_or_err then
    reaper.defer(loop)
  end
end

-- Cleanup hook: gdy script się zamyka (window X, REAPER shutdown).
-- Wywołujemy shutdown WSZYSTKICH modes — każdy module wie co cleanup'ować
-- (VR: recording.shutdown; TTS/Dubbing: no-op).
reaper.atexit(function()
  for _, mode in pairs(modes_map) do
    pcall(mode.shutdown, state)
  end
  -- M3-3 (audit 2026-06-10): kasuj pliki kluczy API z dysku przy zamknięciu.
  -- Odtwarzane on-demand przy następnym uruchomieniu — zero kosztu UX.
  pcall(api.wipe_key_file)
  pcall(function() require('modules.llm').wipe_key_files() end)
  pcall(function() require('modules.cache').flush_index() end)  -- M6-7: dirty LRU
end)

reaper.defer(loop)
