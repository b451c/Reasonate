-- modules/gui/tracks_table.lua
-- Tabela tracków: # · Name · Role · Voice (with [Set] + override ●) · Items.
-- Mutacje (voice/role) idą przez state, nie bezpośrednio do REAPER.
--
-- Zmiana w v2: theme tokens, [Set] text button (Inter nie ma gear/midline-ellipsis glyph'ów),
-- alt-row striping przez Col_TableRowBgAlt z theme.push.
--
-- Phase 11.x redesign: rozszerzalne wiersze (chevron > / v) ujawniają sub-rows
-- per-item z indywidualnymi swatchami koloru. Track swatch wyświetla effective
-- color (uniform → that color, mixed/empty → transparent). Klik track swatch =
-- bulk apply do wszystkich itemów; klik item swatch = single item.

local colors                = require 'modules.colors'
local voice_picker          = require 'modules.gui.voice_picker'
local voice_settings_dialog = require 'modules.gui.voice_settings_dialog'
local helpers               = require 'modules.reaper_helpers'
local theme                 = require 'modules.theme'
local recording             = require 'modules.recording'
local util                  = require 'modules.util'

local M = {}

-- Ephemeral expand state — track_guid → bool. Reload kontekstu = wszystko collapsed.
-- Per CLAUDE.md "Simplicity First" — UI state cosmetic, NIE persistujemy w P_EXT.
local expanded = {}

local TABLE_FLAGS

local function table_flags()
  if TABLE_FLAGS then return TABLE_FLAGS end
  TABLE_FLAGS = reaper.ImGui_TableFlags_RowBg()
              | reaper.ImGui_TableFlags_BordersInnerH()
              | reaper.ImGui_TableFlags_Resizable()
              | reaper.ImGui_TableFlags_SizingStretchProp()
              | reaper.ImGui_TableFlags_PadOuterX()
  return TABLE_FLAGS
end

local UNASSIGNED_LABEL = 'Pick voice…'

-- T8 (UX-POLISH): stan filtra ról/search (panel-local UI state — nie
-- persystowany; filtr to widok, nie dane projektu).
local flt = { role = nil, text = '' }
local STATUS_ORDER = { 'new', 'in_progress', 'converted', 'stale', 'error', 'output', 'skipped' }

----------------------------------------------------------------------------
-- Items breakdown w cell (np. "12 · ●3 ●2") — kompaktowe per-track stats
----------------------------------------------------------------------------
local function render_items_breakdown(ctx, counts)
  reaper.ImGui_Text(ctx, ('%d'):format(counts.total_audio))
  for _, st in ipairs(STATUS_ORDER) do
    local n = counts[st] or 0
    if n > 0 then
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
      reaper.ImGui_TextColored(ctx, colors.PALETTE[st].rgba,
        ('●%d'):format(n))
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, ('%d %s'):format(n, colors.PALETTE[st].label))
      end
    end
  end
end

----------------------------------------------------------------------------
-- Format duration (h:mm:ss / m:ss / Ns)
----------------------------------------------------------------------------
local function format_len(secs)
  if not secs or secs < 0 then return '?' end
  if secs < 60 then return ('%.1fs'):format(secs) end
  local m = math.floor(secs / 60)
  local s = math.floor(secs % 60)  -- Lua 5.4: %d wymaga integer, NOT float
  return ('%d:%02d'):format(m, s)
end

local function format_timer(secs)
  if not secs or secs < 0 then return '0:00' end
  local m = math.floor(secs / 60)
  local s = math.floor(secs % 60)
  return ('%d:%02d'):format(m, s)
end

----------------------------------------------------------------------------
-- VU + timer cell (zastępuje items breakdown gdy track recording).
-- - Pre-roll: countdown "Starts in 3..."
-- - Recording: VU bar (level dB) + timer
----------------------------------------------------------------------------
local function render_recording_meter(ctx, track_guid)
  if recording.is_pre_roll() then
    local r = recording.pre_roll_remaining()
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xF59E0BFF)
    reaper.ImGui_Text(ctx, ('Starts in %.1fs'):format(r))
    reaper.ImGui_PopStyleColor(ctx, 1)
    return
  end

  -- VU bar — read peak co frame, map -60..0 dB → 0..1.
  -- Color: green < -12 dB, yellow -12..-6, red > -6 (clipping risk).
  local db = recording.target_track_peak_db(0)
  local fraction = math.max(0, math.min(1, (db + 60) / 60))
  local bar_color
  if db > -6 then
    bar_color = 0xDC1414FF       -- red (clip warn)
  elseif db > -12 then
    bar_color = 0xEAB308FF       -- yellow
  else
    bar_color = 0x22C55EFF       -- green
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PlotHistogram(), bar_color)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x000000AA)
  reaper.ImGui_ProgressBar(ctx, fraction, 90, 12, '')
  reaper.ImGui_PopStyleColor(ctx, 2)

  -- Timer — red text obok VU bar
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xDC1414FF)
  reaper.ImGui_Text(ctx, format_timer(recording.elapsed_secs()))
  reaper.ImGui_PopStyleColor(ctx, 1)
end

----------------------------------------------------------------------------
-- Render sub-row dla pojedynczego itema (gdy track expanded).
-- ctx_args: { sel_item, sel_item_track_guid }
-- Returns: out — { color_open_item_guid? }
----------------------------------------------------------------------------
local function render_item_subrow(ctx, item, track_guid, ctx_args)
  local out = {}
  if not helpers.is_audio_item(item) then return out end

  reaper.ImGui_TableNextRow(ctx)
  local item_guid = helpers.item_guid(item)
  local take = reaper.GetActiveTake(item)
  local take_name = ''
  if take then
    local _
    _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
  end
  if take_name == '' then take_name = '(unnamed)' end
  local len      = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local status   = helpers.get_item_status(item)
  local native   = math.floor(reaper.GetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR'))
  local has_user_flag = helpers.get_item_user_color_flag(item)

  -- Persistent selection state — sub-row highlights gdy jego item == current
  -- REAPER selection (sel_item from ctx_args). Match przeżywa loss of focus.
  local is_selected = ctx_args and ctx_args.sel_item == item

  -- Selected row tint (amber) — bg color via TableSetBgColor; spójne z parent
  -- track row selection look (Idea 3 / Big Session #2). Brak selected = subtle
  -- domyślny tint.
  if is_selected then
    reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg0(),
      0xF59E0B33, -1)
  else
    reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg0(),
      0xFFFFFF08, -1)
  end

  -- Col 1: indent + item swatch + take name
  reaper.ImGui_TableNextColumn(ctx)

  -- Whole-row Selectable as click target (load item into Audition). Rendered
  -- FIRST z SpanAllColumns + AllowOverlap → subsequent widgets (swatch button)
  -- zachowują własne hit regions. Empty label = invisible (only hover tint).
  -- size_h = full frame height żeby hover/selected highlight pokrywał całą
  -- wysokość row'a (default 0 = font line height = za mały).
  local sel_flags = reaper.ImGui_SelectableFlags_SpanAllColumns()
                  | reaper.ImGui_SelectableFlags_AllowOverlap()
  local row_h = reaper.ImGui_GetFrameHeight(ctx)
  if reaper.ImGui_Selectable(ctx, '##audi_sub_' .. item_guid, is_selected, sel_flags, 0, row_h) then
    out.audition_item_guid = item_guid
    out.audition_track_guid = track_guid
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Click to load this item into Audition')
  end
  reaper.ImGui_SameLine(ctx, 0, 0)

  reaper.ImGui_Dummy(ctx, 32, 0)         -- left indent (≈ chevron + index width)
  reaper.ImGui_SameLine(ctx, 0, 0)
  local SWATCH_SZ = 14
  -- Center vertically — swatch (14) jest mniejszy niż frame height (~28),
  -- bez offsetu siedzi przy górze. Push CursorPosY w dół o połowę różnicy.
  local fh = reaper.ImGui_GetFrameHeight(ctx)
  local v_offset = math.max(0, math.floor((fh - SWATCH_SZ) / 2))
  if v_offset > 0 then
    reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + v_offset)
  end
  local rgba = (native ~= 0)
    and (colors.native_to_rgba(native) or 0x80808088)
    or  0x00000000
  local cb_flags = reaper.ImGui_ColorEditFlags_NoTooltip()
                 | reaper.ImGui_ColorEditFlags_NoBorder()
  if reaper.ImGui_ColorButton(ctx, '##icol_' .. item_guid, rgba,
      cb_flags, SWATCH_SZ, SWATCH_SZ) then
    out.color_open_item_guid = item_guid
    out.color_open_item_track_guid = track_guid
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, has_user_flag
      and 'Item color (user override) · click to change'
      or  'Item color (auto status) · click to override')
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, take_name)

  -- Col 2: length (right-aligned via TextDisabled)
  reaper.ImGui_TableNextColumn(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextDisabled(ctx, format_len(len))

  -- Col 3: empty placeholder (voice column unused for sub-row)
  reaper.ImGui_TableNextColumn(ctx)

  -- Col 4: status badge (kropka kolor + nazwa)
  reaper.ImGui_TableNextColumn(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  local p = colors.PALETTE[status]
  if p then
    reaper.ImGui_TextColored(ctx, p.rgba, '●')
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    reaper.ImGui_TextDisabled(ctx, p.label)
    if has_user_flag then
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
      reaper.ImGui_TextDisabled(ctx, '(custom)')
    end
  else
    reaper.ImGui_TextDisabled(ctx, status or '?')
  end

  return out
end

----------------------------------------------------------------------------
-- Render single track row + sub-rows jeśli expanded.
-- ctx_args: { sel_item, sel_item_track_guid }
-- Returns: { audition_track_guid?, repair_track_guid?, repair_item?,
--           color_open_track_guid?, color_open_item_guid?,
--           color_open_item_track_guid? }
----------------------------------------------------------------------------
local function render_row(ctx, state, track, ctx_args)
  local out = {}
  reaper.ImGui_TableNextRow(ctx)

  local tr_obj = helpers.find_track_by_guid(track.guid)
  local is_selected = tr_obj and reaper.IsTrackSelected(tr_obj) or false
  local has_override = tr_obj and helpers.get_track_voice_settings(tr_obj) ~= nil
  local has_isolate  = tr_obj and helpers.get_track_isolate_flag(tr_obj) or false
  local item_on_this_track = ctx_args.sel_item_track_guid == track.guid
  local is_rec_target = recording.is_active() and recording.target_guid() == track.guid

  -- Row tint priority: recording (pulsing red) > selected (amber)
  if is_rec_target then
    -- Pulsująca alpha (0x20..0x60) z sin wave dla "live recording" feel
    local pulse = (math.sin(util.now() * 6) + 1) * 0.5
    local alpha = math.floor(0x30 + pulse * 0x40)
    reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg0(),
      (0xDC << 24) | (0x14 << 16) | (0x14 << 8) | alpha, -1)
  elseif is_selected then
    reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg0(),
      0xF59E0B22, -1)
  end

  -- Col 1: chevron + index Selectable + items color swatch + name + [-> Role]
  reaper.ImGui_TableNextColumn(ctx)

  -- Folder indent: child tracks (inside REAPER folder) get leading dummy.
  -- 14px per nesting level — wystarczająco dla wizualnej hierarchii bez
  -- ścieśniania col 1 zawartości.
  local indent_level = track.folder_indent or 0
  if indent_level > 0 then
    reaper.ImGui_Dummy(ctx, indent_level * 14, 0)
    reaper.ImGui_SameLine(ctx, 0, 0)
  end

  -- Chevron expand toggle. Disabled gdy 0 audio items.
  -- Tight FramePadding — domyślny 10px horizontal squeezuje wąski button.
  local can_expand = (track.audio_count or 0) > 0
  local is_expanded = can_expand and expanded[track.guid] == true
  local chevron = is_expanded and 'v' or '>'
  reaper.ImGui_BeginDisabled(ctx, not can_expand)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 4, 6)
  if theme.button_ghost(ctx, chevron .. '##exp_' .. track.guid, 22, 0) then
    expanded[track.guid] = not is_expanded
  end
  reaper.ImGui_PopStyleVar(ctx, 1)
  if reaper.ImGui_IsItemHovered(ctx) and can_expand then
    reaper.ImGui_SetTooltip(ctx, is_expanded and 'Collapse items' or 'Expand items')
  end
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)

  -- Track index "1"/"2" jako Selectable click target.
  if reaper.ImGui_Selectable(ctx, ('%d##audi_%s'):format(track.index, track.guid),
      is_selected, 0, 24, 0) then
    out.audition_track_guid = track.guid
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Click to load this track into Audition')
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)

  -- T1 (UX-POLISH): wiersz outputu ([AI]) dostaje dim → — wizualna
  -- hierarchia "ten track należy do źródła" także w layoucie flat (bez
  -- folder indentu). '→' U+2192 = zweryfikowany glyph Inter (KNOWN-ISSUES
  -- safe-list; '↳' U+21B3 NIE jest zweryfikowany — nie ryzykujemy '?').
  if track.is_output_track then
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_TextDisabled(ctx, '\xe2\x86\x92')   -- → U+2192
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
  end

  -- Items color swatch — wyświetla effective color (uniform across audio items).
  -- Mixed lub no-color → transparent. Klik = bulk apply do wszystkich items.
  local SWATCH_SZ = 14
  local effective = track.effective_color or 0
  local swatch_rgba
  if effective ~= 0 then
    swatch_rgba = colors.native_to_rgba(effective) or 0x80808088
  else
    swatch_rgba = 0x00000000
  end
  local cb_flags = reaper.ImGui_ColorEditFlags_NoTooltip()
                 | reaper.ImGui_ColorEditFlags_NoBorder()
  -- Center vertically (same as sub-row)
  local row_fh = reaper.ImGui_GetFrameHeight(ctx)
  local v_off  = math.max(0, math.floor((row_fh - SWATCH_SZ) / 2))
  if v_off > 0 then
    reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + v_off)
  end
  if reaper.ImGui_ColorButton(ctx, '##color_' .. track.guid, swatch_rgba,
      cb_flags, SWATCH_SZ, SWATCH_SZ) then
    out.color_open_track_guid = track.guid
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    local n = track.audio_count or 0
    local tip
    if n == 0 then
      tip = 'No audio items on track'
    elseif track.color_uniform and effective ~= 0 then
      tip = ('All %d items same color · click to change all'):format(n)
    elseif track.color_uniform then
      tip = ('%d items · click to set color for all'):format(n)
    else
      tip = ('%d items · mixed colors · click to set all to one color'):format(n)
    end
    reaper.ImGui_SetTooltip(ctx, tip)
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)

  local name_value = track.name or ''
  reaper.ImGui_SetNextItemWidth(ctx, -38)
  local nv, new_name = reaper.ImGui_InputText(ctx,
    '##name_' .. track.guid, name_value)
  if nv and new_name ~= name_value then
    state.set_name(track.guid, new_name)
  end

  -- Copy track name → role. Ukryty dla outputów (rola nie ma tam sensu).
  if not track.is_output_track then
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    if theme.button_ghost(ctx, '->##copy_role_' .. track.guid, 32, 0) then
      state.set_role(track.guid, name_value)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, 'Copy track name to role (overwrites current role)')
    end
  end

  -- Col 2: Role (editable; output track → dim etykieta zamiast pola)
  reaper.ImGui_TableNextColumn(ctx)
  if track.is_output_track then
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_TextDisabled(ctx, 'AI takes')
  else
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local role_value = track.role or ''
    local rv, new_role = reaper.ImGui_InputText(ctx,
      '##role_' .. track.guid, role_value)
    if rv and new_role ~= role_value then
      state.set_role(track.guid, new_role)
    end
  end

  -- Col 3: Voice cell — W3 UI/UX redesign (2026-06-10, user-approved wariant
  -- "pełna nazwa + menu ⋯"). Voice button na całą szerokość kolumny (pełne
  -- nazwy głosów), akcje (settings / record / Voice Isolator / clear) w popup
  -- menu pod ⋯. Wskaźniki override/isolate = kropki DrawList na prawej
  -- krawędzi przycisku (nie zabierają miejsca, nie łapią kliknięć). Podczas
  -- nagrywania na tym tracku slot ⋯ zamienia się w bezpośredni ■ stop —
  -- zatrzymanie nagrania musi zostać na 1 klik.
  reaper.ImGui_TableNextColumn(ctx)

  -- T1 (UX-POLISH): output track ([AI]) = read-only wiersz. Zamiast
  -- "Pick voice…" (sugerował konwersję już skonwertowanego głosu) — dim
  -- opis przynależności do źródła. Bez menu ⋯ / record (akcje per-take
  -- żyją w sub-rows + Audition). Kolumna Items renderuje się normalnie.
  if track.is_output_track then
    reaper.ImGui_AlignTextToFramePadding(ctx)
    local src = (track.output_of and track.output_of ~= '')
      and track.output_of or 'source track'
    reaper.ImGui_TextDisabled(ctx, ('AI output of "%s"'):format(src))
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        ('Converted takes for "%s" land here.\nVoice is chosen on the source track — expand the row (>) to audition takes.')
          :format(src))
    end
    -- Col 4: Items breakdown (mirror ścieżki poniżej)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    if track.counts then
      render_items_breakdown(ctx, track.counts)
    else
      reaper.ImGui_Text(ctx, tostring(track.item_count))
    end
    if is_expanded and tr_obj then
      for it in helpers.iter_track_items(tr_obj) do
        local sub_out = render_item_subrow(ctx, it, track.guid, ctx_args)
        if sub_out and sub_out.color_open_item_guid then
          out.color_open_item_guid = sub_out.color_open_item_guid
          out.color_open_item_track_guid = sub_out.color_open_item_track_guid
        end
        if sub_out and sub_out.audition_item_guid then
          out.audition_item_guid  = sub_out.audition_item_guid
          out.audition_track_guid = sub_out.audition_track_guid
        end
      end
    end
    return out
  end

  local has_voice = track.voice_id ~= nil
  local current_label = track.voice_name or UNASSIGNED_LABEL

  local voice_btn_w = -36   -- full width minus ⋯ slot
  local open_picker
  if has_voice then
    open_picker = reaper.ImGui_Button(ctx,
      current_label .. '##voice_' .. track.guid, voice_btn_w, 0)
  else
    open_picker = theme.button_ghost(ctx,
      current_label .. '##voice_' .. track.guid, voice_btn_w, 0)
  end
  if open_picker then
    voice_picker.open({
      state            = state,
      track_guid       = track.guid,
      current_voice_id = track.voice_id,
    })
  end

  local show_override_dot = has_voice and has_override
  if has_isolate or show_override_dot then
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local _, min_y = reaper.ImGui_GetItemRectMin(ctx)
    local max_x, max_y = reaper.ImGui_GetItemRectMax(ctx)
    local dot_y = (min_y + max_y) / 2
    local dot_x = max_x - 10
    if has_isolate then
      reaper.ImGui_DrawList_AddCircleFilled(dl, dot_x, dot_y, 3, 0x67E8F9FF)
      dot_x = dot_x - 10
    end
    if show_override_dot then
      reaper.ImGui_DrawList_AddCircleFilled(dl, dot_x, dot_y, 3, theme.COLORS.override)
    end
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    local tip = has_voice
      and ('Click to change voice · ID: ' .. track.voice_id)
      or  'Pick a voice for this track'
    if show_override_dot then tip = tip .. '\n● Custom voice settings active' end
    if has_isolate then tip = tip .. '\n● Voice Isolator: ON' end
    reaper.ImGui_SetTooltip(ctx, tip)
  end

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 4, 6)
  if is_rec_target then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xDC1414FF)
    if theme.button_ghost(ctx, '\xe2\x96\xa0##stop_' .. track.guid, 28, 0) then
      out.record_stop = true
    end
    reaper.ImGui_PopStyleColor(ctx, 1)
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, 'Stop recording')
    end
  else
    -- '…' (U+2026) zamiast '⋯' (U+22EF) — Inter nie ma U+22EF → '?' (2026-06-11)
    if theme.button_ghost(ctx, '…##vmenu_' .. track.guid, 28, 0) then
      reaper.ImGui_OpenPopup(ctx, 'voice_menu_' .. track.guid)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, 'Track actions: voice settings · record · Voice Isolator')
    end
  end
  reaper.ImGui_PopStyleVar(ctx, 1)

  if reaper.ImGui_BeginPopup(ctx, 'voice_menu_' .. track.guid) then
    reaper.ImGui_BeginDisabled(ctx, not has_voice)
    local vs_label = has_override and 'Voice settings... (override active)' or 'Voice settings...'
    if reaper.ImGui_Selectable(ctx, vs_label, false) then
      voice_settings_dialog.open({
        state      = state,
        track_guid = track.guid,
        track_name = track.name,
        voice_name = track.voice_name,
      })
    end
    reaper.ImGui_EndDisabled(ctx)

    local other_recording = recording.is_active() and not is_rec_target
    reaper.ImGui_BeginDisabled(ctx, other_recording)
    if reaper.ImGui_Selectable(ctx, '\xe2\x97\x8f Record new take', false) then
      out.record_start_track_guid = track.guid
    end
    reaper.ImGui_EndDisabled(ctx)

    -- Voice Isolator toggle — checkmark odzwierciedla flagę (ten sam toggle
    -- żyje też w voice_settings_dialog; tu szybki dostęp bez modala).
    if tr_obj then
      if reaper.ImGui_MenuItem(ctx, 'Voice Isolator (clean audio)', nil, has_isolate) then
        helpers.set_track_isolate_flag(tr_obj, not has_isolate)
      end
    end

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_BeginDisabled(ctx, not has_voice)
    if reaper.ImGui_Selectable(ctx, 'Clear voice', false) then
      state.clear_voice(track.guid)
    end
    reaper.ImGui_EndDisabled(ctx)
    reaper.ImGui_EndPopup(ctx)
  end

  -- Col 4: Items breakdown LUB VU+timer (gdy recording na tym tracku)
  reaper.ImGui_TableNextColumn(ctx)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  if is_rec_target then
    render_recording_meter(ctx, track.guid)
  elseif track.counts then
    render_items_breakdown(ctx, track.counts)
  else
    reaper.ImGui_Text(ctx, tostring(track.item_count))
  end

  -- Sub-rows (expanded). Iterujemy items na track per-frame — items mogą się
  -- zmieniać między klatkami (delete/add w REAPER), trzymamy live source.
  if is_expanded and tr_obj then
    for it in helpers.iter_track_items(tr_obj) do
      local sub_out = render_item_subrow(ctx, it, track.guid, ctx_args)
      if sub_out and sub_out.color_open_item_guid then
        out.color_open_item_guid = sub_out.color_open_item_guid
        out.color_open_item_track_guid = sub_out.color_open_item_track_guid
      end
      if sub_out and sub_out.audition_item_guid then
        out.audition_item_guid  = sub_out.audition_item_guid
        out.audition_track_guid = sub_out.audition_track_guid
      end
    end
  end

  return out
end

----------------------------------------------------------------------------
-- Public render
----------------------------------------------------------------------------
function M.render(ctx, state)
  local out = {
    audition_track_guid = nil,
    audition_item_guid  = nil,        -- gdy sub-row click → load specific item
    repair_track_guid   = nil,
    repair_item         = nil,
    color_open_track_guid       = nil,
    color_open_item_guid        = nil,
    color_open_item_track_guid  = nil,
    record_start_track_guid     = nil,
    record_stop                 = false,
  }
  if #state.tracks == 0 then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_TextDisabled(ctx,
      'No tracks in project. Add a track and reopen, or wait — auto-rescan every 500 ms.')
    return out
  end

  local sel_item_n = reaper.CountSelectedMediaItems(0)
  local sel_item   = sel_item_n == 1 and reaper.GetSelectedMediaItem(0, 0) or nil
  local sel_item_track_guid = nil
  if sel_item then
    local tr = reaper.GetMediaItemTrack(sel_item)
    if tr then sel_item_track_guid = helpers.track_guid(tr) end
  end
  local ctx_args = { sel_item = sel_item, sel_item_track_guid = sel_item_track_guid }

  -- T8 (UX-POLISH, user decision): filtr ról + search dla dużej obsady
  -- (audiobook: 1 aktor → wiele ról na wielu trackach). Chipy ról z
  -- licznikami (wzorzec filtra statusów w Dubbingu) + search po nazwie/
  -- roli/głosie. Pasek widoczny gdy ≥2 role lub ≥6 tracków źródłowych —
  -- małe projekty bez szumu. Wiersz [AI] podąża za widocznością source'a.
  local buckets, order, n_src = {}, {}, 0
  for _, t in ipairs(state.tracks) do
    if not t.is_output_track then
      n_src = n_src + 1
      local b = (t.role and t.role ~= '') and t.role or '(no role)'
      if not buckets[b] then
        buckets[b] = 0
        order[#order + 1] = b
      end
      buckets[b] = buckets[b] + 1
    end
  end
  local show_bar = (#order >= 2) or (n_src >= 6)
  if not show_bar then
    flt.role, flt.text = nil, ''
  else
    reaper.ImGui_AlignTextToFramePadding(ctx)
    theme.push_caption(ctx)
    reaper.ImGui_TextDisabled(ctx, 'Search:')
    theme.pop_caption(ctx)
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    reaper.ImGui_SetNextItemWidth(ctx, 180)
    local rv_f, new_f = reaper.ImGui_InputText(ctx, '##vr_flt_search', flt.text or '')
    if rv_f then flt.text = new_f end
    if (flt.text or '') ~= '' then
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
      if theme.button_ghost(ctx, '×##vr_flt_clear', 0, 0) then flt.text = '' end
    end
    local function chip(label, count, role_key)
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
      local active = (flt.role == role_key)
      if active then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), theme.COLORS.primary)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),   theme.COLORS.text_on_amber)
      end
      if reaper.ImGui_SmallButton(ctx,
           ('%s · %d##vr_chip_%s'):format(label, count, label)) then
        flt.role = active and nil or role_key
      end
      if active then reaper.ImGui_PopStyleColor(ctx, 2) end
    end
    chip('All', n_src, nil)
    -- 'All' toggle: klik gdy nic nie wybrane = no-op (role_key nil)
    for _, b in ipairs(order) do chip(b, buckets[b], b) end
    reaper.ImGui_Spacing(ctx)
  end
  local needle = (flt.text or ''):lower()
  local function src_passes(t)
    if flt.role and ((t.role and t.role ~= '') and t.role or '(no role)') ~= flt.role then
      return false
    end
    if needle ~= '' then
      local hay = ((t.name or '') .. ' ' .. (t.role or '') .. ' '
                   .. (t.voice_name or '')):lower()
      if not hay:find(needle, 1, true) then return false end
    end
    return true
  end
  local visible_src, any_hidden = {}, false
  for _, t in ipairs(state.tracks) do
    if not t.is_output_track then
      visible_src[t.guid] = src_passes(t)
      if not visible_src[t.guid] then any_hidden = true end
    end
  end

  if reaper.ImGui_BeginTable(ctx, 'tracks_table', 4, table_flags()) then
    reaper.ImGui_TableSetupColumn(ctx, 'Track',
      reaper.ImGui_TableColumnFlags_WidthStretch(), 3)
    reaper.ImGui_TableSetupColumn(ctx, 'Role',
      reaper.ImGui_TableColumnFlags_WidthStretch(), 2)
    reaper.ImGui_TableSetupColumn(ctx, 'Voice',
      reaper.ImGui_TableColumnFlags_WidthStretch(), 4)
    reaper.ImGui_TableSetupColumn(ctx, 'Items',
      reaper.ImGui_TableColumnFlags_WidthStretch(), 2)
    reaper.ImGui_TableHeadersRow(ctx)

    for _, track in ipairs(state.tracks) do
      -- T8: filtr — output podąża za source'em; source wg chipa+search.
      local row_visible = track.is_output_track
        and (visible_src[track.output_src_guid] ~= false)
        or  visible_src[track.guid]
      local row_out = row_visible and render_row(ctx, state, track, ctx_args) or nil
      if row_out then
        if row_out.audition_track_guid then
          out.audition_track_guid = row_out.audition_track_guid
        end
        if row_out.audition_item_guid then
          out.audition_item_guid = row_out.audition_item_guid
        end
        if row_out.repair_track_guid then
          out.repair_track_guid = row_out.repair_track_guid
          out.repair_item       = row_out.repair_item
        end
        if row_out.color_open_track_guid then
          out.color_open_track_guid = row_out.color_open_track_guid
        end
        if row_out.color_open_item_guid then
          out.color_open_item_guid       = row_out.color_open_item_guid
          out.color_open_item_track_guid = row_out.color_open_item_track_guid
        end
        if row_out.record_start_track_guid then
          out.record_start_track_guid = row_out.record_start_track_guid
        end
        if row_out.record_stop then
          out.record_stop = true
        end
      end
    end

    reaper.ImGui_EndTable(ctx)
  end

  -- T8: uczciwa informacja, że filtr coś chowa (żaden wiersz nie znika
  -- "po cichu").
  if any_hidden then
    theme.push_caption(ctx)
    local n_vis = 0
    for _, v in pairs(visible_src) do if v then n_vis = n_vis + 1 end end
    reaper.ImGui_TextDisabled(ctx,
      ('Filter: showing %d of %d tracks — click the active chip or clear search to show all.')
        :format(n_vis, n_src))
    theme.pop_caption(ctx)
  end
  return out
end

return M
