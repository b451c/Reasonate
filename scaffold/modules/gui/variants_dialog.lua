-- modules/gui/variants_dialog.lua
-- Modal: "Generate variants" — pyta o N (1-10), spawnuje jobów z RANDOM
-- seedami. Wszystkie warianty trafiają jako kolejne TAKES na jednym output
-- itemie (REAPER native take cycling — Tab w take menu).
--
-- Cache: random seed = unikalny cache_key każdorazowo → zawsze realny API call.

local theme = require 'modules.theme'

local M = {}

local POPUP_ID = 'Generate variants'

local s = {
  pending_open = false,
  payload      = nil,    -- spec budowany w open()
  count        = 3,
  ready        = nil,
}

local CHARS_PER_SEC = 50
local USD_PER_1K    = 0.05

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------
function M.open(opts)
  s.pending_open = true
  s.payload = opts   -- {source_item_guid, voice_id, voice_name, audio_seconds,
                     --  input_path, source_path, source_size, source_length,
                     --  settings, item_label}
  s.count = 3
end

function M.consume_request()
  local r = s.ready
  s.ready = nil
  return r
end

function M.render(ctx)
  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    s.pending_open = false
  end

  theme.center_next_modal(ctx, 480, 0)
  theme.popup_keep_top(ctx, POPUP_ID)

  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end
  if not p_open then reaper.ImGui_CloseCurrentPopup(ctx) end

  local p = s.payload or {}

  reaper.ImGui_TextWrapped(ctx, 'Generate multiple variants with random seeds.')
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Text(ctx, ('Item:   %s'):format(p.item_label or '?'))
  reaper.ImGui_Text(ctx, ('Voice:  %s'):format(p.voice_name or '?'))
  reaper.ImGui_Text(ctx, ('Audio:  %.1fs per variant'):format(p.audio_seconds or 0))

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  reaper.ImGui_Text(ctx, 'Number of variants:')
  reaper.ImGui_SetNextItemWidth(ctx, 200)
  local rv, new_count = reaper.ImGui_SliderInt(ctx, '##count', s.count, 1, 10)
  if rv then s.count = new_count end

  reaper.ImGui_Spacing(ctx)

  local total_secs = (p.audio_seconds or 0) * s.count
  local est_chars  = math.ceil(total_secs * CHARS_PER_SEC)
  local est_usd    = est_chars * USD_PER_1K / 1000
  reaper.ImGui_Text(ctx, ('Total audio: %.1fs   Est. cost: ~%d chars (~$%.4f)')
    :format(total_secs, est_chars, est_usd))

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'Each variant = a real API call (random seed = cache miss). Results are ' ..
    'appended as takes on the output item — Tab in the take menu cycles them.')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  if theme.button_neutral(ctx, 'Cancel', 100, 0) then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_SameLine(ctx)

  if theme.button_primary(ctx, ('Generate %d'):format(s.count), 140, 0) then
    s.ready = { count = s.count, payload = s.payload }
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

return M
