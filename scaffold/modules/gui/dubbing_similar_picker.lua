-- modules/gui/dubbing_similar_picker.lua
-- NS-B M3.2: Results modal dla /v1/similar-voices.
--
-- Po request_similar_for_speaker → modal pokazuje top-N candidates (typowo
-- 10) z imieniem / labels / preview button / Select button.
-- Single-select; Cancel zostawia speaker bez voice (status unchanged).
--
-- Reuses modules.preview dla audio playback z voice.preview_url (deterministic
-- via voice_id key — można porównać kilka voices przed wyborem).

local theme   = require 'modules.theme'
local preview = require 'modules.preview'
local config  = require 'modules.config'

local M = {}

local POPUP_ID = 'Similar voices'

local s = {
  pending_open  = false,
  speaker_id    = nil,
  speaker_label = nil,
  voices        = nil,    -- array {voice_id, name, labels, preview_url, category, description}
  total_count   = 0,
  has_more      = false,
  current_top_k = 10,
  load_more_request = false,   -- M4.3: signal dla caller to spawn next batch
  selected      = nil,    -- {voice_id, name} after click
}

function M.open(opts)
  s.pending_open  = true
  s.speaker_id    = opts.speaker_id
  s.speaker_label = opts.speaker_label or opts.speaker_id
  s.voices        = opts.voices or {}
  s.total_count   = opts.total_count or #(opts.voices or {})
  s.has_more      = opts.has_more == true
  s.current_top_k = opts.top_k or 10
  s.load_more_request = false
  s.selected      = nil
end

-- M4.3: caller calls after spawn_similar_voices returns more results;
-- merges into existing voices list (deduped by voice_id).
function M.append_voices(more_voices, more_has_more, more_total_count, new_top_k)
  if type(more_voices) ~= 'table' then return end
  local seen = {}
  for _, v in ipairs(s.voices or {}) do seen[v.voice_id] = true end
  for _, v in ipairs(more_voices) do
    if v.voice_id and not seen[v.voice_id] then
      s.voices[#s.voices + 1] = v
      seen[v.voice_id] = true
    end
  end
  if more_has_more ~= nil then s.has_more = more_has_more end
  if more_total_count ~= nil and more_total_count > s.total_count then s.total_count = more_total_count end
  if new_top_k then s.current_top_k = new_top_k end
  s.load_more_request = false
end

-- M4.3: poll dla caller — after Load more clicked, drain & return next-k
function M.consume_load_more_request()
  if not s.load_more_request then return nil end
  s.load_more_request = false
  return s.current_top_k + 10
end

function M.is_open() return s.voices ~= nil end

-- Returns action: 'select' z s.selected, 'cancel', or nil (still open)
function M.render(ctx)
  if not s.voices then return nil end
  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    s.pending_open = false
  end

  theme.center_next_modal(ctx, 820, 680)
  theme.popup_keep_top(ctx, POPUP_ID)
  local visible = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return nil end

  local action = nil

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx, ('Similar to sample for: %s. Showing %d of %d candidate(s).'):format(
    s.speaker_label or '?', #s.voices, s.total_count))
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Scrollable list
  if reaper.ImGui_BeginChild(ctx, '##sim_list', -1, -56, 0, 0) then
    for i, v in ipairs(s.voices) do
      reaper.ImGui_PushID(ctx, 'sim_' .. i)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, ('%d. %s'):format(i, v.name or '(unnamed)'))

      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
      local labels = v.labels or {}
      local meta = {}
      if labels.gender   and labels.gender   ~= '' then meta[#meta + 1] = labels.gender end
      if labels.accent   and labels.accent   ~= '' then meta[#meta + 1] = labels.accent end
      if v.category      and v.category      ~= '' then meta[#meta + 1] = v.category end
      if #meta > 0 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
        reaper.ImGui_Text(ctx, '[' .. table.concat(meta, ' / ') .. ']')
        reaper.ImGui_PopStyleColor(ctx, 1)
      end

      -- PM9 iter2: buttons na NOWEJ linii (right-align z absolute offset nie
      -- działało reliable — buttons były obcięte poza ramką gdy meta było
      -- krótkie lub child miał scrollbar). New-line layout zawsze fits.
      reaper.ImGui_Dummy(ctx, 1, 2)
      reaper.ImGui_Indent(ctx, 16)

      local is_fav = config.is_favorite(v.voice_id)
      if reaper.ImGui_SmallButton(ctx, is_fav and '* Fav' or 'o Fav') then
        config.toggle_favorite(v.voice_id)
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
          is_fav and 'Remove from favorites'
                 or  'Add to favorites (filter w Voice Picker)')
      end
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)

      local playing = v.preview_url and preview.is_playing(v.voice_id) or false
      if playing then
        if reaper.ImGui_SmallButton(ctx, 'Stop') then preview.stop() end
      else
        reaper.ImGui_BeginDisabled(ctx, not v.preview_url or v.preview_url == '')
        if reaper.ImGui_SmallButton(ctx, '> Preview') then
          if v.preview_url and v.preview_url ~= '' then
            preview.play_url(v.preview_url, v.voice_id)
          end
        end
        reaper.ImGui_EndDisabled(ctx)
      end
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
      if theme.button_primary(ctx, 'Select') then
        s.selected = { voice_id = v.voice_id, name = v.name or '(unnamed)' }
        preview.stop()
        action = 'select'
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_Unindent(ctx, 16)

      if v.description and v.description ~= '' then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
        reaper.ImGui_TextWrapped(ctx, v.description)
        reaper.ImGui_PopStyleColor(ctx, 1)
      end
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PopID(ctx)
    end
    reaper.ImGui_EndChild(ctx)
  end

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)
  if s.has_more then
    if theme.button_neutral(ctx, 'Load more') then
      s.load_more_request = true
      action = 'load_more'
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Fetch next 10 similar candidates from ElevenLabs (pagination).')
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  end
  if theme.button_neutral(ctx, 'Cancel') then
    preview.stop()
    action = 'cancel'
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)

  if action == 'select' or action == 'cancel' then
    s.voices = nil   -- closes for is_open() check
  end
  return action
end

function M.get_selection() return s.selected end
function M.get_speaker_id() return s.speaker_id end

return M
