-- modules/gui/voice_library.lua
-- Browse public ElevenLabs Voice Library + import voices to user account.
-- Wykorzystuje async voice_admin.spawn_list_shared / spawn_add_shared.
--
-- Workflow:
--   user open Library → spawn_list_shared (default filters page=0)
--   list renders w table (search, filters, preview, [Add] button)
--   user clicks [Add] → spawn_add_shared → success: refresh user voices,
--     voice pojawia się w voice_picker.

local theme       = require 'modules.theme'
local voice_admin = require 'modules.voice_admin'
local preview     = require 'modules.preview'
local api         = require 'modules.api'
local util        = require 'modules.util'

local M = {}

local POPUP_ID = 'Voice Library##rc_voice_library'

local CATEGORIES = { '', 'professional', 'high_quality', 'famous' }
local GENDERS    = { '', 'male', 'female', 'neutral' }
local AGES       = { '', 'young', 'middle_aged', 'old' }
local LANGUAGES  = { '', 'pl', 'en', 'es', 'de', 'fr', 'it', 'pt', 'nl', 'cs', 'ru', 'uk', 'tr', 'ja', 'zh' }
-- use_cases values per ElevenLabs Voice Library website filter taxonomy.
-- Empty string = wszystkie. API param = use_cases (multi-value allowed,
-- robimy single-select dla simplicity).
local USE_CASES  = {
  '',
  'narrative_story',
  'conversational',
  'characters_animation',
  'social_media',
  'entertainment_tv',
  'advertisement',
  'informative_educational',
  'video_games',
  'meditation',
}

local s = {
  pending_open       = false,
  state              = nil,
  -- Filters
  search             = '',
  gender             = '',
  age                = '',
  language           = '',
  category           = '',
  use_case           = '',
  featured           = false,
  -- include_custom_rates / include_live_moderated: API booleans, default
  -- exclude (false) per ElevenLabs UI default. User toggle = include.
  custom_rates       = false,
  live_moderated     = false,
  page               = 0,
  page_size          = 30,
  -- Search debounce: dirty timestamp + last submitted; render fires action
  -- po quietness > debounce window (zapobiega spamowaniu API per keystroke).
  search_dirty_at    = nil,
  last_searched      = '',
  -- Async
  list_handle        = nil,
  add_handle         = nil,         -- which row is being added (voice_id key)
  refresh_after_add  = nil,         -- voice_admin handle (refresh user voices po add)
  -- Result
  voices             = {},          -- list of shared voice objects
  has_more           = false,
  total_count        = 0,
  -- Status
  status_msg         = '',
  status_color       = nil,
  -- Cache adding to prevent re-spawn
  pending_add        = nil,         -- {public_owner_id, voice_id, name}
}

local COL_OK   = theme.COLORS.status_done
local COL_ERR  = theme.COLORS.status_error

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------
local function current_filters()
  return {
    search                  = s.search,
    gender                  = s.gender,
    age                     = s.age,
    language                = s.language,
    category                = s.category,
    use_case                = s.use_case,
    featured                = s.featured,
    include_custom_rates    = s.custom_rates,
    include_live_moderated  = s.live_moderated,
    page                    = s.page,
    page_size               = s.page_size,
  }
end

function M.open(state)
  s.pending_open = true
  s.state        = state
  s.status_msg   = ''
  -- Fetch immediately on first open if voices empty
  if #s.voices == 0 and not s.list_handle then
    s.list_handle = voice_admin.spawn_list_shared(current_filters())
  end
end

function M.is_open() return s.pending_open end

----------------------------------------------------------------------------
-- Async pollers
----------------------------------------------------------------------------
local function poll_list()
  if not s.list_handle then return end
  voice_admin.poll(s.list_handle)
  if s.list_handle.status == 'done' then
    local r = s.list_handle.result or {}
    s.voices      = r.voices or {}
    s.has_more    = r.has_more or false
    s.total_count = r.total_count or 0
    s.list_handle = nil
  elseif s.list_handle.status == 'error' then
    s.status_msg   = 'List failed: ' .. tostring(s.list_handle.error)
    s.status_color = COL_ERR
    s.list_handle  = nil
  end
end

local function poll_add()
  if not s.add_handle then return end
  voice_admin.poll(s.add_handle)
  if s.add_handle.status == 'done' then
    local args = s.add_handle.args
    s.status_msg   = ('Added "%s" to your voices'):format(args.new_name)
    s.status_color = COL_OK
    s.pending_add  = nil
    s.add_handle   = nil
    -- Trigger refresh user voices żeby nowy pojawił się w voice_picker.
    s.refresh_after_add = voice_admin.spawn_refresh()
  elseif s.add_handle.status == 'error' then
    s.status_msg   = 'Add failed: ' .. tostring(s.add_handle.error)
    s.status_color = COL_ERR
    s.pending_add  = nil
    s.add_handle   = nil
  end
end

local function poll_refresh_after_add()
  if not s.refresh_after_add then return end
  voice_admin.poll(s.refresh_after_add)
  if s.refresh_after_add.status == 'done' then
    if s.state and s.state.set_voices then
      s.state.set_voices(s.refresh_after_add.result)
      api.save_voices_cache(s.refresh_after_add.result)
    end
    s.refresh_after_add = nil
  elseif s.refresh_after_add.status == 'error' then
    -- Silent — voice was added, just user-side refresh failed.
    s.refresh_after_add = nil
  end
end

----------------------------------------------------------------------------
-- Trigger fetch with current filters (page reset to 0)
----------------------------------------------------------------------------
local function action_search()
  s.page         = 0
  s.list_handle  = voice_admin.spawn_list_shared(current_filters())
  if s.list_handle.status == 'error' then
    s.status_msg   = 'List failed: ' .. tostring(s.list_handle.error)
    s.status_color = COL_ERR
    s.list_handle  = nil
  end
end

local function action_page(delta)
  s.page = math.max(0, s.page + delta)
  s.list_handle = voice_admin.spawn_list_shared(current_filters())
end

----------------------------------------------------------------------------
-- Combo filter helper
----------------------------------------------------------------------------
local function filter_combo(ctx, label, options, current)
  local display = (current == '' or current == nil) and ('(' .. label .. ')') or current
  local picked = current
  reaper.ImGui_SetNextItemWidth(ctx, 110)
  if reaper.ImGui_BeginCombo(ctx, '##' .. label, display) then
    for _, opt in ipairs(options) do
      local lbl = (opt == '') and ('(any ' .. label .. ')') or opt
      if reaper.ImGui_Selectable(ctx, lbl, current == opt) then
        picked = opt   -- capture, EndCombo always; return picked at end (CLAUDE.md inv 6)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  return picked
end

----------------------------------------------------------------------------
-- Render
----------------------------------------------------------------------------
local SEARCH_DEBOUNCE = 0.3   -- seconds quietness before fire

function M.render(ctx)
  poll_list()
  poll_add()
  poll_refresh_after_add()

  -- Debounced search trigger — fire gdy quietness > 300ms i search się zmienił
  -- od ostatniego fetch. Eliminates per-keystroke API spam. Dirty_at trzymamy
  -- gdy list jest busy → fire próbuje ponownie po jego zakończeniu.
  if s.search_dirty_at and (util.now() - s.search_dirty_at) > SEARCH_DEBOUNCE then
    if s.search == s.last_searched then
      s.search_dirty_at = nil    -- already searched this exact value
    elseif not s.list_handle then
      s.last_searched   = s.search
      s.search_dirty_at = nil
      action_search()
    end
    -- else: list_handle running → keep dirty_at, retry next frame
  end

  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    s.pending_open = false
  end

  theme.center_next_modal(ctx, 1080, 720)
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 880, 520, 99999, 99999)
  theme.popup_keep_top(ctx, POPUP_ID)
  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end
  if not p_open then reaper.ImGui_CloseCurrentPopup(ctx) end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'Browse public voices from the ElevenLabs Voice Library and import them ' ..
    'to your account. After import, voice appears in Pick voice for any track.')
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)

  -- Filter row
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Search:')
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 220)
  local rv, new_search = reaper.ImGui_InputText(ctx, '##vl_search', s.search)
  if rv then
    s.search          = new_search
    s.search_dirty_at = util.now()
  end

  -- Combo/checkbox change → auto-trigger search (no Apply click needed).
  -- Search input keeps Enter-trigger żeby nie spamować API per keystroke.
  local filters_changed = false

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  do
    local before = s.gender
    s.gender = filter_combo(ctx, 'gender', GENDERS, s.gender)
    if s.gender ~= before then filters_changed = true end
  end
  reaper.ImGui_SameLine(ctx)
  do
    local before = s.age
    s.age = filter_combo(ctx, 'age', AGES, s.age)
    if s.age ~= before then filters_changed = true end
  end
  reaper.ImGui_SameLine(ctx)
  do
    local before = s.language
    s.language = filter_combo(ctx, 'language', LANGUAGES, s.language)
    if s.language ~= before then filters_changed = true end
  end
  reaper.ImGui_SameLine(ctx)
  do
    local before = s.category
    s.category = filter_combo(ctx, 'category', CATEGORIES, s.category)
    if s.category ~= before then filters_changed = true end
  end
  reaper.ImGui_SameLine(ctx)
  do
    local before = s.use_case
    s.use_case = filter_combo(ctx, 'use case', USE_CASES, s.use_case)
    if s.use_case ~= before then filters_changed = true end
  end

  -- Drugi rząd: bool toggles (Featured / Custom rates / Live moderated).
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextDisabled(ctx, 'Include:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  local rv_f, new_f = reaper.ImGui_Checkbox(ctx, 'Featured', s.featured)
  if rv_f then s.featured = new_f; filters_changed = true end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  local rv_cr, new_cr = reaper.ImGui_Checkbox(ctx, 'Custom rates', s.custom_rates)
  if rv_cr then s.custom_rates = new_cr; filters_changed = true end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Voices with custom pricing rates')
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  local rv_lm, new_lm = reaper.ImGui_Checkbox(ctx, 'Live moderated', s.live_moderated)
  if rv_lm then s.live_moderated = new_lm; filters_changed = true end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Voices with active live moderation')
  end

  -- Clear filters button — reset all to default. Tylko gdy cokolwiek active.
  local has_active_filters = (s.search ~= '') or (s.gender ~= '') or (s.age ~= '')
                          or (s.language ~= '') or (s.category ~= '')
                          or (s.use_case ~= '') or s.featured
                          or s.custom_rates or s.live_moderated
  if has_active_filters then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    if theme.button_neutral(ctx, 'Clear filters') then
      s.search         = ''
      s.gender         = ''
      s.age            = ''
      s.language       = ''
      s.category       = ''
      s.use_case       = ''
      s.featured       = false
      s.custom_rates   = false
      s.live_moderated = false
      filters_changed  = true
    end
  end

  -- Searching indicator (no Apply button — filter changes auto-trigger).
  local listing = s.list_handle ~= nil
  if listing then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xF59E0BFF)
    reaper.ImGui_Text(ctx, ('Searching %s'):format(voice_admin.spinner_glyph()))
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  if filters_changed and not listing then
    action_search()
  end

  if s.status_msg ~= '' then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), s.status_color or 0xCCCCCCFF)
    reaper.ImGui_Text(ctx, s.status_msg)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)

  -- Results table
  local table_flags = reaper.ImGui_TableFlags_RowBg()
                    | reaper.ImGui_TableFlags_BordersInnerH()
                    | reaper.ImGui_TableFlags_ScrollY()
                    | reaper.ImGui_TableFlags_SizingStretchProp()
  if reaper.ImGui_BeginTable(ctx, '##vl_table', 6, table_flags, 0, -90) then
    reaper.ImGui_TableSetupColumn(ctx, '',         reaper.ImGui_TableColumnFlags_WidthFixed(),   50)
    reaper.ImGui_TableSetupColumn(ctx, 'Name',     reaper.ImGui_TableColumnFlags_WidthStretch(), 4)
    reaper.ImGui_TableSetupColumn(ctx, 'Gender',   reaper.ImGui_TableColumnFlags_WidthFixed(),   70)
    reaper.ImGui_TableSetupColumn(ctx, 'Lang/Acc', reaper.ImGui_TableColumnFlags_WidthFixed(),  120)
    reaper.ImGui_TableSetupColumn(ctx, 'Category', reaper.ImGui_TableColumnFlags_WidthFixed(),   90)
    reaper.ImGui_TableSetupColumn(ctx, 'Action',   reaper.ImGui_TableColumnFlags_WidthFixed(),  120)
    reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
    reaper.ImGui_TableHeadersRow(ctx)

    for _, v in ipairs(s.voices) do
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableNextColumn(ctx)

      -- Play preview
      local has_preview = v.preview_url and v.preview_url ~= ''
      local playing     = preview.is_playing(v.voice_id)
      reaper.ImGui_BeginDisabled(ctx, not has_preview)
      local btn = (playing and 'Stop' or 'Play') .. '##vlp_' .. v.voice_id
      if reaper.ImGui_SmallButton(ctx, btn) then
        if playing then
          preview.stop()
        else
          preview.play_url(v.preview_url, v.voice_id)
        end
      end
      reaper.ImGui_EndDisabled(ctx)

      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_Text(ctx, v.name or '?')
      if v.description and v.description ~= '' and reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, v.description:sub(1, 200))
      end

      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_TextDisabled(ctx, v.gender or '—')

      reaper.ImGui_TableNextColumn(ctx)
      local lang_acc = (v.language or '—')
      if v.accent and v.accent ~= '' then lang_acc = lang_acc .. '/' .. v.accent end
      reaper.ImGui_TextDisabled(ctx, lang_acc)

      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_TextDisabled(ctx, v.category or '—')

      reaper.ImGui_TableNextColumn(ctx)
      local is_adding = s.add_handle and s.pending_add
                        and s.pending_add.voice_id == v.voice_id
      reaper.ImGui_BeginDisabled(ctx, s.add_handle ~= nil)
      local add_label = is_adding
        and ('Adding %s'):format(voice_admin.spinner_glyph())
        or  'Add'
      if theme.button_primary(ctx, add_label .. '##vla_' .. v.voice_id) then
        s.pending_add = {
          public_owner_id = v.public_owner_id,
          voice_id        = v.voice_id,
          name            = v.name or 'Voice',
        }
        s.add_handle = voice_admin.spawn_add_shared(
          v.public_owner_id, v.voice_id, v.name or 'Voice')
        if s.add_handle.status == 'error' then
          s.status_msg   = 'Add failed: ' .. tostring(s.add_handle.error)
          s.status_color = COL_ERR
          s.add_handle   = nil
          s.pending_add  = nil
        end
      end
      reaper.ImGui_EndDisabled(ctx)
    end

    reaper.ImGui_EndTable(ctx)
  end

  -- Pagination + counter
  reaper.ImGui_Spacing(ctx)
  local total_label = (s.total_count > 0) and (' · %d total'):format(s.total_count) or ''
  reaper.ImGui_TextDisabled(ctx,
    ('Page %d · %d voices%s'):format(s.page + 1, #s.voices, total_label))
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
  reaper.ImGui_BeginDisabled(ctx, s.page == 0 or listing)
  if theme.button_neutral(ctx, '< Prev') then action_page(-1) end
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_BeginDisabled(ctx, not s.has_more or listing)
  if theme.button_neutral(ctx, 'Next >') then action_page(1) end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_Separator(ctx)
  if theme.button_neutral(ctx, 'Close') then
    preview.stop()
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

return M
