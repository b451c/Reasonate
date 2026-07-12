-- modules/gui/cast_manager.lua
-- Modal: save current cast + list saved casts + apply / delete.
-- Cast = role → voice mapping, persistowany globalnie (ExtState).

local cast    = require 'modules.cast'
local helpers = require 'modules.reaper_helpers'
local theme   = require 'modules.theme'

local M = {}

local POPUP_ID = 'Casts'

local s = {
  pending_open  = false,
  state         = nil,
  selected_name = nil,
  new_name_buf  = '',
  status_msg    = '',
  status_color  = 0xCCCCCCFF,
}

local COL_OK   = 0x80E090FF
local COL_ERR  = 0xFF8888FF
local COL_INFO = 0xCCCCCCFF

local function set_status(msg, col)
  s.status_msg   = msg or ''
  s.status_color = col or COL_INFO
end

----------------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------------
local function action_save()
  local ok, msg = cast.save_current(s.new_name_buf)
  if ok then
    set_status(msg, COL_OK)
    s.selected_name = s.new_name_buf
    s.new_name_buf = ''
  else
    set_status(msg, COL_ERR)
  end
end

local function action_apply()
  local entry = cast.find(s.selected_name)
  if not entry or not entry.mapping then
    set_status('cast not found', COL_ERR)
    return
  end
  local applied = 0
  for tr in helpers.iter_tracks() do
    local role = helpers.get_track_role(tr)
    if role and entry.mapping[role] then
      local v = entry.mapping[role]
      -- Mutacja przez state (force refresh + cache invalidation)
      if s.state and s.state.set_voice then
        s.state.set_voice(helpers.track_guid(tr), v.voice_id, v.voice_name)
        applied = applied + 1
      end
    end
  end
  if applied == 0 then
    set_status(('No tracks with matching roles. Cast has roles: %s')
      :format(table.concat(M._roles_of(entry), ', ')), COL_ERR)
  else
    set_status(('Applied "%s" to %d track(s)'):format(s.selected_name, applied), COL_OK)
  end
end

local function action_delete()
  if not s.selected_name then return end
  cast.delete(s.selected_name)
  set_status(('Deleted "%s"'):format(s.selected_name), COL_INFO)
  s.selected_name = nil
end

function M._roles_of(entry)
  local list = {}
  for k in pairs(entry.mapping or {}) do list[#list + 1] = k end
  table.sort(list)
  return list
end

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------
function M.open(state)
  s.pending_open = true
  s.state = state
  s.status_msg = ''
end

function M.render(ctx)
  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    s.pending_open = false
  end

  theme.center_next_modal(ctx, 580, 480)
  theme.popup_keep_top(ctx, POPUP_ID)

  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end
  if not p_open then reaper.ImGui_CloseCurrentPopup(ctx) end

  -- TextWrapped żeby się zawijał w obrębie okna (TextDisabled tnie na boundary).
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'Cast = role → voice mapping. Save the current project, then Apply to a new one with matching role names.')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Save current cast')

  reaper.ImGui_SetNextItemWidth(ctx, 280)
  local rv, new_val = reaper.ImGui_InputText(ctx, '##cast_name', s.new_name_buf)
  if rv then s.new_name_buf = new_val end

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_BeginDisabled(ctx, s.new_name_buf == '')
  if theme.button_primary(ctx, 'Save', 110, 0) then action_save() end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, 'Saved casts')

  local casts = cast.list()
  if #casts == 0 then
    reaper.ImGui_TextDisabled(ctx, '(none yet — save first)')
  else
    -- ReaImGui contract: EndChild TYLKO gdy BeginChild zwrócił true.
    if reaper.ImGui_BeginChild(ctx, 'casts_list', -1, 220) then
      for _, c in ipairs(casts) do
        local n_roles = cast.count_roles(c.mapping or {})
        local age_min = c.saved_at and math.floor((os.time() - c.saved_at) / 60) or 0
        local age_str
        if age_min < 60 then age_str = age_min .. 'm ago'
        elseif age_min < 60*24 then age_str = math.floor(age_min/60) .. 'h ago'
        else age_str = math.floor(age_min/60/24) .. 'd ago' end
        local label = ('%s   ·   %d role%s   ·   %s'):format(
          c.name, n_roles, n_roles == 1 and '' or 's', age_str)
        if reaper.ImGui_Selectable(ctx, label .. '##' .. c.name,
            s.selected_name == c.name) then
          s.selected_name = c.name
        end
        if reaper.ImGui_IsItemHovered(ctx) then
          local roles = M._roles_of(c)
          if #roles > 0 then
            reaper.ImGui_SetTooltip(ctx, 'Roles: ' .. table.concat(roles, ', '))
          end
        end
      end
      reaper.ImGui_EndChild(ctx)
    end
  end

  reaper.ImGui_Spacing(ctx)

  reaper.ImGui_BeginDisabled(ctx, not s.selected_name)
  if theme.button_primary(ctx, 'Apply selected', 150, 0) then action_apply() end
  reaper.ImGui_SameLine(ctx)
  if theme.button_danger(ctx, 'Delete', 100, 0) then action_delete() end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_SameLine(ctx)
  if theme.button_neutral(ctx, 'Close', 100, 0) then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  if s.status_msg ~= '' then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), s.status_color)
    reaper.ImGui_TextWrapped(ctx, s.status_msg)
    reaper.ImGui_PopStyleColor(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

return M
