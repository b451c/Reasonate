-- modules/voice_clone.lua
-- Phase 11 (Dialog Repair) — voice clone management.
--
-- Smart hybrid voice resolution per user decision (2026-05-08):
--   1. Track has voice_id (z casting / manual pick) → use it (no IVC needed)
--   2. Track has voice_clone_id (previously auto-cloned) → reuse it
--   3. Track has voice_clone_fallback_id (user picked library voice po
--      kiepskim klonie) → use it
--   4. Else → 'needs_clone_confirm' (UI shows hybrid confirm dialog)
--
-- IVC endpoint: POST /v1/voices/add (multipart). Free na każdym planie.
-- Polski supported (32+ languages na ElevenLabs IVC).
--
-- Sample audio strategy (first cut): używamy bezpośrednio source file
-- pierwszego simple item'a na tracku. ElevenLabs IVC przyjmuje większe
-- pliki (do 11MB / kilka minut) — sample full source. Phase 11.x może
-- dodać explicit 30-60s slice render dla quality control.

local api     = require 'modules.api'
local cfg     = require 'modules.config'
local helpers = require 'modules.reaper_helpers'
local ar      = require 'modules.audio_render'
local concat  = require 'modules.audio_concat'      -- NS-G: speaker-aware regions concat

local M = {}

----------------------------------------------------------------------------
-- M.resolve_voice_for_track(track) → { voice_id, source, name? }
--   source ∈ {'track_voice', 'voice_clone', 'voice_clone_fallback', 'needs_clone_confirm'}
----------------------------------------------------------------------------
function M.resolve_voice_for_track(track)
  if not track then return { voice_id = nil, source = 'no_track' } end

  local id, name = helpers.get_track_voice(track)
  if id and id ~= '' then
    return { voice_id = id, source = 'track_voice', name = name }
  end

  local clone = helpers.get_track_voice_clone(track)
  if clone and clone.voice_id and clone.voice_id ~= '' then
    return {
      voice_id    = clone.voice_id,
      source      = 'voice_clone',
      created_at  = clone.created_at,
      source_path = clone.source_path,
    }
  end

  local fb = helpers.get_track_voice_clone_fallback(track)
  if fb and fb.voice_id and fb.voice_id ~= '' then
    return { voice_id = fb.voice_id, source = 'voice_clone_fallback', name = fb.name }
  end

  return { voice_id = nil, source = 'needs_clone_confirm' }
end

----------------------------------------------------------------------------
-- Sample audio path for IVC.
--
-- Behaviour:
--   1. opts.regions + opts.source_item provided (NS-G — speaker-aware path)
--      → audio_concat.concat_regions renders selected source-time regions
--      do single mono 44.1kHz WAV. Used dla multi-speaker sources (podcast,
--      wywiad) gdzie user manually picks ONE speaker + zaznacza regions w
--      speaker_picker modal.
--   2. Brak opts.regions (legacy / single-speaker path) → pierwszy usable
--      audio item na tracku (full visible region via prepare_audio_for_api).
--
-- Returns: path or nil, error_msg or nil
----------------------------------------------------------------------------
function M.find_sample_audio_for_track(track, opts)
  opts = opts or {}

  -- NS-G path: explicit regions + source item from speaker_picker modal
  if opts.regions and #opts.regions > 0 and opts.source_item then
    local path, err = concat.concat_regions(opts.source_item, opts.regions, {})
    if not path then
      return nil, 'concat regions failed: ' .. tostring(err)
    end
    return path, nil
  end

  -- Legacy path: first usable item on track
  if not track then return nil, 'nil track' end
  local n = reaper.CountTrackMediaItems(track)
  if n == 0 then return nil, 'track has no items' end

  local first_err
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    -- M5-7: cap próbki do 240 s (audio_concat.MAX_DURATION_SECS) — IVC nie
    -- potrzebuje więcej, a upload całego długiego itemu bywa wolny/odrzucany.
    -- concat_regions odrzuca playrate≠1 → fallback niżej do pełnego rendera.
    local take = reaper.GetActiveTake(item)
    local len  = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') or 0
    if take and len > concat.MAX_DURATION_SECS then
      local offs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
      local capped = concat.concat_regions(item, {
        { start = offs, ['end'] = offs + concat.MAX_DURATION_SECS } }, {})
      if capped then return capped, nil end
    end
    local path, err = ar.prepare_audio_for_api(item)
    if path then
      return path, nil
    end
    if not first_err then first_err = err end
  end
  return nil, 'no usable audio item on track (' .. tostring(first_err) .. ')'
end

-- create_ivc / rename_voice / delete_clone / ensure_clone_for_track
-- USUNIETE M7 (2026-07-11, user OK) - sync legacy bez callerow od Big
-- Session #3 (async voice_admin.spawn_train/rename/delete + M4-3 pompa
-- kasowania klonow pokrywaja wszystko). Git history zachowuje.


return M
