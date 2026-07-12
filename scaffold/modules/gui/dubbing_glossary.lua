-- modules/gui/dubbing_glossary.lua
-- NS-B M1 Part 2 — glossary modal (characters / terms / do-not-translate).
--
-- Per spec §13.3 — CRUD per row. On Save: caller flags translations stale
-- (zmiana glossary = zmiana LLM system prompt = stale translations).
--
-- W2 M1 UX rework (2026-06-11, user-approved wariant "tabele"):
-- - sekcje jako BeginTable z nagłówkami kolumn (etykiety raz, nie wiszące
--   po prawej każdego pola),
-- - plain-language hint + przykład per sekcja (user feedback: stary opis
--   był żargonem — "persona context"/"verbatim"),
-- - Enter w polach add-row dodaje wpis (mirror + Add),
-- - Save bez faktycznych zmian → action 'save_nochange' (caller NIE staluje
--   tłumaczeń; porównanie przez dubbing_project.glossary_hash),
-- - X/Esc resetuje s.open (wcześniej flaga wisiała → martwe render cally).

local theme = require 'modules.theme'
local dub_project = require 'modules.dubbing_project'

local M = {}

local s = {
  open                = false,
  pending_open        = false,
  -- Edit buffers (deep clone z project.glossary; commit na Save)
  characters          = {},
  terms               = {},
  dnt                 = {},
  -- Add buffers
  new_char_name       = '',
  new_char_style      = '',
  new_term_source     = '',
  new_term_target     = '',
  new_dnt_word        = '',
  -- W2 M1: hash przy otwarciu — Save bez zmian = no-op
  hash_on_open        = '',
}

local function clone_glossary(project)
  s.characters = {}
  s.terms      = {}
  s.dnt        = {}
  if not project or not project.glossary then return end
  for _, c in ipairs(project.glossary.characters or {}) do
    s.characters[#s.characters + 1] = {
      name           = c.name or '',
      speaking_style = c.speaking_style or '',
      preserve_name  = c.preserve_name == true,
    }
  end
  for _, t in ipairs(project.glossary.terms or {}) do
    s.terms[#s.terms + 1] = {
      source      = t.source or '',
      target      = t.target or '',
      consistency = t.consistency or 'normal',
    }
  end
  for _, w in ipairs(project.glossary.do_not_translate or {}) do
    s.dnt[#s.dnt + 1] = w
  end
end

local function commit_glossary(project)
  if not project then return end
  project.glossary = project.glossary or {}
  project.glossary.characters = {}
  project.glossary.terms      = {}
  project.glossary.do_not_translate = {}
  for _, c in ipairs(s.characters) do
    if c.name and c.name ~= '' then
      project.glossary.characters[#project.glossary.characters + 1] = {
        name           = c.name,
        speaking_style = c.speaking_style,
        preserve_name  = c.preserve_name == true,
      }
    end
  end
  for _, t in ipairs(s.terms) do
    if t.source and t.source ~= '' and t.target and t.target ~= '' then
      project.glossary.terms[#project.glossary.terms + 1] = {
        source      = t.source,
        target      = t.target,
        consistency = t.consistency or 'normal',
      }
    end
  end
  for _, w in ipairs(s.dnt) do
    if w and w ~= '' then
      project.glossary.do_not_translate[#project.glossary.do_not_translate + 1] = w
    end
  end
end

local function try_add_char()
  if s.new_char_name == '' then return end
  s.characters[#s.characters + 1] = {
    name           = s.new_char_name,
    speaking_style = s.new_char_style,
    preserve_name  = false,
  }
  s.new_char_name  = ''
  s.new_char_style = ''
end

local function try_add_term()
  if s.new_term_source == '' or s.new_term_target == '' then return end
  s.terms[#s.terms + 1] = {
    source      = s.new_term_source,
    target      = s.new_term_target,
    consistency = 'normal',
  }
  s.new_term_source = ''
  s.new_term_target = ''
end

local function try_add_dnt()
  if s.new_dnt_word == '' then return end
  s.dnt[#s.dnt + 1] = s.new_dnt_word
  s.new_dnt_word = ''
end

function M.open(project)
  clone_glossary(project)
  s.new_char_name   = ''
  s.new_char_style  = ''
  s.new_term_source = ''
  s.new_term_target = ''
  s.new_dnt_word    = ''
  s.hash_on_open    = dub_project.glossary_hash(project)
  s.open            = true
  s.pending_open    = true
end

function M.is_open() return s.open end

local function section_hint(ctx, text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx, text)
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)
end

function M.render(ctx, state, mode_module, deps)
  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, 'Translation glossary')
    s.pending_open = false
  end

  theme.center_next_modal(ctx, 680, 540)
  theme.popup_keep_top(ctx, 'Translation glossary')
  local visible = reaper.ImGui_BeginPopupModal(ctx, 'Translation glossary', true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then
    -- X/Esc auto-close — reset flagi (edits discarded, mirror Cancel).
    s.open = false
    return nil
  end

  -- Enter w add-row = + Add (progressive enhancement; przyciski działają zawsze)
  local enter_pressed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'A cheat-sheet for the translator — keeps character voices, key terms and names '
    .. 'consistent across the whole project. Optional: leave it empty when the material '
    .. 'doesn\'t need it.')
  reaper.ImGui_TextWrapped(ctx,
    'Saving changes marks existing translations as stale — re-run Translate all '
    .. '(unchanged lines come back free from cache).')
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)

  -- Sekcje w scrollowanym childzie; przyciski przypięte na dole (-44 =
  -- miejsce na separator + action row; likwiduje martwą przestrzeń).
  if reaper.ImGui_BeginChild(ctx, 'glossary_body', 0, -44) then

    -- Characters ------------------------------------------------------------
    if reaper.ImGui_CollapsingHeader(ctx, ('Characters (%d)###gl_chars'):format(#s.characters),
        nil, reaper.ImGui_TreeNodeFlags_DefaultOpen()) then
      reaper.ImGui_Indent(ctx, 12)
      section_hint(ctx,
        'Who speaks how — e.g. "Janek: gruff detective, short sentences". '
        .. 'The translator keeps each voice in character.')
      if reaper.ImGui_BeginTable(ctx, 'gl_chars_tbl', 4,
          reaper.ImGui_TableFlags_BordersInnerH()) then
        reaper.ImGui_TableSetupColumn(ctx, 'Name', reaper.ImGui_TableColumnFlags_WidthFixed(), 140)
        reaper.ImGui_TableSetupColumn(ctx, 'Description', reaper.ImGui_TableColumnFlags_WidthStretch())
        reaper.ImGui_TableSetupColumn(ctx, 'Keep name', reaper.ImGui_TableColumnFlags_WidthFixed(), 78)
        reaper.ImGui_TableSetupColumn(ctx, '##del', reaper.ImGui_TableColumnFlags_WidthFixed(), 52)
        reaper.ImGui_TableHeadersRow(ctx)

        for i, c in ipairs(s.characters) do
          reaper.ImGui_PushID(ctx, 'char_' .. i)
          reaper.ImGui_TableNextRow(ctx)
          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_SetNextItemWidth(ctx, -1)
          local rv_n, new_n = reaper.ImGui_InputText(ctx, '##name', c.name)
          if rv_n then c.name = new_n end
          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_SetNextItemWidth(ctx, -1)
          local rv_st, new_st = reaper.ImGui_InputText(ctx, '##desc', c.speaking_style)
          if rv_st then c.speaking_style = new_st end
          reaper.ImGui_TableNextColumn(ctx)
          local rv_pn, new_pn = reaper.ImGui_Checkbox(ctx, '##keep', c.preserve_name)
          if rv_pn then c.preserve_name = new_pn end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx,
              'Never translate or localize this name — always copied as-is.')
          end
          reaper.ImGui_TableNextColumn(ctx)
          if reaper.ImGui_SmallButton(ctx, 'x') then
            table.remove(s.characters, i)
            reaper.ImGui_PopID(ctx)
            break
          end
          reaper.ImGui_PopID(ctx)
        end

        -- Add row
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, -1)
        local rv_an, new_an = reaper.ImGui_InputText(ctx, '##new_char_name', s.new_char_name)
        if rv_an then s.new_char_name = new_an end
        if enter_pressed and reaper.ImGui_IsItemFocused(ctx) then try_add_char() end
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, -1)
        local rv_as, new_as = reaper.ImGui_InputText(ctx, '##new_char_desc', s.new_char_style)
        if rv_as then s.new_char_style = new_as end
        if enter_pressed and reaper.ImGui_IsItemFocused(ctx) then try_add_char() end
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_BeginDisabled(ctx, s.new_char_name == '')
        if reaper.ImGui_SmallButton(ctx, '+ Add##add_char') then try_add_char() end
        reaper.ImGui_EndDisabled(ctx)

        reaper.ImGui_EndTable(ctx)
      end
      reaper.ImGui_Unindent(ctx, 12)
      reaper.ImGui_Spacing(ctx)
    end

    -- Terms -----------------------------------------------------------------
    if reaper.ImGui_CollapsingHeader(ctx, ('Terms (%d)###gl_terms'):format(#s.terms),
        nil, reaper.ImGui_TreeNodeFlags_DefaultOpen()) then
      reaper.ImGui_Indent(ctx, 12)
      section_hint(ctx,
        'Always translate the same way across the whole project — '
        .. 'e.g. "zaklecie" in the source always becomes "spell".')
      if reaper.ImGui_BeginTable(ctx, 'gl_terms_tbl', 4,
          reaper.ImGui_TableFlags_BordersInnerH()) then
        reaper.ImGui_TableSetupColumn(ctx, 'Source word', reaper.ImGui_TableColumnFlags_WidthStretch())
        reaper.ImGui_TableSetupColumn(ctx, 'Translation', reaper.ImGui_TableColumnFlags_WidthStretch())
        reaper.ImGui_TableSetupColumn(ctx, 'Strict', reaper.ImGui_TableColumnFlags_WidthFixed(), 50)
        reaper.ImGui_TableSetupColumn(ctx, '##del', reaper.ImGui_TableColumnFlags_WidthFixed(), 52)
        reaper.ImGui_TableHeadersRow(ctx)

        for i, t in ipairs(s.terms) do
          reaper.ImGui_PushID(ctx, 'term_' .. i)
          reaper.ImGui_TableNextRow(ctx)
          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_SetNextItemWidth(ctx, -1)
          local rv_s, new_s = reaper.ImGui_InputText(ctx, '##src', t.source)
          if rv_s then t.source = new_s end
          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_SetNextItemWidth(ctx, -1)
          local rv_t, new_t = reaper.ImGui_InputText(ctx, '##tgt', t.target)
          if rv_t then t.target = new_t end
          reaper.ImGui_TableNextColumn(ctx)
          local strict = t.consistency == 'strict'
          local rv_c, new_c = reaper.ImGui_Checkbox(ctx, '##strict', strict)
          if rv_c then t.consistency = new_c and 'strict' or 'normal' end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx,
              'Enforce this exact translation everywhere,\n'
              .. 'even where a synonym would read better.')
          end
          reaper.ImGui_TableNextColumn(ctx)
          if reaper.ImGui_SmallButton(ctx, 'x') then
            table.remove(s.terms, i)
            reaper.ImGui_PopID(ctx)
            break
          end
          reaper.ImGui_PopID(ctx)
        end

        -- Add row
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, -1)
        local rv_ns, new_ns = reaper.ImGui_InputText(ctx, '##new_term_src', s.new_term_source)
        if rv_ns then s.new_term_source = new_ns end
        if enter_pressed and reaper.ImGui_IsItemFocused(ctx) then try_add_term() end
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, -1)
        local rv_nt, new_nt = reaper.ImGui_InputText(ctx, '##new_term_tgt', s.new_term_target)
        if rv_nt then s.new_term_target = new_nt end
        if enter_pressed and reaper.ImGui_IsItemFocused(ctx) then try_add_term() end
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_BeginDisabled(ctx, s.new_term_source == '' or s.new_term_target == '')
        if reaper.ImGui_SmallButton(ctx, '+ Add##add_term') then try_add_term() end
        reaper.ImGui_EndDisabled(ctx)

        reaper.ImGui_EndTable(ctx)
      end
      reaper.ImGui_Unindent(ctx, 12)
      reaper.ImGui_Spacing(ctx)
    end

    -- Do not translate -------------------------------------------------------
    if reaper.ImGui_CollapsingHeader(ctx, ('Do not translate (%d)###gl_dnt'):format(#s.dnt),
        nil, reaper.ImGui_TreeNodeFlags_DefaultOpen()) then
      reaper.ImGui_Indent(ctx, 12)
      section_hint(ctx,
        'Words copied as-is into the translation — brand and product names, '
        .. 'e.g. "REAPER".')
      if reaper.ImGui_BeginTable(ctx, 'gl_dnt_tbl', 2,
          reaper.ImGui_TableFlags_BordersInnerH()) then
        reaper.ImGui_TableSetupColumn(ctx, 'Word', reaper.ImGui_TableColumnFlags_WidthFixed(), 240)
        reaper.ImGui_TableSetupColumn(ctx, '##del', reaper.ImGui_TableColumnFlags_WidthStretch())
        reaper.ImGui_TableHeadersRow(ctx)

        for i, w in ipairs(s.dnt) do
          reaper.ImGui_PushID(ctx, 'dnt_' .. i)
          reaper.ImGui_TableNextRow(ctx)
          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_SetNextItemWidth(ctx, -1)
          local rv, new = reaper.ImGui_InputText(ctx, '##w', w)
          if rv then s.dnt[i] = new end
          reaper.ImGui_TableNextColumn(ctx)
          if reaper.ImGui_SmallButton(ctx, 'x') then
            table.remove(s.dnt, i)
            reaper.ImGui_PopID(ctx)
            break
          end
          reaper.ImGui_PopID(ctx)
        end

        -- Add row
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, -1)
        local rv_nd, new_nd = reaper.ImGui_InputText(ctx, '##new_dnt', s.new_dnt_word)
        if rv_nd then s.new_dnt_word = new_nd end
        if enter_pressed and reaper.ImGui_IsItemFocused(ctx) then try_add_dnt() end
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_BeginDisabled(ctx, s.new_dnt_word == '')
        if reaper.ImGui_SmallButton(ctx, '+ Add##add_dnt') then try_add_dnt() end
        reaper.ImGui_EndDisabled(ctx)

        reaper.ImGui_EndTable(ctx)
      end
      reaper.ImGui_Unindent(ctx, 12)
    end

    reaper.ImGui_EndChild(ctx)
  end

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  local action = nil
  if theme.button_neutral(ctx, 'Cancel') then
    s.open = false
    reaper.ImGui_CloseCurrentPopup(ctx)
    action = 'cancel'
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if theme.button_primary(ctx, 'Save glossary') then
    local changed = false
    local mode_state = state.modes and state.modes.dubbing
    if mode_state and mode_state.project then
      commit_glossary(mode_state.project)
      -- W2 M1: Save bez faktycznych zmian = no-op (otwarcie + Save z nawyku
      -- NIE staluje tłumaczeń — pre-fix straszyło "marked stale" mimo zera zmian).
      changed = dub_project.glossary_hash(mode_state.project) ~= s.hash_on_open
    end
    s.open = false
    reaper.ImGui_CloseCurrentPopup(ctx)
    action = changed and 'save' or 'save_nochange'
  end

  reaper.ImGui_EndPopup(ctx)
  return action
end

return M
