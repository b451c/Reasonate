-- modules/modes/voice_replacement.lua
--
-- NS-A: Voice Replacement mode — S2S voice conversion + Phase 11 Dialog Repair.
-- Extracted z reasonate.lua w sesji 2a (NS-A impl).
--
-- Module shape (per modes contract):
--   M.NAME, M.LABEL, M.DESCRIPTION — metadata
--   M.render(ctx, state, deps)        — main panel render (called inside Begin/End)
--   M.render_modals(ctx, state, deps) — mode-specific modale (called outside Begin/End)
--   M.consume_signals(state, deps)    — post-frame signal consumption (called z loop)
--   M.shutdown()                      — atexit cleanup hook
--
-- deps fields:
--   action_msg_setter(msg, color) — callback do set footer status
--   has_api_key (bool)
--   mod_label   ('Cmd'|'Ctrl')
--   main_geom   ({cx, cy})  — dla batch_dialog centering

local config       = require 'modules.config'
local helpers      = require 'modules.reaper_helpers'
local util         = require 'modules.util'
local audio_render = require 'modules.audio_render'
local job_manager  = require 'modules.job_manager'
local cache        = require 'modules.cache'
local theme        = require 'modules.theme'

local tracks_table          = require 'modules.gui.tracks_table'
local stats_strip           = require 'modules.gui.stats_strip'
local audition_strip        = require 'modules.gui.audition_strip'
local action_band           = require 'modules.gui.action_band'
local batch_dialog          = require 'modules.gui.batch_dialog'
local voice_settings_dialog = require 'modules.gui.voice_settings_dialog'
local variants_dialog       = require 'modules.gui.variants_dialog'
local cast_manager          = require 'modules.gui.cast_manager'
-- NS-F: transcript_editor (Phase 11 modal Repair) removed. Repair workflow
-- przeniesiony do dedicated mode 'repair' (modes/repair.lua).
local track_color_popup     = require 'modules.gui.track_color_popup'
local settings_dialog       = require 'modules.gui.settings_dialog'
local recording             = require 'modules.recording'

local M = {}
M.NAME        = 'voice_replacement'
M.LABEL       = 'Voice Replacement'
M.DESCRIPTION = 'Voice swap in existing recordings'

local COL_OK   = theme.COLORS.status_done
local COL_ERR  = theme.COLORS.status_error
local COL_INFO = theme.COLORS.text_dim

----------------------------------------------------------------------------
-- Convert: walidacja każdego selectowanego → confirm dialog
-- (extracted z reasonate.lua linie 173-290)
----------------------------------------------------------------------------
local function action_convert_selected_click(deps)
  local set_action = deps.action_msg_setter

  if not config.has_api_key() then
    set_action('Set API key first (Settings…)', COL_ERR)
    settings_dialog.open()
    return
  end

  local n_sel = reaper.CountSelectedMediaItems(0)
  if n_sel == 0 then
    set_action('Select at least 1 item', COL_ERR)
    return
  end

  local specs        = {}
  local first_err    = nil
  local skipped_done = 0
  local cache_hits   = 0

  for i = 0, n_sel - 1 do
    local item  = reaper.GetSelectedMediaItem(0, i)
    local track = reaper.GetMediaItemTrack(item)
    local voice_id, voice_name = helpers.get_track_voice(track)

    if not voice_id then
      if not first_err then first_err = ('Item %d: track has no voice'):format(i + 1) end
    elseif voice_id:match('^fake%-') then
      if not first_err then first_err = ('Item %d: placeholder voice (Refresh voices)'):format(i + 1) end
    else
      -- Phase 7: too_long check PRZED prepare_audio_for_api — długi trimmed
      -- item nie renderuje się w całości na darmo (kawałki renderują osobno).
      local too_long, item_len = audio_render.item_too_long(item)
      local settings = helpers.effective_voice_settings(track)
      local needs, _reason = helpers.needs_conversion(item, voice_id, settings)
      if not needs then
        skipped_done = skipped_done + 1
      elseif too_long then
        -- ===== Phase 7: chunked path (N specs, jeden per kawałek) =====
        local chunks, cerr = audio_render.plan_sts_chunks(item)
        if not chunks then
          if not first_err then first_err = ('Item %d: %s'):format(i + 1, cerr) end
        else
          local plan_hash = audio_render.chunk_plan_hash(chunks)
          local info = helpers.item_source_info(item)
          local source_path   = info and info.path   or ''
          local source_size   = info and info.size   or 0
          local source_length = info and info.length or item_len
          -- Jeden seed dla wszystkich kawałków (spójna konwersja głosu);
          -- klucze cache i tak różne per chunk przez render_info.item_offs.
          local seed = util.simple_hash(helpers.item_guid(item) .. '|' .. voice_id) % 4294967295
          local take = reaper.GetActiveTake(item)
          local _, take_name  = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
          local _, track_name = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
          local base_label = ('%s @ %s'):format(
            take_name  ~= '' and take_name  or '(unnamed)',
            track_name ~= '' and track_name or '(track)')
          for ci, ch in ipairs(chunks) do
            local input_path, rerr, render_info = audio_render.prepare_chunk_for_api(item, ch)
            if not input_path then
              if not first_err then first_err = ('Item %d: %s'):format(i + 1, rerr) end
              break
            end
            local cache_key = cache.compute_key({
              source_path   = source_path,
              source_size   = source_size,
              source_length = source_length,
              voice_id      = voice_id,
              model_id      = config.get_model_id(),
              seed          = seed,
              settings      = settings,
              output_format = config.get_output_format(),
              item_offs     = render_info.item_offs,
              item_length   = render_info.item_length,
              playrate      = render_info.playrate,
            })
            local is_cache_hit = cache.exists(cache_key)
            if is_cache_hit then cache_hits = cache_hits + 1 end
            specs[#specs + 1] = {
              source_item_guid = helpers.item_guid(item),
              voice_id         = voice_id,
              voice_name       = voice_name,
              audio_seconds    = ch.duration,
              input_path       = input_path,
              source_path      = source_path,
              source_size      = source_size,
              source_length    = source_length,
              settings         = settings,
              cache_hit        = is_cache_hit,
              render_info      = render_info,
              multi_take       = true,
              chunk            = { index = ci, count = #chunks,
                                   offset_secs = ch.offset_secs,
                                   plan_hash = plan_hash },
              item_label       = ('%s (part %d/%d)'):format(base_label, ci, #chunks),
            }
          end
        end
      else
        local input_path, err, render_info = audio_render.prepare_audio_for_api(item)
        if not input_path then
          if not first_err then first_err = ('Item %d: %s'):format(i + 1, err) end
        else
          -- Cache key zawsze referencjuje ORIGINAL source identity (path/size/len)
          -- + opcjonalnie item geometry (offs/length/playrate) gdy rendered.
          -- Trimmed variants tej samej source dostają distinct keys.
          local info = helpers.item_source_info(item)
          local source_path   = info and info.path   or ''
          local source_size   = info and info.size   or 0
          local source_length = info and info.length or item_len

          local seed = util.simple_hash(helpers.item_guid(item) .. '|' .. voice_id) % 4294967295
          local cache_key = cache.compute_key({
            source_path   = source_path,
            source_size   = source_size,
            source_length = source_length,
            voice_id      = voice_id,
            model_id      = config.get_model_id(),
            seed          = seed,
            settings      = settings,
            output_format = config.get_output_format(),
            -- M6-8: bez flagi isolate estymata cache-hit w confirm kłamała
            -- dla tracków z Voice Isolatorem (klucz realny ma suffix |iso).
            isolate_audio = helpers.get_track_isolate_flag(track),
            item_offs     = render_info and render_info.item_offs,
            item_length   = render_info and render_info.item_length,
            playrate      = render_info and render_info.playrate,
          })
          local is_cache_hit = cache.exists(cache_key)
          if is_cache_hit then cache_hits = cache_hits + 1 end

          local take = reaper.GetActiveTake(item)
          local _, take_name  = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
          local _, track_name = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
          specs[#specs + 1] = {
            source_item_guid = helpers.item_guid(item),
            voice_id         = voice_id,
            voice_name       = voice_name,
            audio_seconds    = item_len,
            input_path       = input_path,
            source_path      = source_path,
            source_size      = source_size,
            source_length    = source_length,
            settings         = settings,
            cache_hit        = is_cache_hit,
            render_info      = render_info,
            multi_take       = true,
            item_label       = ('%s @ %s'):format(
              take_name  ~= '' and take_name  or '(unnamed)',
              track_name ~= '' and track_name or '(track)'),
          }
        end
      end
    end
  end

  if first_err then
    set_action(first_err, COL_ERR)
    return
  end

  if #specs == 0 then
    if skipped_done > 0 then
      set_action(('All %d selected item%s already up-to-date'):format(
        skipped_done, skipped_done == 1 and '' or 's'), COL_INFO)
    else
      set_action('Nothing to convert', COL_ERR)
    end
    return
  end

  batch_dialog.open_confirm({
    jobs         = specs,
    skipped_done = skipped_done,
    cache_hits   = cache_hits,
  })
  set_action('', COL_INFO)
end

----------------------------------------------------------------------------
-- Variants click (extracted z reasonate.lua linie 295-342)
----------------------------------------------------------------------------
local function action_variants_click(deps)
  local set_action = deps.action_msg_setter

  if not config.has_api_key() then
    set_action('Set API key first (Settings…)', COL_ERR)
    settings_dialog.open()
    return
  end
  local n_sel = reaper.CountSelectedMediaItems(0)
  if n_sel ~= 1 then
    set_action(('Variants: select exactly 1 item (%d selected)'):format(n_sel), COL_ERR)
    return
  end
  local item  = reaper.GetSelectedMediaItem(0, 0)
  local track = reaper.GetMediaItemTrack(item)
  local voice_id, voice_name = helpers.get_track_voice(track)

  if not voice_id then
    set_action('Track has no voice', COL_ERR); return
  end
  if voice_id:match('^fake%-') then
    set_action('Placeholder voice — Refresh voices first', COL_ERR); return
  end
  -- Phase 7 user decision (2026-06-11): Variants WYŁĄCZONE dla długich itemów
  -- (każdy wariant = koszt całości × liczba kawałków). Convert je obsługuje.
  local too_long, len = audio_render.item_too_long(item)
  if too_long then
    set_action('Variants are disabled for items >290s — use Convert (splits into chunks)', COL_ERR)
    return
  end
  local input_path, err, render_info = audio_render.prepare_audio_for_api(item)
  if not input_path then set_action('Cannot convert: ' .. err, COL_ERR); return end

  local info = helpers.item_source_info(item)
  local take = reaper.GetActiveTake(item)
  local _, take_name  = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
  local _, track_name = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)

  variants_dialog.open({
    source_item_guid = helpers.item_guid(item),
    voice_id         = voice_id,
    voice_name       = voice_name,
    audio_seconds    = len,
    input_path       = input_path,
    source_path      = info and info.path or '',
    source_size      = info and info.size or 0,
    source_length    = info and info.length or len,
    settings         = helpers.effective_voice_settings(track),
    render_info      = render_info,
    item_label       = ('%s @ %s'):format(
      take_name  ~= '' and take_name  or '(unnamed)',
      track_name ~= '' and track_name or '(track)'),
  })
  set_action('', COL_INFO)
end

----------------------------------------------------------------------------
-- Shortcuts (mode-specific: ⌘+Enter = Convert, Esc = cancel batch).
-- Globalny ⌘+, = Settings dispatchany z reasonate.lua.
----------------------------------------------------------------------------
local function process_shortcuts(ctx, deps)
  local mod_ctrl_cmd = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())

  -- Convert shortcut zablokowany gdy batch active (nie clobber'ujemy modal state'a).
  if mod_ctrl_cmd
      and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false)
      and not (job_manager.has_active() or batch_dialog.is_active()) then
    action_convert_selected_click(deps)
  end
  if job_manager.has_active()
      and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
    job_manager.cancel_all()
    deps.action_msg_setter('Batch cancelled (Esc)', COL_INFO)
  end
end

----------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------

-- Main mode panel render (called inside main window Begin/End scope).
function M.render(ctx, state, deps)
  -- 1. Stats strip
  local stats_out = stats_strip.render(ctx, state)
  if stats_out and stats_out.add_track_clicked then
    reaper.Undo_BeginBlock()
    reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
    reaper.Undo_EndBlock('Reasonate: Insert track', -1)
    reaper.TrackList_AdjustWindows(false)
    state.refresh(true)
    deps.action_msg_setter('New track added', COL_INFO)
  end
  -- Casts modal — VR-only feature (moved z global header PM8).
  if stats_out and stats_out.casts_clicked then
    cast_manager.open(state)
  end

  -- 2. Tracks table — wypełnia środek, scrollowalna.
  -- GetContentRegionAvail zwraca (w, h) jako dwa returny w Lua.
  -- ReaImGui BeginChild contract (per source): visible=true → user EndChild;
  -- visible=false → ReaImGui sam pop'uje, NIE wywoływać EndChild.
  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local TABLE_RESERVE = 150
  local child_visible = reaper.ImGui_BeginChild(ctx, 'tracks_scroll', -1,
    math.max(120, (avail_h or 0) - TABLE_RESERVE))
  local tt_out
  if child_visible then
    tt_out = tracks_table.render(ctx, state)
    reaper.ImGui_EndChild(ctx)
  end

  -- Idea 3: track index click → select track + first audio item.
  -- Sub-row click (per-item w expanded track) → select TEN konkretny item.
  -- W obu przypadkach audition_strip auto-detect'uje selection.
  if tt_out and tt_out.audition_item_guid then
    local it = helpers.find_item_by_guid(tt_out.audition_item_guid)
    if it then
      local tr = reaper.GetMediaItemTrack(it)
      reaper.SelectAllMediaItems(0, false)
      if tr then reaper.SetOnlyTrackSelected(tr) end
      reaper.SetMediaItemSelected(it, true)
      reaper.UpdateArrange()
    end
  elseif tt_out and tt_out.audition_track_guid then
    local tr = helpers.find_track_by_guid(tt_out.audition_track_guid)
    if tr then
      reaper.SelectAllMediaItems(0, false)
      reaper.SetOnlyTrackSelected(tr)
      local n = reaper.CountTrackMediaItems(tr)
      for i = 0, n - 1 do
        local it = reaper.GetTrackMediaItem(tr, i)
        if helpers.is_audio_item(it) then
          reaper.SetMediaItemSelected(it, true)
          break
        end
      end
      reaper.UpdateArrange()
    end
  end

  -- Color swatch clicks (track-level bulk OR per-item single)
  if tt_out and tt_out.color_open_track_guid then
    track_color_popup.open_for_track(tt_out.color_open_track_guid)
  elseif tt_out and tt_out.color_open_item_guid then
    track_color_popup.open_for_item(tt_out.color_open_item_guid,
      tt_out.color_open_item_track_guid)
  end
  track_color_popup.render(ctx)

  -- Recording controls
  if tt_out and tt_out.record_start_track_guid then
    local ok_rec, rec_err = recording.start(tt_out.record_start_track_guid)
    if not ok_rec then
      deps.action_msg_setter(rec_err or 'Cannot start recording', COL_ERR)
    end
  elseif tt_out and tt_out.record_stop then
    recording.stop()
  end
  recording.tick()

  -- 3. Audition strip — stała wysokość, niezależna od selekcji.
  reaper.ImGui_Separator(ctx)
  audition_strip.render(ctx, { has_api_key = deps.has_api_key })

  -- NS-F: Phase 11 Repair button removed. Use dedicated Repair mode (mode tab)
  -- dla word-level corrections. tt_out.repair_track_guid / repair_item zostają
  -- w struct dla backward compat (tracks_table return shape) but no-op tutaj.

  -- 4. Action band — zawsze widoczny. Convert/Variants disabled gdy batch active.
  reaper.ImGui_Separator(ctx)
  local act = action_band.render(ctx, {
    n_sel        = reaper.CountSelectedMediaItems(0),
    has_api_key  = deps.has_api_key,
    mod_label    = deps.mod_label,
    batch_active = job_manager.has_active() or batch_dialog.is_active(),
  })
  if act.convert_clicked  then action_convert_selected_click(deps) end
  if act.variants_clicked then action_variants_click(deps) end

  -- Mode-specific keyboard shortcuts
  process_shortcuts(ctx, deps)
end

-- Mode-specific modale render (called z reasonate.lua after Begin/End scope,
-- before theme.pop). Globalne modale (settings, voice_picker, voice_manager,
-- voice_library, cast_manager) rendered z reasonate.lua.
function M.render_modals(ctx, state, deps)
  -- batch_dialog dispatched OUTSIDE Begin/End w reasonate.lua (PM9 iter4) —
  -- non-blocking floating window (regular ImGui_Begin, NIE BeginPopupModal)
  -- wymaga top-level dispatch żeby z-order nie był nested pod main viewport.
  voice_settings_dialog.render(ctx)
  variants_dialog.render(ctx)
  -- NS-F: transcript_editor removed. Repair w dedicated mode.
end

-- Consume signals z mode-specific modali (called z main loop po frame()).
function M.consume_signals(state, deps)
  -- Confirm dialog → enqueue + transition modal w stan progress (NS-1).
  local req = batch_dialog.consume_request()
  if req and req.jobs and #req.jobs > 0 then
    job_manager.enqueue_batch(req.jobs)
    batch_dialog.transition_to_progress()
    deps.action_msg_setter(('Enqueued %d jobs (concurrency %d)'):format(
      #req.jobs, job_manager.max_concurrent), COL_INFO)
  end

  -- NS-F: Phase 11 transcript_editor consume_result removed.
  -- Repair toast handled przez modes/repair.lua M.consume_signals.

  -- Variants → enqueue N z RANDOM seedami i multi_take=true
  local var_req = variants_dialog.consume_request()
  if var_req and var_req.count and var_req.count > 0 then
    math.randomseed(os.time() + math.floor(util.now() * 1e6))
    local p = var_req.payload
    local specs = {}
    for i = 1, var_req.count do
      specs[#specs + 1] = {
        source_item_guid = p.source_item_guid,
        voice_id         = p.voice_id,
        voice_name       = p.voice_name,
        audio_seconds    = p.audio_seconds,
        input_path       = p.input_path,
        source_path      = p.source_path,
        source_size      = p.source_size,
        source_length    = p.source_length,
        settings         = p.settings,
        render_info      = p.render_info,
        seed_override    = math.random(0, 4294967295),
        multi_take       = true,
        item_label       = ('%s [variant %d/%d]'):format(p.item_label, i, var_req.count),
      }
    end
    job_manager.enqueue_batch(specs)
    batch_dialog.open_progress()
    deps.action_msg_setter(('Enqueued %d variants (random seeds, multi-take)'):format(var_req.count), COL_INFO)
  end
end

-- Atexit cleanup hook.
function M.shutdown()
  pcall(recording.shutdown)
end

return M
