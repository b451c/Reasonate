-- modules/gui/dubbing_context.lua
-- NS-B Dubbing M2: Translation Context section (collapsible).
--
-- Renders 5 editable dropdowns (tone / era / audience / media_type / honorific)
-- + free-text textarea + glossary launcher. Edits hooked do project.context;
-- any change marks all translations as 'stale' (M2.3 propagation) for active
-- target language because system prompt depends on these fields.
--
-- Per PHASE-NS-B.md §13.1 — context shaped into LLM system prompt via
-- llm.build_system_prompt; changes inwalidate translation memory cache
-- because context_hash() includes all 6 fields.

local theme        = require 'modules.theme'
local dub_project  = require 'modules.dubbing_project'
local cfg          = require 'modules.config'   -- T10: custom styles

local M = {}

-- Per-frame UI state (collapse + buffer for free_text input).
local s = {
  collapsed = true,    -- default collapsed (user feedback PM8 — saves vertical space)
}

----------------------------------------------------------------------------
-- Dropdown options (label = user-facing, value = stored in project.context).
-- Values are stable identifiers wpięte w llm.build_system_prompt.
----------------------------------------------------------------------------
local TONE_OPTIONS = {
  { value = 'neutral',        label = 'Neutral' },
  { value = 'formal',         label = 'Formal' },
  { value = 'informal',       label = 'Informal' },
  { value = 'conversational', label = 'Conversational' },
  { value = 'dramatic',       label = 'Dramatic' },
}

local ERA_OPTIONS = {
  { value = 'modern',     label = 'Modern (contemporary)' },
  { value = 'classical',  label = 'Classical (pre-1900)' },
  { value = 'period',     label = 'Period (specific era)' },
  { value = 'scifi',      label = 'Sci-fi / Future' },
  { value = 'fantasy',    label = 'Fantasy' },
  { value = 'historical', label = 'Historical drama' },
}

local AUDIENCE_OPTIONS = {
  { value = 'kids',         label = 'Kids' },
  { value = 'teen',         label = 'Teen' },
  { value = 'adult',        label = 'Adult' },
  { value = 'mixed',        label = 'Mixed / family' },
  { value = 'professional', label = 'Professional' },
}

local MEDIA_TYPE_OPTIONS = {
  { value = 'drama_film',  label = 'Drama film' },
  { value = 'documentary', label = 'Documentary' },
  { value = 'podcast',     label = 'Podcast' },
  { value = 'animation',   label = 'Animation' },
  { value = 'training',    label = 'Training / corporate' },
  { value = 'commercial',  label = 'Commercial / advert' },
  { value = 'audiobook',   label = 'Audiobook' },
  { value = 'game',        label = 'Video game' },
}

local HONORIFIC_OPTIONS = {
  { value = 'formal',   label = 'Formal (Pan/Pani / Sie / vous)' },
  { value = 'informal', label = 'Informal (Ty / du / tu)' },
  { value = 'mix',      label = 'Mixed (per-character)' },
}

-- Generowane z dubbing_project (single source of truth od 2026-06-10 —
-- presety + labels + kolejność żyją w STYLE_PRESETS/STYLE_PRESET_ORDER).
local STYLE_PRESET_OPTIONS = (function()
  local opts = {}
  for _, key in ipairs(dub_project.STYLE_PRESET_ORDER) do
    opts[#opts + 1] = { value = key, label = dub_project.STYLE_PRESETS[key].label }
  end
  opts[#opts + 1] = { value = 'custom', label = 'Custom (manual fields)' }
  return opts
end)()

local function label_for(options, value)
  -- T10: własne style usera ('saved:<Name>' — snapshot kontekstu z ExtState)
  local saved = type(value) == 'string' and value:match('^saved:(.+)$')
  if saved then return saved .. ' ·custom·' end
  for _, o in ipairs(options) do
    if o.value == value then return o.label end
  end
  return value or '?'
end

----------------------------------------------------------------------------
-- Edit hook: any context change marks translations stale for active lang
-- (M2.3 stale propagation). Also flips style_preset='custom' if user changed
-- a structural field away from its preset value.
----------------------------------------------------------------------------
local function on_context_edited(state, project, mode_module, changed_field)
  mode_module.mark_dirty(state)

  -- Update style_preset → 'custom' if user diverged from current preset baseline.
  -- free_text changes do NOT count as diverging (preset doesn't define it).
  if changed_field and changed_field ~= 'free_text'
     and project.style_preset and project.style_preset ~= 'custom' then
    local preset = dub_project.STYLE_PRESETS[project.style_preset]
    if preset then
      local matches = true
      for _, f in ipairs({ 'tone', 'era', 'audience', 'media_type', 'honorific' }) do
        if project.context[f] ~= preset[f] then matches = false; break end
      end
      if not matches then project.style_preset = 'custom' end
    end
  end

  -- Cascade stale across ALL target languages (context affects every translation).
  -- mode_module.propagate_stale handles translations + dubs + REAPER I_CUSTOMCOLOR.
  if mode_module.propagate_stale then
    mode_module.propagate_stale(state, 'all_langs')
    -- W3 quick win: cascade was silent — user unaware edits invalidated
    -- translations. Idempotent message (free_text edits fire per keystroke).
    local lang = mode_module.active_target_lang and mode_module.active_target_lang(state)
    local n = 0
    if lang then
      for _, seg in ipairs(project.segments or {}) do
        if seg.translation_status and seg.translation_status[lang] == 'stale' then n = n + 1 end
      end
    end
    if n > 0 then
      mode_module.set_status(state,
        ('Context updated — %d %s translation(s) marked stale. Run Translate all to refresh.')
          :format(n, lang:upper()),
        theme.COLORS.status_stale)
    else
      mode_module.set_status(state, 'Context saved.', theme.COLORS.status_done)
    end
  end
end

----------------------------------------------------------------------------
-- Apply style preset → re-fills all 5 fields from preset and clears 'custom'.
-- replace_notes (2026-06-10): brief presetu wchodzi do free_text (widoczny,
-- edytowalny — user-approved). false = user wybrał "keep my text" w confirm.
----------------------------------------------------------------------------
local function apply_style_preset(state, project, mode_module, preset_key, replace_notes)
  if preset_key == 'custom' then
    project.style_preset = 'custom'
    mode_module.mark_dirty(state)
    return
  end
  local preset = dub_project.STYLE_PRESETS[preset_key]
  if not preset then return end
  project.style_preset = preset_key
  project.context.tone       = preset.tone
  project.context.era        = preset.era
  project.context.audience   = preset.audience
  project.context.media_type = preset.media_type
  project.context.honorific  = preset.honorific
  if preset.brief and replace_notes then
    project.context.free_text = preset.brief
  end
  on_context_edited(state, project, mode_module, 'preset')
end

-- T10: własny styl usera = SNAPSHOT kontekstu (5 pól + free_text) zapisany
-- pod nazwą w ExtState (cross-project). Apply przywraca całość — user
-- jawnie wybiera SWÓJ zapis, więc bez confirm (w odróżnieniu od presetów,
-- których brief mógłby nadpisać cudzy tekst).
local function apply_saved_style(state, project, mode_module, name)
  local st = cfg.get_custom_styles('dubbing')[name]
  if not st then return end
  project.style_preset = 'saved:' .. name
  for _, f in ipairs({ 'tone', 'era', 'audience', 'media_type', 'honorific' }) do
    if type(st[f]) == 'string' and st[f] ~= '' then project.context[f] = st[f] end
  end
  if type(st.free_text) == 'string' then
    project.context.free_text = st.free_text
  end
  on_context_edited(state, project, mode_module, 'preset')
end

-- T10: modal zapisu bieżącego kontekstu jako styl (nazwa; template = to,
-- co user właśnie ustawił w sekcji — najlepsza powierzchnia autorska).
local function render_save_style_modal(ctx, state, project, mode_module)
  local ed = s.save_style
  if not ed then return end
  if ed.pending_open then
    reaper.ImGui_OpenPopup(ctx, 'Save context as style')
    ed.pending_open = nil
  end
  theme.center_next_modal(ctx, 460, 0)
  theme.popup_keep_top(ctx, 'Save context as style')
  local visible = reaper.ImGui_BeginPopupModal(ctx, 'Save context as style', true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end
  reaper.ImGui_TextWrapped(ctx,
    'Saves the CURRENT context (style fields + additional notes) under a name — reusable in any project from the Style preset list.')
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local rn, nn = reaper.ImGui_InputText(ctx, '##dubst_name', ed.name or '')
  if rn then ed.name = nn end
  reaper.ImGui_Spacing(ctx)
  local clean = (ed.name or ''):gsub('^%s+', ''):gsub('%s+$', '')
  reaper.ImGui_BeginDisabled(ctx, clean == '')
  if theme.button_primary(ctx, 'Save##dubst_save') then
    cfg.save_custom_style('dubbing', clean, {
      tone       = project.context.tone,
      era        = project.context.era,
      audience   = project.context.audience,
      media_type = project.context.media_type,
      honorific  = project.context.honorific,
      free_text  = project.context.free_text or '',
    })
    project.style_preset = 'saved:' .. clean
    mode_module.mark_dirty(state)
    s.save_style = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if theme.button_neutral(ctx, 'Cancel##dubst_cancel', 0, 0) then
    s.save_style = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndPopup(ctx)
end

----------------------------------------------------------------------------
-- Compact dropdown helper (label + combo on same line).
----------------------------------------------------------------------------
local function render_dropdown(ctx, state, project, mode_module, label_text, options, ctx_field, combo_w)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, label_text)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_SetNextItemWidth(ctx, combo_w or 180)
  local cur = project.context[ctx_field]
  if reaper.ImGui_BeginCombo(ctx, '##ctx_' .. ctx_field, label_for(options, cur)) then
    for _, o in ipairs(options) do
      if reaper.ImGui_Selectable(ctx, o.label, o.value == cur) then
        if project.context[ctx_field] ~= o.value then
          project.context[ctx_field] = o.value
          on_context_edited(state, project, mode_module, ctx_field)
        end
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
end

----------------------------------------------------------------------------
-- Public: render(ctx, state, project, mode_module)
----------------------------------------------------------------------------
function M.render(ctx, state, project, mode_module)
  -- Collapsible header
  local arrow = s.collapsed and '> ' or 'v '
  local preset_summary = ''
  if s.collapsed then
    -- One-line summary when collapsed
    preset_summary = ('   [%s · %s · %s]'):format(
      label_for(STYLE_PRESET_OPTIONS, project.style_preset or 'custom'):sub(1, 20),
      label_for(TONE_OPTIONS, project.context.tone or '?'):sub(1, 12),
      label_for(AUDIENCE_OPTIONS, project.context.audience or '?'):sub(1, 12))
  end
  if reaper.ImGui_Selectable(ctx, arrow .. 'Translation context' .. preset_summary, false) then
    s.collapsed = not s.collapsed
  end
  if s.collapsed then return end

  reaper.ImGui_Indent(ctx, 16)

  -- Style preset selector (top — drives the other 5 fields).
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Style preset:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_SetNextItemWidth(ctx, 240)
  local cur_preset = project.style_preset or 'custom'
  if reaper.ImGui_BeginCombo(ctx, '##ctx_preset', label_for(STYLE_PRESET_OPTIONS, cur_preset)) then
    for _, o in ipairs(STYLE_PRESET_OPTIONS) do
      if reaper.ImGui_Selectable(ctx, o.label, o.value == cur_preset) then
        if o.value ~= cur_preset then
          local p = dub_project.STYLE_PRESETS[o.value]
          -- User-authored free_text → pytaj zanim nadpiszemy briefem presetu
          -- (reaper.MB synchronous — mirror dubbing_inspector unsaved-changes).
          local needs_confirm = o.value ~= 'custom' and p and p.brief
            and not dub_project.is_stock_style_text(project.context.free_text)
          if needs_confirm then
            local choice = reaper.MB(
              'This preset comes with its own style notes for the translator.\n\n'
              .. 'Replace your text in "Additional context" with the preset notes?\n\n'
              .. 'Yes — replace with preset notes\n'
              .. 'No — keep your text (apply only the style fields)',
              'Replace style notes?', 3)
            if choice ~= 2 then
              apply_style_preset(state, project, mode_module, o.value, choice == 6)
            end
          else
            apply_style_preset(state, project, mode_module, o.value, true)
          end
        end
      end
    end
    -- T10: własne style usera (snapshoty kontekstu) + zapis/kasowanie.
    local saved_names = cfg.list_custom_style_names('dubbing')
    if #saved_names > 0 then
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextDisabled(ctx, 'Custom styles')
      for _, name in ipairs(saved_names) do
        local key = 'saved:' .. name
        if reaper.ImGui_Selectable(ctx, name .. '##dubst_' .. name,
             key == cur_preset) then
          apply_saved_style(state, project, mode_module, name)
        end
      end
    end
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_Selectable(ctx, 'Save current context as style\xe2\x80\xa6##dubst_saveas', false) then
      s.save_style = {
        name = (cur_preset:match('^saved:(.+)$')) or '',
        pending_open = true,
      }
    end
    do
      local cur_saved = cur_preset:match('^saved:(.+)$')
      if cur_saved then
        if reaper.ImGui_Selectable(ctx, 'Delete this custom style##dubst_del', false) then
          cfg.delete_custom_style('dubbing', cur_saved)
          project.style_preset = 'custom'
          mode_module.mark_dirty(state)
        end
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Style preset prefills tone / era / audience / media / honorific\n'
      .. 'and writes its style notes into "Additional context" (editable).\n'
      .. 'Editing any field manually flips preset to "Custom". Free text never changes preset.\n'
      .. '"Save current context as style" keeps YOUR whole setup reusable across projects.')
  end
  -- T10: modal zapisu stylu (otwierany z combo wyżej; PO tooltipie — hover
  -- musi celować w combo, nie w ostatni item modala)
  render_save_style_modal(ctx, state, project, mode_module)

  reaper.ImGui_Spacing(ctx)

  -- 5 dropdowns in 2 rows (tone+era+audience / media+honorific) for compactness.
  render_dropdown(ctx, state, project, mode_module, 'Tone:',     TONE_OPTIONS,     'tone',     150)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  render_dropdown(ctx, state, project, mode_module, 'Era:',      ERA_OPTIONS,      'era',      150)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  render_dropdown(ctx, state, project, mode_module, 'Audience:', AUDIENCE_OPTIONS, 'audience', 140)

  render_dropdown(ctx, state, project, mode_module, 'Media:',     MEDIA_TYPE_OPTIONS, 'media_type', 180)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  render_dropdown(ctx, state, project, mode_module, 'Honorific:', HONORIFIC_OPTIONS,  'honorific',  220)

  reaper.ImGui_Spacing(ctx)

  -- Free-text additional context
  reaper.ImGui_Text(ctx, 'Additional context (free text — translator notes, plot summary, character relationships):')
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local rv, new_text = reaper.ImGui_InputTextMultiline(ctx, '##ctx_free_text',
    project.context.free_text or '', -1, 80)
  if rv then
    project.context.free_text = new_text
    on_context_edited(state, project, mode_module, 'free_text')
  end

  -- Glossary launcher inline
  reaper.ImGui_Spacing(ctx)
  local g = project.glossary or {}
  local n_chars = type(g.characters) == 'table' and #g.characters or 0
  local n_terms = type(g.terms) == 'table' and #g.terms or 0
  local n_dnt   = type(g.do_not_translate) == 'table' and #g.do_not_translate or 0
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_Text(ctx, ('Glossary: %d character(s) · %d term(s) · %d preserved word(s).'):format(
    n_chars, n_terms, n_dnt))
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if reaper.ImGui_SmallButton(ctx, 'Open glossary editor##ctx_glossary') then
    local ms = mode_module.init_state(state)
    ms.glossary_modal_pending_open = true
  end

  reaper.ImGui_Unindent(ctx, 16)
end

return M
