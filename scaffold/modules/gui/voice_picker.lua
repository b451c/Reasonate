-- modules/gui/voice_picker.lua
-- Modal voice picker: search + filtry (gender/accent/category) + scrollable
-- lista voice'ów. Wywoływany przez tracks_table z {state, track_guid,
-- current_voice_id}; po Select wywołuje state.set_voice; po Clear voice
-- → state.clear_voice.

local preview     = require 'modules.preview'
local theme       = require 'modules.theme'
local voice_admin = require 'modules.voice_admin'
local api         = require 'modules.api'
local config      = require 'modules.config'

local M = {}

local POPUP_ID = 'Pick voice'

local s = {
  pending_open       = false,
  state              = nil,
  track_guid         = nil,
  current_voice_id   = nil,
  selected_voice_id  = nil,
  -- Optional callback mode (caller passes opts.on_pick + opts.allow_clear).
  -- on_pick(voice_id, voice_name) gets called instead of state.set_voice; for
  -- TTS mode where selection lives in state.modes.tts, not track P_EXT.
  -- nil → legacy track-mode (set_voice/clear_voice on s.track_guid).
  on_pick            = nil,
  allow_clear        = true,
  -- filter (persistent across opens)
  search             = '',
  gender             = '',
  accent             = '',
  category           = '',
  favorites_only     = false,
  -- Sync button transient feedback
  sync_handle        = nil,           -- voice_admin handle (async refresh)
  sync_msg           = '',
  sync_color         = nil,
}

-- Apply / clear helpers — route to callback if set, else default track mode.
local function apply_voice(voice_id, voice_name)
  if s.on_pick then
    s.on_pick(voice_id, voice_name)
  elseif s.state and s.track_guid then
    s.state.set_voice(s.track_guid, voice_id, voice_name)
  end
end

local function clear_voice()
  if s.on_pick then
    s.on_pick(nil, nil)
  elseif s.state and s.track_guid then
    s.state.clear_voice(s.track_guid)
  end
end

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------
-- Normalize do lowercase żeby premade voices ("male") i custom clones
-- ("Male") trafiały do tego samego bucketu filtra.
local function norm(s)
  if not s then return '' end
  return tostring(s):lower()
end

local function pretty(s)
  if s == '' then return '(any)' end
  return s:sub(1, 1):upper() .. s:sub(2)
end

local function unique_label_values(voices, field)
  local seen = {}
  local list = { '' }   -- '' = (any)
  for _, v in ipairs(voices or {}) do
    local raw
    if field == 'category' then
      raw = v.category
    else
      raw = v.labels and v.labels[field] or nil
    end
    local val = norm(raw)
    if val ~= '' and not seen[val] then
      seen[val] = true
      list[#list + 1] = val
    end
  end
  table.sort(list, function(a, b)
    if a == '' then return true end
    if b == '' then return false end
    return a < b
  end)
  return list
end

local function matches(v, search, gender, accent, category)
  if search ~= '' then
    local hay = ((v.name or '') .. ' ' .. (v.description or '')):lower()
    if not hay:find(search:lower(), 1, true) then return false end
  end
  local labels = v.labels or {}
  if gender   ~= '' and norm(labels.gender)   ~= gender   then return false end
  if accent   ~= '' and norm(labels.accent)   ~= accent   then return false end
  if category ~= '' and norm(v.category)      ~= category then return false end
  return true
end

-- ImGui balanced rule: jeśli BeginCombo zwraca true → EndCombo MUST be called
-- przed return. Zbieramy selekcję bez early-returnu, EndCombo ZAWSZE po pętli.
local function filter_combo(ctx, label, current, choices)
  reaper.ImGui_SetNextItemWidth(ctx, 130)
  local new_value = current
  local display_current = current == '' and ('(' .. label .. ')') or pretty(current)
  if reaper.ImGui_BeginCombo(ctx, '##' .. label, display_current) then
    for _, c in ipairs(choices) do
      if reaper.ImGui_Selectable(ctx, pretty(c), c == current) then
        new_value = c
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  return new_value
end

----------------------------------------------------------------------------
-- Preview wrapper — używa shared modules/preview.lua (SWS CF_Preview lub
-- fallback). Identyfikator = voice.voice_id, dzięki czemu is_playing(id)
-- pozwala pokazać Stop badge tylko na grającym voice.
----------------------------------------------------------------------------
local function action_preview(voice)
  if not voice or not voice.preview_url or voice.preview_url == '' then
    return false, 'no preview URL'
  end
  return preview.play_url(voice.preview_url, voice.voice_id)
end

local function is_playing(voice_id)
  return preview.is_playing(voice_id)
end

local function stop_preview()
  preview.stop()
end

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------
function M.open(opts)
  s.pending_open      = true
  s.state             = opts.state
  s.track_guid        = opts.track_guid
  s.current_voice_id  = opts.current_voice_id
  s.selected_voice_id = opts.current_voice_id
  s.on_pick           = opts.on_pick
  s.allow_clear       = (opts.allow_clear ~= false)  -- default true
end

function M.render(ctx)
  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    s.pending_open = false
  end

  -- Window sizing: Search + 3 filter combos + Sync button + status text muszą
  -- mieścić się w jednym rzędzie bez ucinania. 980 px przy theme padding daje
  -- margines.
  theme.center_next_modal(ctx, 980, 640)
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 860, 480, 99999, 99999)
  theme.popup_keep_top(ctx, POPUP_ID)

  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end
  if not p_open then reaper.ImGui_CloseCurrentPopup(ctx) end

  if not s.state or not s.state.voices or #s.state.voices == 0 then
    reaper.ImGui_TextWrapped(ctx,
      'No voices loaded. Open Settings → Save & fetch voices, or click Sync.')
    if reaper.ImGui_Button(ctx, 'Close') then reaper.ImGui_CloseCurrentPopup(ctx) end
    reaper.ImGui_EndPopup(ctx)
    return
  end

  -- Filter row
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Search')
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 240)
  local rv, new_search = reaper.ImGui_InputText(ctx, '##search', s.search)
  if rv then s.search = new_search end

  reaper.ImGui_SameLine(ctx)
  s.gender   = filter_combo(ctx, 'gender',   s.gender,
    unique_label_values(s.state.voices, 'gender'))
  reaper.ImGui_SameLine(ctx)
  s.accent   = filter_combo(ctx, 'accent',   s.accent,
    unique_label_values(s.state.voices, 'accent'))
  reaper.ImGui_SameLine(ctx)
  s.category = filter_combo(ctx, 'category', s.category,
    unique_label_values(s.state.voices, 'category'))

  -- Favorites filter — pokazuje tylko gwiazdkowane voices.
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  local rv_fav, new_fav = reaper.ImGui_Checkbox(ctx,
    ('★ only (%d)'):format(config.favorites_count()), s.favorites_only)
  if rv_fav then s.favorites_only = new_fav end

  -- Sync from server (async) — spawn worker, poll handle each frame.
  if s.sync_handle then
    voice_admin.poll(s.sync_handle)
    if s.sync_handle.status == 'done' then
      s.state.set_voices(s.sync_handle.result)
      api.save_voices_cache(s.sync_handle.result)
      s.sync_msg   = ('Synced · %d voices'):format(#s.sync_handle.result)
      s.sync_color = theme.COLORS.status_done
      s.sync_handle = nil
    elseif s.sync_handle.status == 'error' then
      s.sync_msg   = 'Sync failed: ' .. tostring(s.sync_handle.error)
      s.sync_color = theme.COLORS.status_error
      s.sync_handle = nil
    end
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
  local syncing = s.sync_handle ~= nil
  reaper.ImGui_BeginDisabled(ctx, syncing)
  local sync_label = syncing
    and ('Syncing %s'):format(voice_admin.spinner_glyph())
    or  'Sync'
  if theme.button_neutral(ctx, sync_label) then
    s.sync_handle = voice_admin.spawn_refresh()
    if s.sync_handle.status == 'error' then
      s.sync_msg   = 'Sync failed: ' .. tostring(s.sync_handle.error)
      s.sync_color = theme.COLORS.status_error
      s.sync_handle = nil
    end
  end
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Refresh voices from ElevenLabs (async)')
  end
  if s.sync_msg ~= '' then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), s.sync_color or theme.COLORS.text_dim)
    reaper.ImGui_Text(ctx, s.sync_msg)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_Spacing(ctx)

  -- Voice table z headerami + scroll + frozen header row.
  -- BordersInnerH zamiast pełnych Borders — spójne z theme, lżejszy look.
  local TABLE_FLAGS = reaper.ImGui_TableFlags_BordersInnerH()
                    | reaper.ImGui_TableFlags_RowBg()
                    | reaper.ImGui_TableFlags_ScrollY()
                    | reaper.ImGui_TableFlags_Resizable()
                    | reaper.ImGui_TableFlags_SizingFixedFit()
                    | reaper.ImGui_TableFlags_PadOuterX()

  -- Rezerwa pod tabelą: caption "Showing N voices" + separator + buttons +
  -- bottom padding. ~95px daje oddech (theme FramePadding 10/6 → buttons
  -- ~30px height; plus 2× Spacing + Separator = ~50px combined; +45px
  -- breathing room na dole popupu).
  local visible_count = 0
  if reaper.ImGui_BeginTable(ctx, 'voices_table', 7, TABLE_FLAGS, -1, -95) then
    if reaper.ImGui_TableSetupScrollFreeze then
      reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)  -- freeze header row
    end
    reaper.ImGui_TableSetupColumn(ctx, '★',        reaper.ImGui_TableColumnFlags_WidthFixed(),   28)
    reaper.ImGui_TableSetupColumn(ctx, '',         reaper.ImGui_TableColumnFlags_WidthFixed(),   50)
    reaper.ImGui_TableSetupColumn(ctx, 'Name',     reaper.ImGui_TableColumnFlags_WidthStretch(), 3)
    reaper.ImGui_TableSetupColumn(ctx, 'Gender',   reaper.ImGui_TableColumnFlags_WidthFixed(),   70)
    reaper.ImGui_TableSetupColumn(ctx, 'Accent',   reaper.ImGui_TableColumnFlags_WidthFixed(),   110)
    reaper.ImGui_TableSetupColumn(ctx, 'Age',      reaper.ImGui_TableColumnFlags_WidthFixed(),   90)
    reaper.ImGui_TableSetupColumn(ctx, 'Category', reaper.ImGui_TableColumnFlags_WidthFixed(),   100)
    reaper.ImGui_TableHeadersRow(ctx)

    for _, v in ipairs(s.state.voices) do
      local is_fav = config.is_favorite(v.voice_id)
      if (not s.favorites_only or is_fav)
         and matches(v, s.search, s.gender, s.accent, s.category) then
        visible_count = visible_count + 1
        local labels = v.labels or {}

        reaper.ImGui_TableNextRow(ctx)

        -- Col 0: ★ favorite toggle
        reaper.ImGui_TableNextColumn(ctx)
        local star_label = (is_fav and '★' or '☆') .. '##fav_' .. v.voice_id
        if is_fav then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.primary)
        end
        if reaper.ImGui_SmallButton(ctx, star_label) then
          config.toggle_favorite(v.voice_id)
        end
        if is_fav then reaper.ImGui_PopStyleColor(ctx, 1) end
        if reaper.ImGui_IsItemHovered(ctx) then
          reaper.ImGui_SetTooltip(ctx, is_fav and 'Unfavorite' or 'Favorite (local only)')
        end

        -- Col 1: Play/Stop button
        reaper.ImGui_TableNextColumn(ctx)
        local has_preview = v.preview_url and v.preview_url ~= ''
        local playing = is_playing(v.voice_id)
        reaper.ImGui_BeginDisabled(ctx, not has_preview)
        local btn_label = (playing and 'Stop' or 'Play') .. '##play_' .. v.voice_id
        if reaper.ImGui_SmallButton(ctx, btn_label) then
          if playing then stop_preview() else action_preview(v) end
        end
        reaper.ImGui_EndDisabled(ctx)
        if reaper.ImGui_IsItemHovered(ctx) then
          local tip
          if not has_preview then
            tip = 'No preview URL'
          elseif reaper.CF_CreatePreview then
            tip = playing and 'Stop' or 'Play 5s in-app via SWS'
          else
            tip = 'Play 5s (external player — install SWS for in-app)'
          end
          reaper.ImGui_SetTooltip(ctx, tip)
        end

        -- Col 1: Name (selectable, double-click = apply)
        reaper.ImGui_TableNextColumn(ctx)
        local is_selected = (v.voice_id == s.selected_voice_id)
        local sel_flags = reaper.ImGui_SelectableFlags_AllowDoubleClick()
        if reaper.ImGui_Selectable(ctx, (v.name or '?') .. '##sel_' .. v.voice_id,
            is_selected, sel_flags) then
          s.selected_voice_id = v.voice_id
          if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
            stop_preview()
            apply_voice(v.voice_id, v.name)
            reaper.ImGui_CloseCurrentPopup(ctx)
          end
        end
        if reaper.ImGui_IsItemHovered(ctx) and v.description and v.description ~= '' then
          reaper.ImGui_SetTooltip(ctx, v.description)
        end

        -- Col 2-5: labels (text, no selectability)
        reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_Text(ctx, labels.gender or '—')
        reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_Text(ctx, labels.accent or '—')
        reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_Text(ctx, labels.age    or '—')
        reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_Text(ctx, v.category    or '—')
      end
    end

    reaper.ImGui_EndTable(ctx)
  end

  reaper.ImGui_TextDisabled(ctx, ('Showing %d / %d voices · double-click name to apply')
    :format(visible_count, #s.state.voices))

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Action buttons. Każde zamknięcie modala stop'uje preview.
  -- Bezpieczna kolejność (destruktywne po lewej, primary po prawej):
  -- Clear voice · Cancel · Select
  -- Clear voice ukryty gdy allow_clear=false (np. TTS mode — wybór głosu
  -- per-generacja, nie ma sensu "wyczyść").
  if s.allow_clear then
    if theme.button_danger(ctx, 'Clear voice', 110, 0) then
      stop_preview()
      clear_voice()
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx)
  end
  if theme.button_neutral(ctx, 'Cancel', 100, 0) then
    stop_preview()
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_SameLine(ctx)

  reaper.ImGui_BeginDisabled(ctx, not s.selected_voice_id)
  if theme.button_primary(ctx, 'Select', 110, 0) then
    stop_preview()
    for _, v in ipairs(s.state.voices) do
      if v.voice_id == s.selected_voice_id then
        apply_voice(v.voice_id, v.name)
        break
      end
    end
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_EndPopup(ctx)
end

return M
