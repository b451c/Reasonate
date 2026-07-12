-- modules/gui/audition_strip.lua
-- Dedicated audition band: ▶ Original · ▶ AI · take cycle · selection hint.
-- Stała wysokość (renderuje hint gdy nic nie zaznaczone — bez window jump).
--
-- Logika resolve_pair / take helpers — przeniesione 1:1 z poprzedniego
-- audition_panel.lua. Tylko styling i layout się zmienia.

local helpers  = require 'modules.reaper_helpers'
local preview  = require 'modules.preview'
local theme    = require 'modules.theme'
local ar       = require 'modules.audio_render'
local isolator = require 'modules.voice_isolator'
local util     = require 'modules.util'

local M = {}

-- NS-C: standalone Voice Isolator state. Per-instance (single audition strip
-- per UI), więc module-level singleton wystarczy.
local clean = {
  handle             = nil,    -- voice_isolator handle gdy running
  for_item_guid      = nil,    -- item dla którego cleaning leci
  last_status_text   = nil,    -- transient message: "Done · new take added" / "Error: …"
  last_status_color  = nil,    -- theme color for status text
  last_status_until  = 0,      -- util.now() timestamp do schowania msg
}

local STATUS_FADE_SECS = 4

local function set_clean_status(text, color)
  clean.last_status_text  = text
  clean.last_status_color = color
  clean.last_status_until = util.now() + STATUS_FADE_SECS
end

----------------------------------------------------------------------------
-- Add cleaned audio jako nowy take na source itemie (multi-take, non-destructive).
-- Per niezmiennik #2 source plik nigdy tknięty — cleaned mp3 to osobny plik.
----------------------------------------------------------------------------
local function add_cleaned_take(item, cleaned_path)
  if not item or not cleaned_path then return false, 'missing args' end
  reaper.Undo_BeginBlock()
  local take = reaper.AddTakeToMediaItem(item)
  if not take then
    reaper.Undo_EndBlock('Reasonate: Voice Isolator (failed)', -1)
    return false, 'AddTakeToMediaItem returned nil'
  end
  local src = reaper.PCM_Source_CreateFromFile(cleaned_path)
  if not src then
    reaper.Undo_EndBlock('Reasonate: Voice Isolator (failed)', -1)
    return false, 'PCM_Source_CreateFromFile returned nil'
  end
  reaper.SetMediaItemTake_Source(take, src)
  reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', 'Cleaned (Voice Isolator)', true)
  reaper.SetActiveTake(take)
  reaper.UpdateItemInProject(item)
  reaper.Undo_EndBlock('Reasonate: Voice Isolator cleanup', -1)
  return true, nil
end

----------------------------------------------------------------------------
-- Helpers (same as old audition_panel)
----------------------------------------------------------------------------
local function resolve_pair(item)
  if not item then return nil, nil, 'none' end
  local _, is_output = reaper.GetSetMediaItemInfo_String(
    item, 'P_EXT:Reasonate.is_output', '', false)
  if is_output == '1' then
    local _, src_guid = reaper.GetSetMediaItemInfo_String(
      item, 'P_EXT:Reasonate.source_item_guid', '', false)
    local source_item = src_guid ~= '' and helpers.find_item_by_guid(src_guid) or nil
    return source_item, item, 'output'
  end
  local _, out_guid = reaper.GetSetMediaItemInfo_String(
    item, 'P_EXT:Reasonate.output_item_guid', '', false)
  local output_item = out_guid ~= '' and helpers.find_item_by_guid(out_guid) or nil
  return item, output_item, 'source'
end

local function take_source_path(take)
  if not take then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  return reaper.GetMediaSourceFileName(src, '')
end

----------------------------------------------------------------------------
-- audition_path(item) — ścieżka pliku do odtworzenia gdy user klika
-- ▶ Original. Dla:
--   - simple item (== full source) → direct source path
--   - trimmed/playrate (renderable, no FX) → AudioAccessor visible-region WAV
--     (cache hit z Convert/Variants jeśli już rendered, inaczej ~1-2s render)
--   - FX item → fallback na direct source (legacy "dry source" behavior;
--     CF_Preview tak czy siak nie aplikuje FX, więc trim w tej sytuacji
--     ignorujemy — user dostaje surowy plik)
----------------------------------------------------------------------------
local function audition_path(item)
  if not item then return nil end
  local path = ar.prepare_audio_for_api(item)
  if path then return path end
  -- Fallback dla nieobsłużonych przypadków (FX, etc.) — legacy behavior
  return take_source_path(reaper.GetActiveTake(item))
end

local function active_take_index(item)
  local take = reaper.GetActiveTake(item)
  if not take then return 0 end
  return math.floor(reaper.GetMediaItemTakeInfo_Value(take, 'IP_TAKENUMBER'))
end

local function set_active_take_idx(item, idx)
  local n = reaper.CountTakes(item)
  if n == 0 then return end
  idx = idx % n
  if idx < 0 then idx = idx + n end
  local take = reaper.GetMediaItemTake(item, idx)
  if take then
    reaper.SetActiveTake(take)
    reaper.UpdateItemInProject(item)
  end
end

----------------------------------------------------------------------------
-- Render
----------------------------------------------------------------------------
function M.render(ctx, opts)
  opts = opts or {}
  local result = { repair_clicked = false, repair_item = nil, repair_label = nil }

  -- NS-C: poll active isolate handle (no-op gdy clean.handle nil).
  if clean.handle then
    isolator.poll(clean.handle)
    if clean.handle.status == 'done' then
      local item = clean.for_item_guid and helpers.find_item_by_guid(clean.for_item_guid)
      if item then
        local ok, err = add_cleaned_take(item, clean.handle.result)
        if ok then
          set_clean_status(('Done · cleaned take added (%.1fs)'):format(clean.handle.elapsed or 0),
            theme.COLORS.status_done)
        else
          set_clean_status('Failed to add take: ' .. tostring(err), theme.COLORS.status_error)
        end
      else
        set_clean_status('Item disappeared during cleaning', theme.COLORS.status_error)
      end
      clean.handle        = nil
      clean.for_item_guid = nil
    elseif clean.handle.status == 'error' then
      set_clean_status('Failed: ' .. tostring(clean.handle.error), theme.COLORS.status_error)
      clean.handle        = nil
      clean.for_item_guid = nil
    end
  end

  -- Caption "AUDITION" jako section label
  theme.push_caption(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextDisabled(ctx, 'AUDITION')
  theme.pop_caption(ctx)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)

  local n_sel = reaper.CountSelectedMediaItems(0)
  if n_sel ~= 1 then
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_TextDisabled(ctx, 'Select 1 item in timeline to listen')
    return result
  end

  local sel_item = reaper.GetSelectedMediaItem(0, 0)
  local source_item, output_item, role = resolve_pair(sel_item)

  -- Original — anchored zaraz po "AUDITION" label żeby buttony nigdy się nie
  -- przesuwały (długie role / role hint nie mogą popychać play buttonów).
  reaper.ImGui_BeginDisabled(ctx, source_item == nil)
  local src_id = source_item and ('src_' .. helpers.item_guid(source_item)) or 'src_none'
  local src_playing = preview.is_playing(src_id)
  if theme.button_neutral(ctx, src_playing and 'Stop##audi_src' or '▶ Original##audi_src', 0, 0) then
    if src_playing then
      preview.stop()
    elseif source_item then
      local path = audition_path(source_item)
      if path and path ~= '' then preview.play_file(path, src_id) end
    end
  end
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)

  -- AI (primary — accentowany)
  reaper.ImGui_BeginDisabled(ctx, output_item == nil)
  local ai_id = output_item and ('ai_' .. helpers.item_guid(output_item)) or 'ai_none'
  local ai_playing = preview.is_playing(ai_id)
  if theme.button_primary(ctx, ai_playing and 'Stop##audi_ai' or '▶ AI##audi_ai', 0, 0) then
    if ai_playing then
      preview.stop()
    elseif output_item then
      local path = take_source_path(reaper.GetActiveTake(output_item))
      if path and path ~= '' then preview.play_file(path, ai_id) end
    end
  end
  reaper.ImGui_EndDisabled(ctx)

  -- Take cycle (multi-take only)
  if output_item then
    local n_takes = reaper.CountTakes(output_item)
    if n_takes > 1 then
      local idx = active_take_index(output_item)

      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
      if theme.button_ghost(ctx, '◀##take_prev', 28, 0) then
        set_active_take_idx(output_item, idx - 1)
        if ai_playing then
          local path = take_source_path(reaper.GetActiveTake(output_item))
          if path and path ~= '' then preview.play_file(path, ai_id) end
        end
      end
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_TextColored(ctx, theme.COLORS.status_output,
        ('Take %d/%d'):format(idx + 1, n_takes))
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
      if theme.button_ghost(ctx, '▶##take_next', 28, 0) then
        set_active_take_idx(output_item, idx + 1)
        if ai_playing then
          local path = take_source_path(reaper.GetActiveTake(output_item))
          if path and path ~= '' then preview.play_file(path, ai_id) end
        end
      end

      local active_take = reaper.GetActiveTake(output_item)
      if active_take then
        local _, take_name = reaper.GetSetMediaItemTakeInfo_String(active_take, 'P_NAME', '', false)
        if take_name ~= '' then
          reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
          reaper.ImGui_AlignTextToFramePadding(ctx)
          theme.push_caption(ctx)
          reaper.ImGui_TextDisabled(ctx, take_name)
          theme.pop_caption(ctx)
        end
      end
    end
  end

  -- NS-C: standalone "Clean voice" button. Acts na source_item (nie na AI
  -- output). Dodaje nowy take z cleaned audio do wybranego itema.
  if source_item then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
    local is_running = clean.handle ~= nil
    reaper.ImGui_BeginDisabled(ctx, is_running)
    if is_running then
      local SPIN = { '|', '/', '-', '\\' }
      local idx = math.floor(util.now() * 8) % #SPIN + 1
      local elapsed = util.now() - (clean.handle.started_at or util.now())
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_pending)
      if theme.button_ghost(ctx, ('%s Cleaning… %.1fs##clean_voice'):format(SPIN[idx], elapsed), 0, 0) then
        -- nic — disabled
      end
      reaper.ImGui_PopStyleColor(ctx, 1)
    else
      if theme.button_ghost(ctx, 'Clean voice##clean_voice', 0, 0) then
        local path = ar.prepare_audio_for_api(source_item)
        if path then
          local item_len = reaper.GetMediaItemInfo_Value(source_item, 'D_LENGTH') or 0
          clean.handle = isolator.spawn_isolate(path, { duration_secs = item_len })
          if clean.handle.status == 'error' then
            set_clean_status('Failed: ' .. tostring(clean.handle.error), theme.COLORS.status_error)
            clean.handle = nil
          elseif clean.handle.status == 'skipped' then
            -- NS-C: item < MIN_DURATION_SECS — API would reject. Pre-flight.
            set_clean_status(
              ('Item too short for Voice Isolator (min %.1fs)'):format(
                clean.handle.min_required or 4.6),
              theme.COLORS.status_error)
            clean.handle = nil
          elseif clean.handle.status == 'done' then
            -- Cache hit — instant. Apply this frame.
            local ok, err = add_cleaned_take(source_item, clean.handle.result)
            if ok then
              set_clean_status('Done · cleaned take added (cache hit)', theme.COLORS.status_done)
            else
              set_clean_status('Failed to add take: ' .. tostring(err), theme.COLORS.status_error)
            end
            clean.handle = nil
          else
            clean.for_item_guid = helpers.item_guid(source_item)
          end
        else
          set_clean_status('Cannot prepare audio (FX item? unsupported format?)',
            theme.COLORS.status_error)
        end
      end
    end
    reaper.ImGui_EndDisabled(ctx)
    if reaper.ImGui_IsItemHovered(ctx) and not is_running then
      reaper.ImGui_SetTooltip(ctx,
        'Voice Isolator: remove noise / reverb · result added as new take on the item')
    end
  end

  -- NS-C: transient status message (success/error fades after ~4s)
  if clean.last_status_text and util.now() < clean.last_status_until then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_TextColored(ctx, clean.last_status_color or theme.COLORS.status_pending,
      clean.last_status_text)
  end

  -- Role + relation hint inline po buttonach. Bliżej Original/AI niż
  -- right-align, no truncation (ImGui flow handle long text bez ucinania).
  -- Buttony są stale-anchored po lewej — długie role nie pchają ich.
  local role_text = nil
  if sel_item then
    local track = reaper.GetMediaItemTrack(sel_item)
    if track then
      role_text = helpers.get_track_role(track)
      if not role_text or role_text == '' then
        role_text = helpers.track_name(track)
      end
      if not role_text or role_text == '' then role_text = '(unnamed)' end
    end
  end
  local rel_hint
  if role == 'source' then
    rel_hint = output_item and 'source · linked AI ●' or 'source · no AI yet'
  elseif role == 'output' then
    rel_hint = 'AI output'
  else
    rel_hint = 'unrelated item'
  end
  local hint = role_text
    and ('Role: ' .. role_text .. '  ·  ' .. rel_hint)
    or  rel_hint
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  theme.push_caption(ctx)
  reaper.ImGui_TextDisabled(ctx, hint)
  theme.pop_caption(ctx)

  return result
end

return M
