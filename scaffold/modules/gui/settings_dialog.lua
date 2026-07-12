-- modules/gui/settings_dialog.lua
-- Modal: API key input + Test + Save + Refresh voices.
--
-- NS-2d (2026-05-11): refactored to BeginTabBar layout — 4 sections:
--   General           — API key + Cache (cross-cutting global settings)
--   TTS               — advance cursor + output format + chars used + dialogue split toggle
--   Voice Replacement — output layout + Migrate + Recording (mode-specific)
--   Dubbing           — placeholder dla NS-B (LLM keys + prompts)
--
-- Pattern:
--   1. main UI woła settings_dialog.open() jak user kliknie [Settings]
--   2. settings_dialog.render(ctx, state) wołane KAŻDY frame (musi byc
--      wewnątrz Begin/End głównego okna albo zaraz po End — popup ImGui
--      tworzy własne sub-okno)

local config        = require 'modules.config'
local api           = require 'modules.api'
local cache         = require 'modules.cache'
local theme         = require 'modules.theme'
local importer      = require 'modules.importer'
local voice_admin   = require 'modules.voice_admin'
local async_op      = require 'modules.async_op'

local M = {}

local POPUP_ID = 'Reasonate Settings'

local s = {
  pending_open  = false,
  api_key_buf   = '',
  busy          = false,       -- M2-2: true gdy test_handle/fetch_handle in-flight
  test_handle   = nil,         -- async quota op (Test connection)
  fetch_handle  = nil,         -- async refresh op (Save & fetch voices)
  status_msg    = '',
  status_color  = nil,
  -- NS-B Dubbing: per-provider key buffers (lazy-init in open()).
  dub_llm_buf   = {
    anthropic = '',
    openai    = '',
    gemini    = '',
    deepseek  = '',
  },
  -- [Test] klucza LLM per provider (2026-07-12): handle + wynik.
  llm_test_handles = {},
  llm_test_msg     = {},   -- { [provider] = {ok=bool, text=string} }
}

local COL_OK   = theme.COLORS.status_done
local COL_ERR  = theme.COLORS.status_error
local COL_INFO = theme.COLORS.text_dim

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------
function M.open()
  s.pending_open = true
  s.api_key_buf = config.get_api_key() or ''
  s.status_msg = ''
  -- NS-B Dubbing: pre-fill LLM key buffers z config (user może modyfikować
  -- bez utraty istniejących wartości gdy zamyka popup bez Save).
  for _, p in ipairs(config.LLM_PROVIDERS_PRIORITY) do
    s.dub_llm_buf[p] = config.get_llm_provider_key(p) or ''
  end
end

function M.is_open() return s.pending_open end

----------------------------------------------------------------------------
-- Action handlers.
-- M2-2 (audit 2026-07): Test + Save&fetch były SYNC (api.test_subscription /
-- api.fetch_voices via curl_get mid-frame) — martwa sieć = do ~45 s freeze
-- całego REAPER, a s.busy=true…false w jednym framie nigdy nie renderowane.
-- Teraz: istniejące async opy (voice_admin.spawn_quota / spawn_refresh),
-- handle w stanie dialogu, poll w M.render (dialog renderuje się co frame),
-- busy = realny stan. Quota przeszła tę samą migrację wcześniej
-- (KNOWN-ISSUES-RESOLVED) — dokładnie z tego powodu.
----------------------------------------------------------------------------
local function action_test()
  if s.test_handle then return end
  -- Testujemy klucz Z BUFORA (może być niezapisany) — spawn_quota z override.
  local h = voice_admin.spawn_quota({ api_key = s.api_key_buf })
  if h.status == 'error' then
    s.status_msg   = 'FAIL · ' .. tostring(h.error or 'spawn failed')
    s.status_color = COL_ERR
    return
  end
  s.test_handle  = h
  s.busy         = true
  s.status_msg   = 'Testing key…'
  s.status_color = COL_INFO
end

local function action_save_and_fetch(state)
  if s.fetch_handle then return end
  config.set_api_key(s.api_key_buf)
  local h = voice_admin.spawn_refresh()   -- klucz już zapisany w config
  if h.status == 'error' then
    s.status_msg   = 'Key saved, fetch FAILED · ' .. tostring(h.error or 'spawn failed')
    s.status_color = COL_ERR
    return
  end
  s.fetch_handle = h
  s.busy         = true
  s.status_msg   = 'Key saved · fetching voices…'
  s.status_color = COL_INFO
end

-- Poll async handles (wołane co frame z M.render — także gdy popup zamknięty,
-- żeby wynik in-flight requestu nie przepadł po zamknięciu dialogu).
local function poll_handles(state)
  -- [Test] kluczy LLM (2026-07-12) — per-provider handles.
  for provider, h in pairs(s.llm_test_handles) do
    local llm = require 'modules.llm'
    llm.poll_key_test(h)
    if h.status == 'done' then
      s.llm_test_msg[provider] = { ok = true, text = 'key OK' }
      s.llm_test_handles[provider] = nil
    elseif h.status == 'error' then
      s.llm_test_msg[provider] = { ok = false, text = 'FAIL: ' .. tostring(h.error or '?') }
      s.llm_test_handles[provider] = nil
    end
  end

  if s.test_handle then
    local h = s.test_handle
    voice_admin.poll(h)
    if h.status == 'running' then async_op.force_error_if_stale(h, 'API key test') end
    if h.status == 'done' then
      local q = h.result or {}
      s.status_msg = ('OK · tier "%s" · %d / %d characters used')
        :format(q.tier or '?', q.used or 0, q.total or 0)
      s.status_color = COL_OK
      s.test_handle  = nil
    elseif h.status == 'error' then
      s.status_msg   = 'FAIL · ' .. tostring(h.error or 'unknown error')
      s.status_color = COL_ERR
      s.test_handle  = nil
    end
  end
  if s.fetch_handle then
    local h = s.fetch_handle
    voice_admin.poll(h)
    if h.status == 'running' then async_op.force_error_if_stale(h, 'Voices fetch') end
    if h.status == 'done' then
      local voices = h.result or {}
      api.save_voices_cache(voices)
      state.set_voices(voices)
      s.status_msg = ('Saved · fetched %d voices'):format(#voices)
      s.status_color = COL_OK
      s.fetch_handle = nil
      -- PM9 iter4: refresh quota immediately po Save (header bar pokaże
      -- % used od razu zamiast czekać 5min stale check).
      state.refresh_quota(config.get_api_key())
    elseif h.status == 'error' then
      s.status_msg   = 'Key saved, fetch FAILED · ' .. tostring(h.error or 'unknown')
      s.status_color = COL_ERR
      s.fetch_handle = nil
    end
  end
  s.busy = (s.test_handle ~= nil) or (s.fetch_handle ~= nil)
end

----------------------------------------------------------------------------
-- Tab: General (API key + Cache — cross-cutting global)
----------------------------------------------------------------------------
local function render_general_tab(ctx, state)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx, 'Key is stored in ExtState — never written to .rpp project files.')
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)

  reaper.ImGui_Text(ctx, 'ElevenLabs API key:')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local rv, new_val = reaper.ImGui_InputText(ctx, '##api_key', s.api_key_buf,
    reaper.ImGui_InputTextFlags_Password())
  if rv then s.api_key_buf = new_val end

  reaper.ImGui_Spacing(ctx)

  reaper.ImGui_BeginDisabled(ctx, s.busy or s.api_key_buf == '')
  if theme.button_neutral(ctx, 'Test connection') then action_test() end
  reaper.ImGui_SameLine(ctx)
  if theme.button_primary(ctx, 'Save & fetch voices') then action_save_and_fetch(state) end
  reaper.ImGui_EndDisabled(ctx)
  if s.busy then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    reaper.ImGui_Text(ctx, voice_admin.spinner_glyph())
  end

  if s.status_msg ~= '' then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), s.status_color)
    reaper.ImGui_TextWrapped(ctx, s.status_msg)
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Cache')

  local cs = cache.stats()
  local mb = cs.total_bytes / (1024 * 1024)
  reaper.ImGui_Text(ctx, ('%d files · %.1f MB'):format(cs.count, mb))
  reaper.ImGui_TextDisabled(ctx, cs.dir)

  -- M2-3 (audit 2026-06-10): size cap — oldest-unused evicted at startup
  -- and after each batch. 0 = unlimited.
  reaper.ImGui_SetNextItemWidth(ctx, 120)
  local cap_gb = config.get_cache_max_gb()
  local rv_cap, new_cap = reaper.ImGui_InputDouble(ctx, 'Cache size limit (GB)', cap_gb, 0, 0, '%.1f')
  if rv_cap then
    if new_cap < 0 then new_cap = 0 end
    config.set_cache_max_gb(new_cap)
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_TextDisabled(ctx, '(0 = unlimited)')

  reaper.ImGui_BeginDisabled(ctx, cs.count == 0)
  if theme.button_danger(ctx, 'Clear cache') then
    local choice = reaper.MB(
      ('Delete %d cache files (%.1f MB)?\n\nWARNING: existing AI items in projects will show "missing media" until re-converted.')
        :format(cs.count, mb),
      'Clear Reasonate cache', 1)
    if choice == 1 then
      local removed = cache.clear()
      s.status_msg = ('Cleared %d cache files'):format(removed)
      s.status_color = COL_OK
    end
  end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Appearance')

  local bg_on = config.get_bg_image_enabled()
  local rv_bg, new_bg = reaper.ImGui_Checkbox(ctx,
    'Decorative background', bg_on)
  if rv_bg then config.set_bg_image_enabled(new_bg) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Hand-painted cosmic nebula background. Disable for plain solid theme bg ' ..
      '(slightly less GPU work, distraction-free look).')
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Diagnostics')

  -- M0-3 (audit 2026-07): jeden globalny toggle logów kalibracyjnych
  -- (tempo/volume/pause-split/dub-fit). Default OFF — release czysty.
  local dbg_on = config.get_debug_logging()
  local rv_dbg, new_dbg = reaper.ImGui_Checkbox(ctx,
    'Diagnostic logging (console)', dbg_on)
  if rv_dbg then config.set_debug_logging(new_dbg) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Prints calibration details (Repair tempo/volume/pause-split, Dubbing ' ..
      'tempo-fit) to the REAPER console on every edit/splice.\n' ..
      'Enable when collecting data for pacing/loudness calibration; ' ..
      'opens the console window on first log line.')
  end

  -- T4 (UX-POLISH): About + wsparcie twórcy (wzorzec MaxPane Settings→About).
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'About')
  reaper.ImGui_Text(ctx, ('Reasonate %s'):format(config.APP_VERSION or ''))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'AI voice tools for REAPER · powered by ElevenLabs · by falami.studio (b4s1c) · MIT')
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextDisabled(ctx, 'Support development:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  local util_mod = require 'modules.util'
  if theme.button_neutral(ctx, 'Ko-fi##about_kofi', 0, 0) then
    util_mod.open_url('https://ko-fi.com/quickmd')
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
  if theme.button_neutral(ctx, 'Buy Me a Coffee##about_bmc', 0, 0) then
    util_mod.open_url('https://buymeacoffee.com/bsroczynskh')
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
  if theme.button_neutral(ctx, 'PayPal##about_pp', 0, 0) then
    util_mod.open_url('https://paypal.me/b451c')
  end

  -- Update-check (PHASE-USER-GUIDE §3). Ukryty dopóki UPDATE_REPO puste
  -- (przed publikacją). Poll robi update_check.tick() w defer loop
  -- reasonate.lua — tu tylko spawn + render wyniku.
  if (config.UPDATE_REPO or '') ~= '' then
    local update_check = require 'modules.update_check'
    reaper.ImGui_Spacing(ctx)
    if update_check.is_checking() then
      reaper.ImGui_TextDisabled(ctx, 'Checking for updates...')
    else
      if theme.button_neutral(ctx, 'Check for updates##about_upd', 0, 0) then
        update_check.spawn_check()
      end
      local r = update_check.last_result
      if r then
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
        if r.status == 'ok' and r.newer then
          reaper.ImGui_Text(ctx, ('%s available'):format(r.tag))
        elseif r.status == 'ok' then
          reaper.ImGui_TextDisabled(ctx, "You're up to date")
        else
          reaper.ImGui_TextDisabled(ctx, 'Check failed: ' .. (r.message or '?'))
        end
      elseif update_check.available() then
        -- Wynik cichego checku z poprzedniego startu (persystowany).
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
        reaper.ImGui_Text(ctx, ('%s available'):format(update_check.available()))
      end
      local show_open = (r and r.status == 'ok' and r.newer)
        or (not r and update_check.available() ~= nil)
      if show_open then
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
        if theme.button_neutral(ctx, 'Open releases##about_rel', 0, 0) then
          util_mod.open_url(update_check.releases_url())
        end
      end
    end
  end
end

----------------------------------------------------------------------------
-- Tab: TTS (advance cursor + output format + chars used + dialogue split)
----------------------------------------------------------------------------
local function render_tts_tab(ctx, state)
  -- Edit cursor advance po Generate w TTS mode. Default ON.
  local cur_advance = config.get_tts_advance_cursor()
  local rv_adv, new_adv = reaper.ImGui_Checkbox(ctx,
    'After Generate advance edit cursor to end of generated item',
    cur_advance)
  if rv_adv then config.set_tts_advance_cursor(new_adv) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'ON: cursor advances — subsequent Generate places items sequentially.\n' ..
      'OFF: cursor stays — each Generate places item at same position.')
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Multi-speaker dialogue')

  -- NS-2d: split master mp3 na per-speaker tracki via Scribe v2 diarization.
  -- Po dialogue Generate spawn STT z diarize=true → parse speaker regions →
  -- utwórz N tracków obok master + items per region (same source mp3).
  local cur_split = config.get_tts_dialogue_split_per_speaker()
  local rv_split, new_split = reaper.ImGui_Checkbox(ctx,
    'After dialogue Generate split into per-speaker tracks (uses Scribe v2 diarization)',
    cur_split)
  if rv_split then config.set_tts_dialogue_split_per_speaker(new_split) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'ON: after Generate, dialogue triggers STT with diarization → creates N\n' ..
      'tracks per speaker next to the master target track. Each speaker gets\n' ..
      'their own audio regions on a separate track (referencing the same source mp3).\n\n' ..
      'Cost: +1 STT call per dialogue Generate (~a few cents per audio minute).\n' ..
      'Accuracy: ~75-85% diarization in typical studio audio. May misalign\n' ..
      'on overlap or when two speakers have similar voices.\n\n' ..
      'OFF: master item stays as is, manual editing on the timeline.')
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Output')

  local FORMAT_OPTIONS = {
    { value = 'mp3_44100_128', label = 'MP3 44.1 kHz · 128 kbps',
      tooltip = 'Smallest file. Free tier compatible.' },
    { value = 'mp3_44100_192', label = 'MP3 44.1 kHz · 192 kbps  (default)',
      tooltip = 'Best MP3 quality. Requires Creator+ tier.' },
    { value = 'pcm_44100',     label = 'PCM 44.1 kHz · uncompressed',
      tooltip = 'Largest file, best quality. Requires Pro+ tier.' },
  }
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Output format:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 280)
  local cur_format = config.get_tts_output_format()
  local cur_label  = cur_format
  for _, o in ipairs(FORMAT_OPTIONS) do
    if o.value == cur_format then cur_label = o.label; break end
  end
  if reaper.ImGui_BeginCombo(ctx, '##tts_output_format', cur_label) then
    for _, o in ipairs(FORMAT_OPTIONS) do
      if reaper.ImGui_Selectable(ctx, o.label, o.value == cur_format) then
        config.set_tts_output_format(o.value)
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, o.tooltip)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Billing')

  local chars_used = config.get_tts_chars_used()
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, ('TTS characters generated (all-time): %s'):format(
    tostring(chars_used)))
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if reaper.ImGui_SmallButton(ctx, 'Reset##tts_chars_reset') then
    config.reset_tts_chars_used()
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Zero the counter. Useful after monthly billing cycle reset.\n' ..
      'Cache hits (re-generated identical text+voice+settings+seed) are not counted.')
  end
end

----------------------------------------------------------------------------
-- Tab: Voice Replacement (output layout + Migrate + Recording)
----------------------------------------------------------------------------
local function render_voice_replacement_tab(ctx, state)
  reaper.ImGui_SeparatorText(ctx, 'Output layout')

  local LAYOUT_OPTIONS = {
    { label = 'Folder child (AI track inside source folder)', value = 'folder' },
    { label = 'Flat sibling (AI track next to source)',       value = 'flat'   },
  }
  local cur_layout = config.get_output_layout()
  local cur_layout_label = '?'
  for _, opt in ipairs(LAYOUT_OPTIONS) do
    if opt.value == cur_layout then cur_layout_label = opt.label; break end
  end
  reaper.ImGui_Text(ctx, 'New conversions:')
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 320)
  if reaper.ImGui_BeginCombo(ctx, '##out_layout', cur_layout_label) then
    for _, opt in ipairs(LAYOUT_OPTIONS) do
      if reaper.ImGui_Selectable(ctx, opt.label, opt.value == cur_layout) then
        config.set_output_layout(opt.value)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  -- Migration button — convert flat sibling AI tracks to folder layout.
  local stats = importer.count_migratable()
  local total = stats.total or 0
  if total > 0 then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_TextWrapped(ctx, ('Project has %d source→AI track pairs (%d already folder, %d eligible to migrate, %d skipped — AI not adjacent).')
      :format(total, stats.already_folder or 0, stats.migrated or 0, stats.skipped or 0))
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_BeginDisabled(ctx, (stats.migrated or 0) == 0)
    if theme.button_neutral(ctx, 'Migrate AI tracks to folder layout') then
      reaper.Undo_BeginBlock()
      local res = importer.migrate_to_folder_layout()
      reaper.Undo_EndBlock('Reasonate: migrate AI tracks to folder layout', -1)
      s.status_msg = ('Migrated %d · already folder %d · skipped %d')
        :format(res.migrated, res.already_folder, res.skipped)
      s.status_color = COL_OK
      reaper.TrackList_AdjustWindows(false)
      reaper.UpdateArrange()
    end
    reaper.ImGui_EndDisabled(ctx)
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Recording')

  -- Input channel: simple combo (Mono ch 1 / Mono ch 2 / Stereo 1+2)
  local INPUT_OPTIONS = {
    { label = 'Mono ch 1',   value = 0 },
    { label = 'Mono ch 2',   value = 1 },
    { label = 'Stereo 1+2',  value = 1024 },
  }
  local cur_input = config.get_record_input()
  local cur_input_label = 'Custom (' .. tostring(cur_input) .. ')'
  for _, opt in ipairs(INPUT_OPTIONS) do
    if opt.value == cur_input then cur_input_label = opt.label; break end
  end
  reaper.ImGui_Text(ctx, 'Input channel:')
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 180)
  if reaper.ImGui_BeginCombo(ctx, '##rec_input', cur_input_label) then
    for _, opt in ipairs(INPUT_OPTIONS) do
      local sel = opt.value == cur_input
      if reaper.ImGui_Selectable(ctx, opt.label, sel) then
        config.set_record_input(opt.value)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  -- Pre-roll: 0 / 1 / 3 / 5 secs
  local PRE_OPTIONS = { 0, 1, 3, 5 }
  local cur_pre = config.get_record_pre_roll()
  reaper.ImGui_Text(ctx, 'Pre-roll countdown:')
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 180)
  if reaper.ImGui_BeginCombo(ctx, '##rec_preroll',
      cur_pre == 0 and 'Off (instant)' or (tostring(cur_pre) .. ' seconds')) then
    for _, v in ipairs(PRE_OPTIONS) do
      local lbl = v == 0 and 'Off (instant)' or (tostring(v) .. ' seconds')
      if reaper.ImGui_Selectable(ctx, lbl, v == cur_pre) then
        config.set_record_pre_roll(v)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  -- Monitor mode: 0=off, 1=on, 2=auto (REAPER's "tape mode")
  local MON_OPTIONS = {
    { label = 'On (always — hear yourself)', value = 1 },
    { label = 'Off',                          value = 0 },
    { label = 'Auto (on when playing/rec)',   value = 2 },
  }
  local cur_mon = config.get_record_monitor()
  local cur_mon_label = '?'
  for _, opt in ipairs(MON_OPTIONS) do
    if opt.value == cur_mon then cur_mon_label = opt.label; break end
  end
  reaper.ImGui_Text(ctx, 'Input monitor:')
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 250)
  if reaper.ImGui_BeginCombo(ctx, '##rec_monitor', cur_mon_label) then
    for _, opt in ipairs(MON_OPTIONS) do
      if reaper.ImGui_Selectable(ctx, opt.label, opt.value == cur_mon) then
        config.set_record_monitor(opt.value)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
end

----------------------------------------------------------------------------
-- Tab: Dubbing (NS-B real impl)
--
-- 4 LLM provider sections (Anthropic / OpenAI / Gemini / DeepSeek) + Dubbing
-- defaults (TTS model / style preset / forced align / voice isolator).
-- Auto-detect first configured provider — user nie musi konfigurować wszystkich.
----------------------------------------------------------------------------

-- Per-provider model options (verified empirically 2026-05 per audit).
-- W2 s6 (2026-06-11): listy zweryfikowane u źródeł (oficjalne docs każdego
-- providera) — Opus 4.7→4.8 (aktualny premium), Gemini odświeżone o rodzinę
-- 3.x (2.0 wyłączone 2026-06-01), + nowi providerzy Grok/Mistral.
local LLM_MODEL_OPTIONS = {
  anthropic = {
    { value = 'claude-sonnet-4-6',  label = 'Claude Sonnet 4.6  (recommended)',
      tooltip = 'Best quality dla Polish dialogue. $3/$15 per 1M.\nWith prompt caching 90% off subsequent calls.' },
    { value = 'claude-opus-4-8',    label = 'Claude Opus 4.8  (premium)',
      tooltip = 'Most capable Opus. $5/$25 per 1M. Best for complex dramatic context.' },
    { value = 'claude-haiku-4-5',   label = 'Claude Haiku 4.5  (fastest/cheapest)',
      tooltip = '$1/$5 per 1M. Lower quality — use for drafts / bulk volume.' },
  },
  openai = {
    { value = 'gpt-5.4-mini',  label = 'GPT-5.4 mini  (recommended sweet spot)',
      tooltip = '$0.75/$4.50 per 1M. Solid JSON schema enforcement.' },
    { value = 'gpt-5.4-nano',  label = 'GPT-5.4 nano  (cheapest)',
      tooltip = '$0.20/$1.25 per 1M. Lower quality but still schema-enforced.' },
    { value = 'gpt-5.4',       label = 'GPT-5.4',
      tooltip = '$2.50/$15 per 1M. Higher quality.' },
    { value = 'gpt-5.5',       label = 'GPT-5.5  (flagship)',
      tooltip = '$5/$30 per 1M. Top quality with 1M context.' },
  },
  gemini = {
    { value = 'gemini-2.5-flash',      label = 'Gemini 2.5 Flash  (recommended, free tier)',
      tooltip = '$0.30/$2.50 per 1M. Generous free quota — great dla testing.' },
    { value = 'gemini-3.5-flash',      label = 'Gemini 3.5 Flash  (newest, premium)',
      tooltip = '$1.50/$9 per 1M, 1M context. GA since May 2026 — strongest Gemini for agentic/translation work.' },
    { value = 'gemini-3.1-pro',        label = 'Gemini 3.1 Pro  (2M context)',
      tooltip = 'Huge 2M context window. Pick when a single batch must see very long material.' },
    { value = 'gemini-2.5-flash-lite', label = 'Gemini 2.5 Flash Lite  (cheapest)',
      tooltip = '$0.10/$0.40 per 1M.' },
  },
  deepseek = {
    { value = 'deepseek-v4-flash', label = 'DeepSeek V4 Flash  (recommended)',
      tooltip = '$0.14/$0.28 per 1M — cheapest. Quality for non-English untested.' },
    { value = 'deepseek-v4-pro',   label = 'DeepSeek V4 Pro',
      tooltip = '$0.435/$0.87 per 1M. Higher quality.' },
  },
  grok = {
    { value = 'grok-4.3',      label = 'Grok 4.3  (recommended)',
      tooltip = 'xAI flagship — frontier quality at $1.25/$2.50 per 1M, 1M context.\nFull JSON schema enforcement.' },
    { value = 'grok-4.1-fast', label = 'Grok 4.1 Fast  (cheapest)',
      tooltip = '$0.20/$0.50 per 1M, 2M context. Older generation — drafts / bulk volume.' },
  },
  mistral = {
    { value = 'mistral-medium-latest', label = 'Mistral Medium  (recommended)',
      tooltip = '$0.40/$2 per 1M. EU-based provider — data processed in Europe (GDPR-friendly for client material).' },
    { value = 'mistral-large-latest',  label = 'Mistral Large  (premium)',
      tooltip = '$2/$6 per 1M. Strongest Mistral.' },
    { value = 'mistral-small-latest',  label = 'Mistral Small  (cheapest)',
      tooltip = '~$0.20/$0.60 per 1M. Drafts / bulk volume.' },
  },
}

local LLM_PROVIDER_LABELS = {
  anthropic = 'Anthropic Claude',
  openai    = 'OpenAI',
  gemini    = 'Google Gemini',
  deepseek  = 'DeepSeek',
  grok      = 'xAI Grok',
  mistral   = 'Mistral (EU)',
}

local TTS_MODEL_OPTIONS = {
  { value = 'eleven_multilingual_v2', label = 'Multilingual v2  (default, balanced)',
    tooltip = '29 languages incl. Polish. No audio tags. 1 credit/char. Stable, recommended for most dubbing.' },
  { value = 'eleven_v3',              label = 'Eleven v3  (premium, [whispers]/[laughs])',
    tooltip = '70 languages. Inline audio tags supported ([whispers], [laughs], [sighs]). Slower. 1 credit/char.' },
  { value = 'eleven_turbo_v2_5',      label = 'Turbo v2.5  (deprecated — use Flash)',
    tooltip = '32 languages. ~300ms latency. No audio tags.\nDeprecated by ElevenLabs — Flash v2.5 is functionally equivalent and 50% cheaper.' },
  { value = 'eleven_flash_v2_5',      label = 'Flash v2.5  (fastest + 50% off)',
    tooltip = '32 languages. ~75ms latency. 0.5 credit/char (50% off). No audio tags. Great dla bulk drafts.' },
}

-- Generowane z dubbing_project (single source of truth od 2026-06-10).
local STYLE_PRESET_OPTIONS = (function()
  local dub_project = require 'modules.dubbing_project'
  local opts = {}
  for _, key in ipairs(dub_project.STYLE_PRESET_ORDER) do
    opts[#opts + 1] = { value = key, label = dub_project.STYLE_PRESETS[key].label }
  end
  return opts
end)()

-- Per-provider section renderer (DRY across 4 providers).
-- 2026-05-14 PM8: wrapped w CollapsingHeader żeby zwijać/rozwijać per
-- provider (4 providers × ~4 rows = 16 rows of clutter when expanded —
-- user request collapsed by default unless configured).
local function render_provider_section(ctx, provider)
  local label = LLM_PROVIDER_LABELS[provider] or provider
  local has_key = config.has_llm_provider_key(provider)
  -- ### keeps stable ID even if visible label changes (z " · configured" suffix).
  local hdr_label = has_key
    and ('%s · configured###llm_hdr_%s'):format(label, provider)
    or  ('%s###llm_hdr_%s'):format(label, provider)
  local flags = has_key and reaper.ImGui_TreeNodeFlags_DefaultOpen() or 0
  if not reaper.ImGui_CollapsingHeader(ctx, hdr_label, nil, flags) then return end

  -- Key input (password masked) + Save + Clear
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'API key:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 340)
  local rv, new_val = reaper.ImGui_InputText(ctx, '##llm_key_' .. provider,
    s.dub_llm_buf[provider], reaper.ImGui_InputTextFlags_Password())
  if rv then s.dub_llm_buf[provider] = new_val end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_BeginDisabled(ctx, s.dub_llm_buf[provider] == ''
    or s.dub_llm_buf[provider] == (config.get_llm_provider_key(provider) or ''))
  if reaper.ImGui_SmallButton(ctx, 'Save##save_' .. provider) then
    config.set_llm_provider_key(provider, s.dub_llm_buf[provider])
    s.status_msg = ('%s key saved'):format(label)
    s.status_color = COL_OK
  end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_BeginDisabled(ctx, not config.has_llm_provider_key(provider))
  if reaper.ImGui_SmallButton(ctx, 'Clear##clear_' .. provider) then
    config.set_llm_provider_key(provider, '')
    s.dub_llm_buf[provider] = ''
    s.llm_test_msg[provider] = nil
    s.status_msg = ('%s key cleared'):format(label)
    s.status_color = COL_INFO
  end
  reaper.ImGui_EndDisabled(ctx)

  -- [Test] (2026-07-12, user request — parity z ElevenLabs "Test
  -- connection"): darmowy GET list-models; testuje klucz Z BUFORA
  -- (jeszcze nie zapisany), fallback na zapisany.
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  local testing = s.llm_test_handles[provider] ~= nil
  local has_any_key = s.dub_llm_buf[provider] ~= '' or config.has_llm_provider_key(provider)
  reaper.ImGui_BeginDisabled(ctx, testing or not has_any_key)
  if reaper.ImGui_SmallButton(ctx, 'Test##llmtest_' .. provider) then
    local llm = require 'modules.llm'
    local h = llm.spawn_key_test(provider, s.dub_llm_buf[provider])
    if h.status == 'error' then
      s.llm_test_msg[provider] = { ok = false, text = h.error or 'spawn failed' }
    else
      s.llm_test_handles[provider] = h
      s.llm_test_msg[provider] = nil
    end
  end
  reaper.ImGui_EndDisabled(ctx)

  if testing then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    reaper.ImGui_TextDisabled(ctx, 'testing...')
  elseif s.llm_test_msg[provider] then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    local r = s.llm_test_msg[provider]
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
      r.ok and COL_OK or COL_ERR)
    reaper.ImGui_Text(ctx, r.text)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  -- Model dropdown
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Model:   ')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 320)
  local cur_model = config.get_llm_provider_model(provider)
  local cur_label = cur_model
  for _, o in ipairs(LLM_MODEL_OPTIONS[provider] or {}) do
    if o.value == cur_model then cur_label = o.label; break end
  end
  if reaper.ImGui_BeginCombo(ctx, '##llm_model_' .. provider, cur_label) then
    for _, o in ipairs(LLM_MODEL_OPTIONS[provider] or {}) do
      if reaper.ImGui_Selectable(ctx, o.label, o.value == cur_model) then
        config.set_llm_provider_model(provider, o.value)
      end
      if reaper.ImGui_IsItemHovered(ctx) and o.tooltip then
        reaper.ImGui_SetTooltip(ctx, o.tooltip)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
end

----------------------------------------------------------------------------
-- Tab: AI (2026-06-11, user decision) — LLM przestał być dubbingowy
-- (konsumenci: Dubbing translate / TTS Enhance / SFX scene+rephrase).
-- Klucze + modele providerów przeniesione z zakładki Dubbing + per-feature
-- nadpisania (np. tani model do Enhance, mocny do tłumaczeń).
----------------------------------------------------------------------------
local LLM_TASK_ROWS = {
  { task = 'translate', label = 'Dubbing — translation',
    hint = 'Quality-critical: a strong model pays off (context, idioms, register).' },
  { task = 'enhance',   label = 'TTS — Enhance (audio tags)',
    hint = 'Short, frequent prompts — a fast/cheap model works great here.' },
  { task = 'sfx',       label = 'SFX — scene ideas / New idea',
    hint = 'Creative but short — a mid/cheap model is usually enough.' },
}

local function render_ai_tab(ctx)
  -- Provider status header
  local effective = config.effective_llm_provider()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  if effective then
    reaper.ImGui_TextWrapped(ctx,
      ('Default LLM provider: %s (%s) — used by Dubbing translation, TTS Enhance and SFX scene analysis.')
        :format(LLM_PROVIDER_LABELS[effective] or effective,
                config.get_llm_provider_model(effective) or '?'))
  else
    reaper.ImGui_TextWrapped(ctx,
      'No LLM provider configured. Add at least one API key below — Reasonate auto-detects first configured (priority: Anthropic → OpenAI → Gemini → DeepSeek).')
  end
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- Active provider override (optional — default = first configured / auto)
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Provider override:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 220)
  local cur_active = config.get_llm_provider_active() or ''
  local override_label = (cur_active == '') and 'Auto (first configured)'
    or (LLM_PROVIDER_LABELS[cur_active] or cur_active)
  if reaper.ImGui_BeginCombo(ctx, '##llm_active', override_label) then
    if reaper.ImGui_Selectable(ctx, 'Auto (first configured)', cur_active == '') then
      config.set_llm_provider_active('')
    end
    for _, p in ipairs(config.LLM_PROVIDERS_PRIORITY) do
      local sel = cur_active == p
      local has_key = config.has_llm_provider_key(p)
      local lbl = LLM_PROVIDER_LABELS[p] or p
      if not has_key then lbl = lbl .. '  (no key)' end
      reaper.ImGui_BeginDisabled(ctx, not has_key)
      if reaper.ImGui_Selectable(ctx, lbl, sel) then
        config.set_llm_provider_active(p)
      end
      reaper.ImGui_EndDisabled(ctx)
    end
    reaper.ImGui_EndCombo(ctx)
  end

  reaper.ImGui_Spacing(ctx)

  -- 4 provider sections (keys + default model)
  for _, p in ipairs(config.LLM_PROVIDERS_PRIORITY) do
    render_provider_section(ctx, p)
    reaper.ImGui_Spacing(ctx)
  end

  -- Per-feature overrides (2026-06-11)
  reaper.ImGui_SeparatorText(ctx, 'Per-feature model')
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'Each AI feature can use its own provider and model. "Default" follows the provider above. ' ..
    'If an overridden provider loses its key, the feature silently falls back to the default.')
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)

  for _, row in ipairs(LLM_TASK_ROWS) do
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, row.label)
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, row.hint)
    end
    reaper.ImGui_SameLine(ctx, 240)

    -- Provider per task
    reaper.ImGui_SetNextItemWidth(ctx, 170)
    local cur_p = config.get_llm_task_provider(row.task) or ''
    local p_label = (cur_p == '') and 'Default'
      or (LLM_PROVIDER_LABELS[cur_p] or cur_p)
    if cur_p ~= '' and not config.has_llm_provider_key(cur_p) then
      p_label = p_label .. '  (no key!)'
    end
    if reaper.ImGui_BeginCombo(ctx, '##task_p_' .. row.task, p_label) then
      if reaper.ImGui_Selectable(ctx, 'Default', cur_p == '') then
        config.set_llm_task_provider(row.task, '')
        config.set_llm_task_model(row.task, '')   -- model należy do providera
      end
      for _, p in ipairs(config.LLM_PROVIDERS_PRIORITY) do
        local has_key = config.has_llm_provider_key(p)
        local lbl = LLM_PROVIDER_LABELS[p] or p
        if not has_key then lbl = lbl .. '  (no key)' end
        reaper.ImGui_BeginDisabled(ctx, not has_key)
        if reaper.ImGui_Selectable(ctx, lbl .. '##tp_' .. row.task .. p, cur_p == p) then
          config.set_llm_task_provider(row.task, p)
          config.set_llm_task_model(row.task, '')
        end
        reaper.ImGui_EndDisabled(ctx)
      end
      reaper.ImGui_EndCombo(ctx)
    end

    -- Model per task (lista modeli resolved providera)
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    reaper.ImGui_SetNextItemWidth(ctx, 270)
    local res_p = (cur_p ~= '' and config.has_llm_provider_key(cur_p)) and cur_p
      or config.effective_llm_provider()
    local cur_m = config.get_llm_task_model(row.task) or ''
    local m_label = 'Provider default'
    if cur_m ~= '' then
      m_label = cur_m
      for _, o in ipairs(LLM_MODEL_OPTIONS[res_p] or {}) do
        if o.value == cur_m then m_label = o.label break end
      end
    end
    if reaper.ImGui_BeginCombo(ctx, '##task_m_' .. row.task, m_label) then
      if reaper.ImGui_Selectable(ctx, 'Provider default', cur_m == '') then
        config.set_llm_task_model(row.task, '')
      end
      for _, o in ipairs(LLM_MODEL_OPTIONS[res_p] or {}) do
        if reaper.ImGui_Selectable(ctx, o.label .. '##tm_' .. row.task, o.value == cur_m) then
          config.set_llm_task_model(row.task, o.value)
        end
        if reaper.ImGui_IsItemHovered(ctx) and o.tooltip then
          reaper.ImGui_SetTooltip(ctx, o.tooltip)
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'Keys stored in ExtState (REAPER user data). Never written to .rpp project files. ' ..
    'On disk written as chmod-600 header files in reasonate_tmp/ only when actually used.')
  reaper.ImGui_PopStyleColor(ctx, 1)
end

----------------------------------------------------------------------------
-- Repair tab (2026-06-10, user decision): tempo generowanej mowy opcjonalne.
-- Default OFF = natural (głos + kontekst TTS decydują); manual speed żyje
-- w panelu Repair (Voice settings → Speed). Volume match zawsze ON.
----------------------------------------------------------------------------
local function render_repair_tab(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Pacing of generated speech')

  local match_pace = config.get_repair_match_pace()
  local rv, v = reaper.ImGui_Checkbox(ctx,
    'Auto-match speaker pace##set_rep_pace', match_pace)
  if rv then config.set_repair_match_pace(v) end

  reaper.ImGui_Indent(ctx, 22)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  if match_pace then
    reaper.ImGui_TextWrapped(ctx,
      'ON — Reasonate measures the tempo of the source recording and sets the '
      .. 'TTS speed to match it. May regenerate a patch once to hit the target, '
      .. 'and gently time-stretch it at the speed limit. Best for tight, '
      .. 'fast-paced narration.')
  else
    reaper.ImGui_TextWrapped(ctx,
      'OFF (default) — the voice and the surrounding sentence decide the '
      .. 'pacing naturally. Want it faster or slower? Set the Speed slider '
      .. 'manually in the Repair panel under Voice settings.')
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Unindent(ctx, 22)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
  reaper.ImGui_TextWrapped(ctx,
    'Loudness matching is always on — patches are level-matched to the '
    .. 'surrounding words automatically.')
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- M5-9c (user decision 2026-07-11): ripple wszystkich tracków, default OFF.
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Timeline shifting')
  local ripple_all = config.get_repair_ripple_all_tracks()
  local rv_r, v_r = reaper.ImGui_Checkbox(ctx,
    'Ripple all tracks##set_rep_ripple', ripple_all)
  if rv_r then config.set_repair_ripple_all_tracks(v_r) end
  reaper.ImGui_Indent(ctx, 22)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  if ripple_all then
    reaper.ImGui_TextWrapped(ctx,
      'ON — when a repair changes the length of the dialogue, items on ALL '
      .. 'tracks after the edit point shift together (music/SFX beds stay '
      .. 'in sync with the dialogue).')
  else
    reaper.ImGui_TextWrapped(ctx,
      'OFF (default) — only the edited track shifts. Other tracks keep '
      .. 'their positions (safe when they are not synced to the dialogue).')
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Unindent(ctx, 22)
end

local function render_dubbing_tab(ctx, state)
  -- LLM providers przeniesione do zakładki AI (2026-06-11) — używają ich
  -- też TTS Enhance i SFX. Tu zostają wyłącznie ustawienia dubbingowe.
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'LLM providers, API keys and per-feature models live in the AI tab.')
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)

  -- Dubbing defaults
  reaper.ImGui_SeparatorText(ctx, 'Dubbing defaults')

  -- Default TTS model
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Default TTS model:   ')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 360)
  local cur_tts = config.get_dubbing_default_tts_model()
  local cur_tts_label = cur_tts
  for _, o in ipairs(TTS_MODEL_OPTIONS) do
    if o.value == cur_tts then cur_tts_label = o.label; break end
  end
  if reaper.ImGui_BeginCombo(ctx, '##dub_tts_model', cur_tts_label) then
    for _, o in ipairs(TTS_MODEL_OPTIONS) do
      if reaper.ImGui_Selectable(ctx, o.label, o.value == cur_tts) then
        config.set_dubbing_default_tts_model(o.value)
      end
      if reaper.ImGui_IsItemHovered(ctx) and o.tooltip then
        reaper.ImGui_SetTooltip(ctx, o.tooltip)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  -- Default style preset
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Default style preset:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 240)
  local cur_style = config.get_dubbing_default_style_preset()
  local cur_style_label = cur_style
  for _, o in ipairs(STYLE_PRESET_OPTIONS) do
    if o.value == cur_style then cur_style_label = o.label; break end
  end
  if reaper.ImGui_BeginCombo(ctx, '##dub_style', cur_style_label) then
    for _, o in ipairs(STYLE_PRESET_OPTIONS) do
      if reaper.ImGui_Selectable(ctx, o.label, o.value == cur_style) then
        config.set_dubbing_default_style_preset(o.value)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  -- User 2026-07-11: gdzie lądują tracki [Dub LANG: mówca].
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Dub track placement:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 240)
  local cur_lay = config.get_dubbing_track_layout()
  local lay_label = (cur_lay == 'flat')
    and 'Below source track (flat)' or 'Inside source folder'
  if reaper.ImGui_BeginCombo(ctx, '##dub_track_layout', lay_label) then
    if reaper.ImGui_Selectable(ctx, 'Inside source folder', cur_lay == 'folder') then
      config.set_dubbing_track_layout('folder')
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Dub tracks become children of the source track folder.\n'
        .. 'The source fader/mute controls source + dubs TOGETHER.')
    end
    if reaper.ImGui_Selectable(ctx, 'Below source track (flat)', cur_lay == 'flat') then
      config.set_dubbing_track_layout('flat')
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Dub tracks are plain tracks below the source (outside its folder).\n'
        .. 'Source volume/mute does NOT affect the dubs — independent mixing.')
    end
    reaper.ImGui_EndCombo(ctx)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Applies to NEWLY created dub tracks. Existing dub tracks stay where\n'
      .. 'they are (drag them in REAPER if you want to move them).')
  end

  -- M5-6 (advanced): czułość rozdzielania mówców przy diarize.
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Speaker separation: ')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_SetNextItemWidth(ctx, 240)
  local cur_thr = config.get_dubbing_diarization_threshold()
  local thr_buf = cur_thr and tostring(cur_thr) or ''
  local rv_thr, new_thr = reaper.ImGui_InputText(ctx, '##dub_diar_thr', thr_buf)
  if rv_thr then config.set_dubbing_diarization_threshold(new_thr) end
  -- Hover łapany NA POLU input (fix 2026-07-11: tooltip wisiał na "(auto)").
  local thr_hover = reaper.ImGui_IsItemHovered(ctx)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
  reaper.ImGui_TextDisabled(ctx, cur_thr and '' or '(auto)')
  if thr_hover or reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Advanced: how eagerly speaker detection decides "this is a DIFFERENT\n' ..
      'person" during project analysis. Empty = automatic (server default,\n' ..
      'about 0.22) - recommended.\n\n' ..
      'One person got split into two detected voices? Try HIGHER, e.g. 0.3.\n' ..
      'Two similar people merged into one? Try LOWER, e.g. 0.15.\n' ..
      'Applies to NEW transcription runs only (re-analyze the project).')
  end

  reaper.ImGui_Spacing(ctx)

  -- Toggles
  local cur_fa = config.get_dubbing_forced_align_auto()
  local rv_fa, new_fa = reaper.ImGui_Checkbox(ctx,
    'Auto-run Forced Alignment after each Generate Dub', cur_fa)
  if rv_fa then config.set_dubbing_forced_align_auto(new_fa) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'ON (default): after TTS, Reasonate runs POST /v1/forced-alignment\n' ..
      'on generated audio + translated text → per-word timestamps. Splice uses these\n' ..
      'timestamps when source word count == target (precise lip-sync). Otherwise falls\n' ..
      'back to full-segment splice (Phase 11 pattern).\n\n' ..
      'OFF: full-segment splice only. Fewer API calls / lower cost, but less precise\n' ..
      'splice for 1:1 word matches.')
  end

  local cur_vi = config.get_dubbing_voice_isolator_preclean()
  local rv_vi, new_vi = reaper.ImGui_Checkbox(ctx,
    'Default: Voice Isolator pre-clean source audio', cur_vi)
  if rv_vi then config.set_dubbing_voice_isolator_preclean(new_vi) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'When ON, Start Dubbing modal pre-checks "Voice Isolator" option.\n' ..
      'User can still toggle off per project. Useful when source has BG noise / music\n' ..
      '(STT diarize accuracy ↑). Cost: extra credits per source-minute.')
  end

  -- Force every dub item to match source segment span (no overlap, uniform stretch
  -- na full-segment path).
  local cur_fss = config.get_dubbing_force_segment_span()
  local rv_fss, new_fss = reaper.ImGui_Checkbox(ctx,
    'Stretch dub items to source segment span (prevents overlap)', cur_fss)
  if rv_fss then config.set_dubbing_force_segment_span(new_fss) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'ON (default): each dub item D_LENGTH = source segment span. Audio uniformly\n'
        .. 'time-stretched (pitch-preserving) to fit. Adjacent items same speaker\n'
        .. 'never overlap. Item start/end align z source segment exactly.\n\n'
        .. 'OFF: dub item uses TTS audio native length, position = seg.t_start - lead_sil\n'
        .. '(speech onset alignment). Adjacent items same speaker CAN overlap if TTS\n'
        .. 'audio longer than source span (typical PL/DE/RU translations +20-40% chars).\n\n'
        .. 'Time-stretch quality depends on REAPER Preferences → Audio → "Default time\n'
        .. 'stretch mode for new items" — use élastique 3 Pro (Soloist Monophonic).')
  end

  -- Short-segment threshold — segments shorter than this skip force-span stretch.
  if cur_fss then
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, '   Short-segment bypass:')
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    -- Width 140: enough dla '%.2f s' (e.g., "0.80 s" ~5 chars) + ImGui's
    -- internal -/+ step buttons rendered w InputDouble field. 80px było za
    -- mało — value nie widoczna (PM8 user feedback).
    reaper.ImGui_SetNextItemWidth(ctx, 140)
    local cur_thr = config.get_dubbing_short_segment_threshold_s()
    local rv_thr, new_thr = reaper.ImGui_InputDouble(ctx, '##short_seg_thr', cur_thr, 0.1, 0.5, '%.2f s')
    if rv_thr then
      if new_thr < 0 then new_thr = 0 end
      if new_thr > 5 then new_thr = 5 end
      config.set_dubbing_short_segment_threshold_s(new_thr)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Segments shorter than this threshold (seconds) SKIP force-span stretch —\n'
          .. 'short interjections ("yeah", "no", "ok", "right") should not be\n'
          .. 'aggressively stretched to the source span (turns them into robotic blobs).\n'
          .. 'Default 0.8s covers typical interjections. Brief overlap with neighbor\n'
          .. 'is acceptable for short segments.\n\n'
          .. 'Set 0 to disable bypass (stretch every segment).')
    end
  end

  -- Per-word splice using REAPER stretch markers (elastic pause redistribution).
  local cur_pw = config.get_dubbing_per_word_splice()
  local rv_pw, new_pw = reaper.ImGui_Checkbox(ctx,
    'Per-word lip-sync (elastic stretch markers — requires forced alignment)', cur_pw)
  if rv_pw then config.set_dubbing_per_word_splice(new_pw) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'ON: After forced alignment, splice creates a SINGLE item per segment with REAPER\n'
        .. 'stretch markers. Algorithm "elastic pause redistribution":\n'
        .. '  • each word gets a uniform rate clamped to ±12% from natural tempo\n'
        .. '  • pauses between words absorb the remaining stretch budget\n'
        .. '  • markers fall on word boundaries; transitions in silence = inaudible\n'
        .. '  • item span = source segment span (no overlap)\n\n'
        .. 'Requires source word count ≈ TTS word count. Tolerance per-language:\n'
        .. '  EN 20%% / PL/CS/RU/UK/DE/FI/HU 30%% / KO 40%% / JA/ZH 50%%.\n'
        .. 'Otherwise falls back to full-segment splice.\n\n'
        .. 'IMPORTANT — time-stretch algorithm: set in REAPER Preferences → Audio →\n'
        .. '"Default time stretch mode for new items":\n'
        .. '  élastique 3 Pro (Soloist Monophonic) -- cleanest for speech/vocals\n'
        .. '  élastique 3 Pro (Tonal)              -- good alternative\n'
        .. 'Standard "REAPER stretch" produces artifacts.\n\n'
        .. 'OFF (default): full-segment splice only. Robust for most use cases.\n'
        .. 'Turn ON for animation sync / video lip-sync.')
  end

  -- Translation context — sliding window (2 prev + 1 next substantive) for continuity
  local cur_tc = config.get_dubbing_translate_context_enabled()
  local rv_tc, new_tc = reaper.ImGui_Checkbox(ctx,
    'Sliding context window for translation (2 previous + 1 next, skipping interjections)', cur_tc)
  if rv_tc then config.set_dubbing_translate_context_enabled(new_tc) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'ON (default): each segment translation includes 2 previous substantive\n'
        .. 'segments (source + translation) + 1 upcoming substantive segment\n'
        .. '(source only) as context. Short interjections ("Yeah", "OK", "Tak",\n'
        .. '"no") under 4 words are SKIPPED — they do not ground continuation\n'
        .. 'and would waste the context window with noise.\n\n'
        .. 'Greatly improves continuity for cut-sentence segments, pronoun\n'
        .. 'resolution, register / tone preservation (you/Pan choice, etc).\n\n'
        .. 'Cost: ~3-4× input tokens per segment. Anthropic prompt caching still\n'
        .. 'covers the static system prompt (~90% of cost preserved).\n\n'
        .. 'Sequencing: segment N waits for substantive prev to be translated\n'
        .. 'before spawning (best-effort). Short ones do not gate concurrency.\n\n'
        .. 'OFF: each segment translated independently (legacy behaviour). Faster\n'
        .. 'but produces "stranded" translations for cut sentences (e.g., when\n'
        .. 'speaker ends a thought mid-segment that continues in next).')
  end

  -- M2.6: Anthropic prompt caching toggle (90% off cached system prompt, 5min TTL)
  local cur_pc = config.get_dubbing_anthropic_prompt_caching()
  local rv_pc, new_pc = reaper.ImGui_Checkbox(ctx,
    'Anthropic prompt caching (90% off after first request)', cur_pc)
  if rv_pc then config.set_dubbing_anthropic_prompt_caching(new_pc) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'ON (default): System prompt + tools schema marked cache_control=ephemeral.\n'
        .. 'Anthropic caches for 5min — subsequent translations 90% cheaper on input tokens.\n'
        .. 'Requires min 2048 tokens for Sonnet (per Anthropic spec).\n'
        .. 'OFF: Each request pays full price (cache_control omitted).\n\n'
        .. 'Cache hits do not count toward ITPM rate limit — you can fire faster batches.\n'
        .. 'Affects Anthropic provider ONLY; other providers unchanged.')
  end

  -- M2.5: Cost tier alert threshold (USD)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Cost alert threshold:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_Text(ctx, '$')
  reaper.ImGui_SameLine(ctx, 0, 0)
  -- Width 140: '%.2f' (e.g., "20.00") + step buttons. 80px było za mało.
  reaper.ImGui_SetNextItemWidth(ctx, 140)
  local cur_thr = config.get_dubbing_cost_alert_threshold_usd()
  local rv_thr, new_thr = reaper.ImGui_InputDouble(ctx, '##dub_cost_threshold',
    cur_thr, 1.0, 10.0, '%.2f')
  if rv_thr then config.set_dubbing_cost_alert_threshold_usd(new_thr) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'When estimated cost for a pending Generate-dub run exceeds this threshold,\n'
        .. 'Reasonate shows a confirm dialog before sending requests.\n\n'
        .. 'Default $20 (close to Creator tier $22/month soft limit).\n'
        .. 'Set 0 to disable alerts. Set higher for less interruption when you\'re\n'
        .. 'on Pro/Scale tier with a higher budget.')
  end
end

----------------------------------------------------------------------------
-- Render
----------------------------------------------------------------------------
function M.render(ctx, state)
  -- M2-2: poll async Test/Save&fetch PRZED early-return — wynik requestu
  -- in-flight aplikuje się nawet gdy user zamknął popup w międzyczasie.
  poll_handles(state)

  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    s.pending_open = false
  end

  -- Default size 760 × 720 — AI tab ma najwięcej treści (4 LLM providers
  -- z keys + per-feature overrides; od 2026-06-11) — auto-height (0) dawało
  -- za mały popup użytkownikom (PM8 feedback). Cond_Appearing = każdy open
  -- używa default size (resize w trakcie sesji preserved przez ImGui, ale
  -- nowy open resetuje — predictable UX). NIE używamy AlwaysAutoResize —
  -- w połączeniu z TextWrapped tworzy feedback loop.
  theme.center_next_modal(ctx, 760, 720)
  theme.popup_keep_top(ctx, POPUP_ID)

  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end

  -- NS-2d: 4 zakładki zamiast flat sections. ReaImGui BeginTabBar/BeginTabItem
  -- auto-end on false-return — wywołujemy End* TYLKO gdy Begin* zwróciło true.
  if reaper.ImGui_BeginTabBar(ctx, 'settings_tabs') then
    if reaper.ImGui_BeginTabItem(ctx, 'General') then
      reaper.ImGui_Spacing(ctx)
      render_general_tab(ctx, state)
      reaper.ImGui_EndTabItem(ctx)
    end
    if reaper.ImGui_BeginTabItem(ctx, 'AI') then
      reaper.ImGui_Spacing(ctx)
      render_ai_tab(ctx)
      reaper.ImGui_EndTabItem(ctx)
    end
    if reaper.ImGui_BeginTabItem(ctx, 'TTS') then
      reaper.ImGui_Spacing(ctx)
      render_tts_tab(ctx, state)
      reaper.ImGui_EndTabItem(ctx)
    end
    if reaper.ImGui_BeginTabItem(ctx, 'Voice Replacement') then
      reaper.ImGui_Spacing(ctx)
      render_voice_replacement_tab(ctx, state)
      reaper.ImGui_EndTabItem(ctx)
    end
    if reaper.ImGui_BeginTabItem(ctx, 'Repair') then
      reaper.ImGui_Spacing(ctx)
      render_repair_tab(ctx)
      reaper.ImGui_EndTabItem(ctx)
    end
    if reaper.ImGui_BeginTabItem(ctx, 'Dubbing') then
      reaper.ImGui_Spacing(ctx)
      render_dubbing_tab(ctx, state)
      reaper.ImGui_EndTabItem(ctx)
    end
    reaper.ImGui_EndTabBar(ctx)
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)
  if theme.button_neutral(ctx, 'Close') then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  -- Title bar X click sets p_open=false → close popup.
  if not p_open then reaper.ImGui_CloseCurrentPopup(ctx) end

  reaper.ImGui_EndPopup(ctx)
end

return M
