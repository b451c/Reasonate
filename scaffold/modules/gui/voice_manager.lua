-- modules/gui/voice_manager.lua
-- Voice Manager: list owned voices z ElevenLabs, rename/delete bez wychodzenia
-- z Reasonate. Read voices z state.voices (pre-fetched cache); operacje
-- destrukcyjne (rename/delete) idą sync przez voice_clone.* helpery, post-OK
-- mutują state.voices in-place + persisted cache.

local theme       = require 'modules.theme'
local api         = require 'modules.api'
local vc          = require 'modules.voice_clone'
local voice_admin = require 'modules.voice_admin'

local M = {}

local POPUP_ID              = 'Voice Manager##rc_voice_manager'
local RENAME_POPUP_ID       = 'Rename voice##rc_vm_rename'
local DELETE_POPUP_ID       = 'Delete voice##rc_vm_delete'
local BATCH_DELETE_POPUP_ID = 'Delete selected##rc_vm_batch_delete'

local s = {
  pending_open    = false,
  state           = nil,             -- ref do state moduł (set w open())
  search          = '',
  busy            = false,           -- refresh in progress
  status_msg      = '',
  status_color    = nil,
  rename_target   = nil,             -- { voice_id, original_name } gdy aktywny
  rename_buf      = '',
  rename_pending_open = false,
  rename_error    = nil,
  delete_target   = nil,             -- voice obj
  delete_pending_open = false,
  delete_error    = nil,
  -- Batch delete: selection set + nested confirm popup
  selected            = {},          -- { [voice_id] = true }
  batch_pending_open  = false,
  batch_errors        = nil,         -- list of { name, err } po async delete
  -- Async handles. Każda operacja powiąże się z handle który polluje render.
  refresh_handle      = nil,
  rename_handle       = nil,
  delete_handle       = nil,
  -- Batch async: kolejka pending voices + handle aktualnie running
  batch_queue         = nil,         -- list of voices do delete (sequential)
  batch_handle        = nil,         -- aktualnie running delete
  batch_done_count    = 0,
  batch_total         = 0,
}

local COL_OK   = 0x80E090FF
local COL_ERR  = 0xFF8888FF

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------
function M.open(state)
  s.pending_open = true
  s.state        = state
  s.status_msg   = ''
  s.search       = ''
  s.selected     = {}
  s.batch_errors = nil
end

local function selection_count()
  local n = 0
  for _ in pairs(s.selected) do n = n + 1 end
  return n
end

function M.is_open() return s.pending_open end

----------------------------------------------------------------------------
-- Filter: zwraca tylko voices którymi user może zarządzać.
-- is_owner=true preferowane (explicit signal z v2 API). Fallback na category
-- (cloned / professional / generated) gdy field brakuje (stary cache).
----------------------------------------------------------------------------
local OWNED_CATEGORIES = { cloned = true, professional = true, generated = true }

local function is_owned(v)
  if v.is_owner == true then return true end
  if v.is_owner == false then return false end  -- explicit non-owner
  return OWNED_CATEGORIES[v.category] == true
end

local function filtered_voices()
  local out = {}
  if not s.state or not s.state.voices then return out end
  local q = (s.search or ''):lower()
  for _, v in ipairs(s.state.voices) do
    if is_owned(v) then
      if q == '' or (v.name or ''):lower():find(q, 1, true) then
        out[#out + 1] = v
      end
    end
  end
  return out
end

----------------------------------------------------------------------------
-- Refresh: refetch voices z API → update state.voices + persisted cache.
-- Sync, blokuje UI ~5-15s (custom voices duże response). Wywoływany manualnie
-- (Refresh button) — nie auto na open.
----------------------------------------------------------------------------
-- Spawn async refresh; status pill renders w main popup; render polls handle.
local function action_refresh()
  s.refresh_handle = voice_admin.spawn_refresh()
  if s.refresh_handle.status == 'error' then
    s.status_msg     = 'Refresh failed: ' .. tostring(s.refresh_handle.error)
    s.status_color   = COL_ERR
    s.refresh_handle = nil
  end
end

local function poll_refresh()
  if not s.refresh_handle then return end
  voice_admin.poll(s.refresh_handle)
  if s.refresh_handle.status == 'done' then
    s.state.set_voices(s.refresh_handle.result)
    api.save_voices_cache(s.refresh_handle.result)
    s.status_msg     = ('Refreshed · %d voices'):format(#s.refresh_handle.result)
    s.status_color   = COL_OK
    s.refresh_handle = nil
  elseif s.refresh_handle.status == 'error' then
    s.status_msg     = 'Refresh failed: ' .. tostring(s.refresh_handle.error)
    s.status_color   = COL_ERR
    s.refresh_handle = nil
  end
end

----------------------------------------------------------------------------
-- Local in-place mutations on state.voices (po API success).
----------------------------------------------------------------------------
local function update_local_name(voice_id, new_name)
  if not s.state or not s.state.voices then return end
  for _, v in ipairs(s.state.voices) do
    if v.voice_id == voice_id then v.name = new_name; break end
  end
  api.save_voices_cache(s.state.voices)
end

local function remove_local_voice(voice_id)
  if not s.state or not s.state.voices then return end
  for i = #s.state.voices, 1, -1 do
    if s.state.voices[i].voice_id == voice_id then
      table.remove(s.state.voices, i); break
    end
  end
  api.save_voices_cache(s.state.voices)
end

----------------------------------------------------------------------------
-- Render: rename popup (nested w main voice_manager popup)
----------------------------------------------------------------------------
local function render_rename_popup(ctx)
  if s.rename_pending_open then
    reaper.ImGui_OpenPopup(ctx, RENAME_POPUP_ID)
    s.rename_pending_open = false
  end

  -- Center on Voice Manager popup
  local mx, my = reaper.ImGui_GetWindowPos(ctx)
  local mw, mh = reaper.ImGui_GetWindowSize(ctx)
  reaper.ImGui_SetNextWindowPos(ctx, mx + mw / 2, my + mh / 2,
    reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSize(ctx, 440, 0, reaper.ImGui_Cond_Appearing())
  -- NIE popup_keep_top dla nested sub-popup (parent: Voice Manager main popup) —
  -- SetWindowFocusEx co frame na nested popup blokował parent popup input
  -- dispatch (PM9 iter5 regresja od popup_keep_top, fix iter5 hotfix).
  -- Dispatch position INSIDE parent popup już gwarantuje proper z-order.

  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, RENAME_POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if not visible then return end
  if s.rename_should_close then
    s.rename_should_close = false
    s.rename_target       = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
    reaper.ImGui_EndPopup(ctx)
    return
  end
  if not p_open and not s.rename_handle then
    s.rename_target = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  if s.rename_target then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_TextWrapped(ctx, ('Renaming "%s" in your ElevenLabs account.'):format(
      s.rename_target.original_name or '?'))
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx)

    reaper.ImGui_Text(ctx, 'New name:')
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local rv, new_buf = reaper.ImGui_InputText(ctx, '##rename_buf', s.rename_buf)
    if rv then s.rename_buf = new_buf end

    if s.rename_error then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_ERR)
      reaper.ImGui_TextWrapped(ctx, 'Error: ' .. s.rename_error)
      reaper.ImGui_PopStyleColor(ctx, 1)
    end

    reaper.ImGui_Spacing(ctx)
    local renaming = s.rename_handle ~= nil
    if renaming then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xF59E0BFF)
      reaper.ImGui_Text(ctx, ('Renaming %s'):format(voice_admin.spinner_glyph()))
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_Spacing(ctx)
    end

    local clean = (s.rename_buf or ''):gsub('[%c]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    local unchanged = clean == (s.rename_target.original_name or '')
    reaper.ImGui_BeginDisabled(ctx, clean == '' or unchanged or renaming)
    if theme.button_primary(ctx, 'Save') then
      s.rename_error  = nil
      s.rename_handle = voice_admin.spawn_rename(s.rename_target.voice_id, clean)
      if s.rename_handle.status == 'error' then
        s.rename_error  = tostring(s.rename_handle.error)
        s.rename_handle = nil
      end
      -- Popup zamykamy w poll_rename gdy status='done' (po API success).
      -- Tu nie zamykamy — user widzi spinner.
    end
    reaper.ImGui_EndDisabled(ctx)
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_BeginDisabled(ctx, renaming)
    if theme.button_neutral(ctx, 'Cancel') then
      s.rename_target = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndDisabled(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

----------------------------------------------------------------------------
-- Render: delete confirm popup (nested)
----------------------------------------------------------------------------
local function render_delete_popup(ctx)
  if s.delete_pending_open then
    reaper.ImGui_OpenPopup(ctx, DELETE_POPUP_ID)
    s.delete_pending_open = false
  end

  local mx, my = reaper.ImGui_GetWindowPos(ctx)
  local mw, mh = reaper.ImGui_GetWindowSize(ctx)
  reaper.ImGui_SetNextWindowPos(ctx, mx + mw / 2, my + mh / 2,
    reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSize(ctx, 440, 0, reaper.ImGui_Cond_Appearing())
  -- NIE popup_keep_top dla nested sub-popup — patrz comment przy RENAME_POPUP_ID.

  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, DELETE_POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if not visible then return end
  if s.delete_should_close then
    s.delete_should_close = false
    s.delete_target       = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
    reaper.ImGui_EndPopup(ctx)
    return
  end
  if not p_open and not s.delete_handle then
    s.delete_target = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  if s.delete_target then
    reaper.ImGui_TextWrapped(ctx, ('Delete voice "%s" from your ElevenLabs account?'):format(
      s.delete_target.name or '?'))
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_TextWrapped(ctx,
      'This cannot be undone. Existing tracks using this voice will start failing ' ..
      'until reassigned. Cached AI items in projects keep working (audio already rendered).')
    reaper.ImGui_PopStyleColor(ctx, 1)

    if s.delete_error then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_ERR)
      reaper.ImGui_TextWrapped(ctx, 'Error: ' .. s.delete_error)
      reaper.ImGui_PopStyleColor(ctx, 1)
    end

    reaper.ImGui_Spacing(ctx)
    local deleting = s.delete_handle ~= nil
    if deleting then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xF59E0BFF)
      reaper.ImGui_Text(ctx, ('Deleting %s'):format(voice_admin.spinner_glyph()))
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_Spacing(ctx)
    end

    reaper.ImGui_BeginDisabled(ctx, deleting)
    if theme.button_danger(ctx, 'Delete') then
      s.delete_error  = nil
      s.delete_handle = voice_admin.spawn_delete(s.delete_target.voice_id)
      s.delete_handle.args._display_name = s.delete_target.name
      if s.delete_handle.status == 'error' then
        s.delete_error  = tostring(s.delete_handle.error)
        s.delete_handle = nil
      end
    end
    reaper.ImGui_EndDisabled(ctx)
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_BeginDisabled(ctx, deleting)
    if theme.button_neutral(ctx, 'Cancel') then
      s.delete_target = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndDisabled(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

----------------------------------------------------------------------------
-- Render: batch delete confirm popup (nested)
----------------------------------------------------------------------------
local function render_batch_delete_popup(ctx)
  if s.batch_pending_open then
    reaper.ImGui_OpenPopup(ctx, BATCH_DELETE_POPUP_ID)
    s.batch_pending_open = false
  end

  local mx, my = reaper.ImGui_GetWindowPos(ctx)
  local mw, mh = reaper.ImGui_GetWindowSize(ctx)
  reaper.ImGui_SetNextWindowPos(ctx, mx + mw / 2, my + mh / 2,
    reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSize(ctx, 480, 0, reaper.ImGui_Cond_Appearing())
  -- NIE popup_keep_top dla nested sub-popup — patrz comment przy RENAME_POPUP_ID.

  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, BATCH_DELETE_POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if not visible then return end
  if s.batch_should_close then
    s.batch_should_close = false
    reaper.ImGui_CloseCurrentPopup(ctx)
    reaper.ImGui_EndPopup(ctx)
    return
  end
  if not p_open and not s.batch_handle and not s.batch_queue then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  -- Build list of selected voices (resolve names z state.voices)
  local targets = {}
  if s.state and s.state.voices then
    for _, v in ipairs(s.state.voices) do
      if s.selected[v.voice_id] then targets[#targets + 1] = v end
    end
  end
  local n = #targets

  reaper.ImGui_TextWrapped(ctx,
    ('Delete %d voice%s from your ElevenLabs account?'):format(n, n == 1 and '' or 's'))
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'This cannot be undone. Tracks using these voices will start failing until ' ..
    'reassigned. Cached AI items keep working (audio already rendered).')
  reaper.ImGui_PopStyleColor(ctx, 1)

  -- Compact list (max 10 visible, rest as "...and X more")
  reaper.ImGui_Spacing(ctx)
  local SHOW_MAX = 10
  for i = 1, math.min(SHOW_MAX, n) do
    reaper.ImGui_BulletText(ctx, targets[i].name or '?')
  end
  if n > SHOW_MAX then
    reaper.ImGui_TextDisabled(ctx, ('…and %d more'):format(n - SHOW_MAX))
  end

  if s.batch_errors and #s.batch_errors > 0 then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_ERR)
    reaper.ImGui_TextWrapped(ctx, ('%d failed:'):format(#s.batch_errors))
    for _, e in ipairs(s.batch_errors) do
      reaper.ImGui_BulletText(ctx, ('%s — %s'):format(e.name or '?', e.err or '?'))
    end
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_Spacing(ctx)
  local batch_running = s.batch_handle ~= nil or s.batch_queue ~= nil
  if batch_running then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xF59E0BFF)
    reaper.ImGui_Text(ctx, ('Deleting %s  %d / %d'):format(
      voice_admin.spinner_glyph(), s.batch_done_count, s.batch_total))
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_Spacing(ctx)
  end
  reaper.ImGui_BeginDisabled(ctx, batch_running or n == 0)
  if theme.button_danger(ctx, ('Delete %d'):format(n)) then
    -- Spawn batch: queue all targets, start sequential delete via poll_batch.
    local queue = {}
    for _, v in ipairs(targets) do
      queue[#queue + 1] = { voice_id = v.voice_id, name = v.name }
    end
    s.batch_queue      = queue
    s.batch_total      = #queue
    s.batch_done_count = 0
    s.batch_errors     = nil
  end
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_BeginDisabled(ctx, batch_running)
  if theme.button_neutral(ctx, 'Cancel') then
    s.batch_errors = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndDisabled(ctx)


  reaper.ImGui_EndPopup(ctx)
end

----------------------------------------------------------------------------
-- Public: render main popup. Wywoływane co frame z reasonate.lua (top-level).
----------------------------------------------------------------------------
----------------------------------------------------------------------------
-- Async pollers — wywoływane na początku M.render każdej klatki.
----------------------------------------------------------------------------
local function poll_rename()
  if not s.rename_handle then return end
  voice_admin.poll(s.rename_handle)
  if s.rename_handle.status == 'done' then
    update_local_name(s.rename_handle.args.voice_id, s.rename_handle.args.new_name)
    s.status_msg          = ('Renamed to "%s"'):format(s.rename_handle.args.new_name)
    s.status_color        = COL_OK
    s.rename_should_close = true
    s.rename_handle       = nil
  elseif s.rename_handle.status == 'error' then
    s.rename_error  = tostring(s.rename_handle.error)
    s.rename_handle = nil
  end
end

local function poll_delete()
  if not s.delete_handle then return end
  voice_admin.poll(s.delete_handle)
  if s.delete_handle.status == 'done' then
    local vid  = s.delete_handle.args.voice_id
    local name = s.delete_handle.args._display_name or vid
    remove_local_voice(vid)
    s.selected[vid]       = nil
    s.status_msg          = ('Deleted "%s"'):format(name)
    s.status_color        = COL_OK
    s.delete_should_close = true
    s.delete_handle       = nil
  elseif s.delete_handle.status == 'error' then
    s.delete_error  = tostring(s.delete_handle.error)
    s.delete_handle = nil
  end
end

-- Batch delete: sequential — kolejny voice spawnowany dopiero po ukończeniu
-- poprzedniego. Bezpieczne dla rate-limit + readable progress (X / N).
local function poll_batch()
  if s.batch_handle then
    voice_admin.poll(s.batch_handle)
    if s.batch_handle.status == 'done' then
      local vid  = s.batch_handle.args.voice_id
      remove_local_voice(vid)
      s.selected[vid]   = nil
      s.batch_done_count = s.batch_done_count + 1
      s.batch_handle    = nil
    elseif s.batch_handle.status == 'error' then
      local vid  = s.batch_handle.args.voice_id
      local name = s.batch_handle.args._display_name or vid
      s.batch_errors    = s.batch_errors or {}
      s.batch_errors[#s.batch_errors + 1] = { name = name, err = tostring(s.batch_handle.error) }
      s.batch_done_count = s.batch_done_count + 1
      s.batch_handle    = nil
    end
  end
  -- Spawn następnego z kolejki gdy żaden nie running.
  if not s.batch_handle and s.batch_queue and #s.batch_queue > 0 then
    local next_v = table.remove(s.batch_queue, 1)
    local h = voice_admin.spawn_delete(next_v.voice_id)
    h.args._display_name = next_v.name
    s.batch_handle = h
    if h.status == 'error' then
      -- Spawn-time error: capture i przejdź dalej
      s.batch_errors = s.batch_errors or {}
      s.batch_errors[#s.batch_errors + 1] = { name = next_v.name, err = tostring(h.error) }
      s.batch_done_count = s.batch_done_count + 1
      s.batch_handle = nil
    end
  end
  -- Kolejka pusta + brak running → koniec batcha.
  if (not s.batch_queue or #s.batch_queue == 0) and not s.batch_handle and s.batch_total > 0 then
    local n_err = s.batch_errors and #s.batch_errors or 0
    local n_ok  = s.batch_done_count - n_err
    if n_err == 0 then
      s.status_msg          = ('Deleted %d voice%s'):format(n_ok, n_ok == 1 and '' or 's')
      s.status_color        = COL_OK
      s.batch_should_close  = true
    else
      s.status_msg = ('Deleted %d · %d failed'):format(n_ok, n_err)
      s.status_color = COL_ERR
      -- Popup pozostaje open — user widzi błędy, może Cancel.
    end
    s.batch_queue       = nil
    s.batch_total       = 0
    s.batch_done_count  = 0
  end
end

function M.render(ctx)
  -- Async polls — przed UI renderem, żeby state widoczny od razu.
  poll_refresh()
  poll_rename()
  poll_delete()
  poll_batch()

  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    s.pending_open = false
  end

  -- Window sizing: szerokość mieści Name/Category/Actions kolumny komfortowo;
  -- wysokość pozwala zobaczyć Close. SizeConstraints klampuje minimum żeby
  -- user nie mógł zmniejszyć poniżej usable.
  theme.center_next_modal(ctx, 920, 700)
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 760, 480, 99999, 99999)
  -- NIE popup_keep_top dla parent popup which has nested sub-popups (Rename/
  -- Delete/Batch_Delete) — SetWindowFocusEx co frame na parent kradnie focus
  -- z nested sub-popup → sub-popup auto-closed → button click brak reakcji.
  -- (PM9 iter5 hotfix #2 — confirmed empirically po fix #1 nie wystarczył.)
  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end
  if not p_open then reaper.ImGui_CloseCurrentPopup(ctx) end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'Manage your ElevenLabs voices: rename clones, delete unused ones. ' ..
    'Premade ElevenLabs voices are filtered out — only voices you own appear here.')
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)

  -- Top bar: search + refresh
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Search:')
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 280)
  local rv, new_search = reaper.ImGui_InputText(ctx, '##vm_search', s.search)
  if rv then s.search = new_search end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
  local refreshing = s.refresh_handle ~= nil
  reaper.ImGui_BeginDisabled(ctx, refreshing)
  local sync_label = refreshing
    and ('Syncing %s'):format(voice_admin.spinner_glyph())
    or  'Sync'
  if theme.button_neutral(ctx, sync_label) then
    action_refresh()
  end
  reaper.ImGui_EndDisabled(ctx)
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Refresh voices from ElevenLabs (async)')
  end

  -- Batch delete trigger
  local sel_n = selection_count()
  local batch_running = s.batch_handle ~= nil or s.batch_queue ~= nil
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
  reaper.ImGui_BeginDisabled(ctx, sel_n == 0 or batch_running)
  if theme.button_danger(ctx, ('Delete selected (%d)'):format(sel_n)) then
    s.batch_errors       = nil
    s.batch_pending_open = true
  end
  reaper.ImGui_EndDisabled(ctx)
  if sel_n > 0 and not batch_running then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    if theme.button_neutral(ctx, 'Clear##vm_clear_sel') then s.selected = {} end
  end

  if s.status_msg ~= '' then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), s.status_color or theme.COLORS.text_dim)
    reaper.ImGui_Text(ctx, s.status_msg)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)

  -- Voices table
  local voices = filtered_voices()
  reaper.ImGui_Text(ctx, ('%d voices'):format(#voices))
  reaper.ImGui_Spacing(ctx)

  local table_flags = reaper.ImGui_TableFlags_RowBg()
                    | reaper.ImGui_TableFlags_BordersInnerH()
                    | reaper.ImGui_TableFlags_ScrollY()
                    | reaper.ImGui_TableFlags_SizingStretchProp()
  -- Table outer_size_y = -90 → fill available height minus reserve dla Close
  -- button + bottom padding. Negative znaczy "from bottom of available space".
  if reaper.ImGui_BeginTable(ctx, '##vm_table', 4, table_flags, 0, -90) then
    reaper.ImGui_TableSetupColumn(ctx, '##sel',    reaper.ImGui_TableColumnFlags_WidthFixed(), 28)
    reaper.ImGui_TableSetupColumn(ctx, 'Name',     reaper.ImGui_TableColumnFlags_WidthStretch(), 5)
    reaper.ImGui_TableSetupColumn(ctx, 'Category', reaper.ImGui_TableColumnFlags_WidthStretch(), 2)
    reaper.ImGui_TableSetupColumn(ctx, 'Actions',  reaper.ImGui_TableColumnFlags_WidthFixed(), 180)
    reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)

    -- Custom header row z select-all checkbox w col 0.
    reaper.ImGui_TableNextRow(ctx, reaper.ImGui_TableRowFlags_Headers())
    reaper.ImGui_TableNextColumn(ctx)
    -- Select-all reflects: all visible voices selected? (pomijamy hidden by search)
    local all_selected = #voices > 0
    for _, v in ipairs(voices) do
      if not s.selected[v.voice_id] then all_selected = false; break end
    end
    local rv_all, new_all = reaper.ImGui_Checkbox(ctx, '##vm_sel_all', all_selected)
    if rv_all then
      if new_all then
        for _, v in ipairs(voices) do s.selected[v.voice_id] = true end
      else
        for _, v in ipairs(voices) do s.selected[v.voice_id] = nil end
      end
    end
    reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_TableHeader(ctx, 'Name')
    reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_TableHeader(ctx, 'Category')
    reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_TableHeader(ctx, 'Actions')

    for _, v in ipairs(voices) do
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableNextColumn(ctx)
      local checked = s.selected[v.voice_id] == true
      local rv_chk, new_chk = reaper.ImGui_Checkbox(ctx, '##sel_' .. v.voice_id, checked)
      if rv_chk then
        s.selected[v.voice_id] = new_chk and true or nil
      end

      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_Text(ctx, v.name or '?')
      -- Type-guard: stary cache mógł mieć fts=table (ElevenLabs zwraca per-
      -- language map dla niektórych voices). Skip badge gdy not-string.
      if type(v.fine_tuning_state) == 'string' and v.fine_tuning_state ~= 'fine_tuned' then
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xF59E0BFF)
        reaper.ImGui_Text(ctx, '· ' .. v.fine_tuning_state)
        reaper.ImGui_PopStyleColor(ctx, 1)
      end

      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_TextDisabled(ctx, v.category or '?')

      reaper.ImGui_TableNextColumn(ctx)
      if theme.button_neutral(ctx, 'Rename##rn_' .. v.voice_id) then
        s.rename_target       = { voice_id = v.voice_id, original_name = v.name or '' }
        s.rename_buf          = v.name or ''
        s.rename_error        = nil
        s.rename_pending_open = true
      end
      reaper.ImGui_SameLine(ctx)
      if theme.button_danger(ctx, 'Delete##del_' .. v.voice_id) then
        s.delete_target       = v
        s.delete_error        = nil
        s.delete_pending_open = true
      end
    end

    reaper.ImGui_EndTable(ctx)
  end

  reaper.ImGui_Spacing(ctx)

  -- Nested popups
  render_rename_popup(ctx)
  render_delete_popup(ctx)
  render_batch_delete_popup(ctx)

  reaper.ImGui_Separator(ctx)
  if theme.button_neutral(ctx, 'Close') then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

return M
