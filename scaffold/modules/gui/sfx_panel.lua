-- modules/gui/sfx_panel.lua
-- NS-SFX (2026-06-10): panel trybu Sound FX — pure UI. Mutuje stan trybu
-- (state.modes.sfx) + ustawia s.req_* flagi; spawny/insert wykonuje
-- modes/sfx.consume_signals (gui nie dotyka projektu bezpośrednio).
--
-- Sub-modes: 'describe' (prompt ręczny) | 'scene' (STT → LLM kandydaci).
-- Wspólna lista wyników na dole (▶ preview + Insert). Prompt inputs używają
-- wzorca soft-wrap (util.soft_wrap_text + normalize — mirror
-- tts_dialogue_panel: stan trzyma czysty tekst, widget dostaje wrapped view).

local theme       = require 'modules.theme'
local cfg         = require 'modules.config'
local util        = require 'modules.util'
local preview     = require 'modules.preview'
local voice_admin = require 'modules.voice_admin'
local sfx_mode    = nil   -- lazy (modes/sfx require'uje ten panel — unikamy cyklu)

local M = {}

local function mode()
  if not sfx_mode then sfx_mode = require 'modules.modes.sfx' end
  return sfx_mode
end

-- Panel-local wrapped-view bufory (mirror tts_dialogue_panel.wrap_buf).
local wrap_buf = {}

----------------------------------------------------------------------------
-- Wrapped multiline input: stan = czysty single-line; widget = wrapped view.
-- Zwraca true gdy tekst się zmienił (caller czyta nową wartość z getter/setter).
----------------------------------------------------------------------------
local function wrapped_input(ctx, id, text, width, min_rows)
  local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local w = width or -1
  local eff_w = (w < 0) and (avail_w + w + 1) or w
  local wrap_chars = math.max(20, math.floor((eff_w - 24) / 7))
  local shown = wrap_buf[id] or util.soft_wrap_text(text or '', wrap_chars)
  local _, n_breaks = shown:gsub('\n', '')
  local n_rows = math.min(5, math.max(min_rows or 2, n_breaks + 1))
  local box_h = n_rows * reaper.ImGui_GetTextLineHeight(ctx) + 14
  local rv, new_t = reaper.ImGui_InputTextMultiline(ctx, id, shown, w, box_h, 0)
  local out = nil
  if rv then
    wrap_buf[id] = new_t
    out = util.normalize_whitespace(new_t)
  end
  if not reaper.ImGui_IsItemActive(ctx) and wrap_buf[id] then
    wrap_buf[id] = nil
  end
  return out
end

----------------------------------------------------------------------------
-- Kind pill — wypełniony kolorowy znacznik rodzaju (mirror theme.status_pill:
-- soft tinted bg + kolor pełny na tekście). Kolory z mode().KIND_COLORS
-- (jedno źródło z kolorami tracków SFX/Music).
----------------------------------------------------------------------------
local KIND_PILL = {
  one_shot = { label = 'ONE-SHOT', color_key = 'one_shot' },
  ambience = { label = 'AMBIENCE', color_key = 'ambience' },
  music    = { label = 'MUSIC',    color_key = 'music' },
  sfx      = { label = 'SFX',      color_key = 'one_shot' },  -- group headers
}

local function kind_color(kind)
  local def = KIND_PILL[kind] or KIND_PILL.one_shot
  return mode().KIND_COLORS[def.color_key] or mode().KIND_COLORS.one_shot
end

local function kind_pill(ctx, kind, id_suffix)
  local def  = KIND_PILL[kind] or KIND_PILL.one_shot
  local rgba = kind_color(kind)
  local soft_bg = (rgba & 0xFFFFFF00) | 0x40
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        soft_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), soft_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  soft_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          rgba)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 8, 2)
  reaper.ImGui_SmallButton(ctx, def.label .. '##kpill_' .. id_suffix)
  reaper.ImGui_PopStyleVar(ctx, 1)
  reaper.ImGui_PopStyleColor(ctx, 4)
end

----------------------------------------------------------------------------
-- Cost preview lines. SFX = stałe 40 credits/s; muzyka NIE ma stałego
-- przelicznika (minuty muzyki z planu, kurs per tier) — preview orientacyjny.
----------------------------------------------------------------------------
local function cost_line(ctx, duration, count)
  local cps = mode().CREDITS_PER_SECOND
  local txt
  if duration then
    local total = math.ceil(duration * cps) * count
    txt = ('~%d credits (%d × %.1f s × %d/s)'):format(total, count, duration, cps)
  else
    txt = ('auto length — ~%d credits per second of result, × %d proposal%s')
      :format(cps, count, count == 1 and '' or 's')
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
  reaper.ImGui_Text(ctx, txt)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

local function music_cost_line(ctx, duration, count)
  local txt
  if duration then
    txt = ('~%s of music × %d take%s — billed as music minutes from your plan')
      :format(duration >= 60 and ('%d:%02d min'):format(math.floor(duration / 60), math.floor(duration % 60))
                              or ('%.0f s'):format(duration),
              count, count == 1 and '' or 's')
  else
    txt = ('auto length — billed as music minutes from your plan, × %d take%s')
      :format(count, count == 1 and '' or 's')
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
  reaper.ImGui_Text(ctx, txt)
  reaper.ImGui_PopStyleColor(ctx, 1)
end

----------------------------------------------------------------------------
-- T10: edytor własnego stylu sceny (Name + Brief + Package guidance).
-- Otwierany z combo "Scene style"; nowy styl = kopia wybranego (template).
-- Zapis → ExtState (config.save_custom_style 'sfx_scene'), cross-project.
----------------------------------------------------------------------------
local function render_style_editor_modal(ctx, s)
  local ed = s.style_editor
  if not ed then return end
  if ed.pending_open then
    reaper.ImGui_OpenPopup(ctx, 'Custom scene style')
    ed.pending_open = nil
  end
  theme.center_next_modal(ctx, 560, 0)
  theme.popup_keep_top(ctx, 'Custom scene style')
  local visible = reaper.ImGui_BeginPopupModal(ctx, 'Custom scene style', true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Name:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local rn, nn = reaper.ImGui_InputText(ctx, '##cst_name', ed.name or '')
  if rn then ed.name = nn end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Text(ctx, 'Style brief (sound character — goes into the AI brief):')
  local rb, nb = reaper.ImGui_InputTextMultiline(ctx, '##cst_brief',
    ed.brief or '', -1, 90)
  if rb then ed.brief = nb end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Text(ctx, 'Package guidance (composition + typical density; optional):')
  local rp, np2 = reaper.ImGui_InputTextMultiline(ctx, '##cst_pkg',
    ed.package or '', -1, 90)
  if rp then ed.package = np2 end

  reaper.ImGui_Spacing(ctx)
  local clean = (ed.name or ''):gsub('^%s+', ''):gsub('%s+$', '')
  reaper.ImGui_BeginDisabled(ctx, clean == '' or (ed.brief or '') == '')
  if theme.button_primary(ctx, 'Save style##cst_save') then
    -- Rename = zapis pod nową nazwą + usunięcie starego wpisu (bez duplikatu).
    if ed.orig_name and ed.orig_name ~= clean then
      cfg.delete_custom_style('sfx_scene', ed.orig_name)
    end
    cfg.save_custom_style('sfx_scene', clean,
      { brief = ed.brief or '', package = ed.package or '' })
    s.scene_preset = 'custom:' .. clean
    s.style_editor = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_EndDisabled(ctx)
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if ed and ed.can_delete then
    if theme.button_neutral(ctx, 'Delete style##cst_del', 0, 0) then
      cfg.delete_custom_style('sfx_scene', ed.orig_name or (ed.name or ''))
      s.scene_preset = 'film_drama'
      s.style_editor = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  end
  if theme.button_neutral(ctx, 'Cancel##cst_cancel', 0, 0) then
    s.style_editor = nil
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

----------------------------------------------------------------------------
-- Variants stepper (persisted globalnie — user decision 2026-06-10).
----------------------------------------------------------------------------
-- T9d (user 2026-07-11): etykieta 'Proposals per click' myliła się z liczbą
-- sugestii AI — teraz 'Takes per Generate' + default 1 (oszczędny start;
-- każdy take to osobny płatny render).
local function variants_stepper(ctx, s)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Takes per Generate:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_SetNextItemWidth(ctx, 110)
  local rv, v = reaper.ImGui_InputInt(ctx, '##sfx_variants', s.variant_count, 1, 1)
  if rv then
    s.variant_count = math.max(1, math.min(10, v))
    cfg.set_sfx_variant_count(s.variant_count)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'How many takes each Generate click renders (1-10). Every take is a\n'
      .. 'separate paid render — results always differ; audition and keep the best.\n'
      .. 'Applies to Describe and to scene candidates. Saved globally.')
  end
end

----------------------------------------------------------------------------
-- Describe sub-mode — przełącznik rodzaju generacji (sound effect / music).
----------------------------------------------------------------------------
local MUSIC_LEN_CHIPS = {
  { label = '10 s',  secs = 10  },
  { label = '30 s',  secs = 30  },
  { label = '1 min', secs = 60  },
  { label = '2 min', secs = 120 },
  { label = '5 min', secs = 300 },
}

local function render_describe_sfx(ctx, s)
  reaper.ImGui_Text(ctx, 'Describe the sound:')
  local new_text = wrapped_input(ctx, '##sfx_prompt', s.text_buffer, -1, 2)
  if new_text then s.text_buffer = new_text end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
  reaper.ImGui_Text(ctx, 'e.g. "Glass shattering on concrete" · "Footsteps on gravel, then a metallic door opens"')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)

  -- Duration: Auto / slider
  local rv, v = reaper.ImGui_Checkbox(ctx, 'Auto length##sfx_dur_auto', s.duration_auto)
  if rv then s.duration_auto = v end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'The model guesses a fitting length. Uncheck to set 0.5-30 s exactly.')
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_BeginDisabled(ctx, s.duration_auto)
  reaper.ImGui_SetNextItemWidth(ctx, 200)
  rv, v = reaper.ImGui_SliderDouble(ctx, '##sfx_dur', s.duration_seconds, 0.5, 30.0, '%.1f s')
  if rv then s.duration_seconds = v end
  reaper.ImGui_EndDisabled(ctx)

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  local lv_rv, lv = reaper.ImGui_Checkbox(ctx, 'Loop##sfx_loop', s.loop)
  if lv_rv then s.loop = lv end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Seamless loop — for ambience beds you want to extend by dragging the item edge.')
  end

  -- Prompt influence
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Stick to description:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_SetNextItemWidth(ctx, 200)
  rv, v = reaper.ImGui_SliderDouble(ctx, '##sfx_infl', s.prompt_influence, 0.0, 1.0, '%.2f')
  if rv then s.prompt_influence = v end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'Low = more creative variation. High = literal reading of the description. Default 0.3.')
  end

  reaper.ImGui_Spacing(ctx)
  variants_stepper(ctx, s)
  cost_line(ctx, (not s.duration_auto) and s.duration_seconds or nil, s.variant_count)
end

local function render_describe_music(ctx, s)
  reaper.ImGui_Text(ctx, 'Describe the music:')
  local new_text = wrapped_input(ctx, '##music_prompt', s.music_text_buffer, -1, 2)
  if new_text then s.music_text_buffer = new_text end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_muted)
  reaper.ImGui_Text(ctx, 'e.g. "Lo-fi chill beat, 70 BPM, warm and hazy" · "Tense investigative underscore, sparse piano, in D minor"')
  reaper.ImGui_PopStyleColor(ctx, 1)

  reaper.ImGui_Spacing(ctx)

  -- Length: Auto / input + quick chips (10 s loop … 5 min podcast bed)
  local rv, v = reaper.ImGui_Checkbox(ctx, 'Auto length##music_dur_auto', s.music_duration_auto)
  if rv then s.music_duration_auto = v end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, 'The model decides the track length. Uncheck to set 3 s - 10 min exactly.')
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  reaper.ImGui_BeginDisabled(ctx, s.music_duration_auto)
  reaper.ImGui_SetNextItemWidth(ctx, 90)
  local dr, dv = reaper.ImGui_InputDouble(ctx, 's##music_dur', s.music_duration_seconds, 0, 0, '%.0f')
  if dr then
    local md = mode()
    s.music_duration_seconds = math.max(md.MUSIC_DUR_MIN, math.min(md.MUSIC_DUR_MAX, dv or s.music_duration_seconds))
  end
  for _, chip in ipairs(MUSIC_LEN_CHIPS) do
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    if reaper.ImGui_SmallButton(ctx, chip.label .. '##music_chip_' .. chip.secs) then
      s.music_duration_seconds = chip.secs
      s.music_duration_auto    = false
    end
  end
  reaper.ImGui_EndDisabled(ctx)

  local ir, iv = reaper.ImGui_Checkbox(ctx, 'Instrumental only##music_instr', s.music_instrumental)
  if ir then s.music_instrumental = iv end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Guarantees no vocals — recommended for beds under narration or dialogue.\n'
      .. 'Uncheck only when you want a song with singing.')
  end

  -- Model muzyczny (2026-07-11): music_v2 dostępne w API — default v2.
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_TextDisabled(ctx, 'Model:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
  reaper.ImGui_SetNextItemWidth(ctx, 150)
  local cur_mm = cfg.get_music_model()
  local mm_label = (cur_mm == 'music_v1') and 'Music v1' or 'Music v2 (new)'
  if reaper.ImGui_BeginCombo(ctx, '##music_model', mm_label) then
    if reaper.ImGui_Selectable(ctx, 'Music v2 (new)', cur_mm == 'music_v2') then
      cfg.set_music_model('music_v2')
    end
    if reaper.ImGui_Selectable(ctx, 'Music v1', cur_mm == 'music_v1') then
      cfg.set_music_model('music_v1')
    end
    reaper.ImGui_EndCombo(ctx)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Music v2 (default): newer model, better long-form structure.\n'
      .. 'Music v1: previous generation — switch back if a result surprises you.')
  end

  reaper.ImGui_Spacing(ctx)
  variants_stepper(ctx, s)
  music_cost_line(ctx, (not s.music_duration_auto) and s.music_duration_seconds or nil, s.variant_count)
end

local function render_describe(ctx, s)
  -- Rodzaj generacji (W3 2026-06-11: radio → segmented sm; akcent per rodzaj
  -- z KIND_COLORS — items budowane per frame, bo kolory przez lazy mode()).
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Generate:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  local kind_items = {
    { key = 'sfx',   label = 'Sound effect', accent = kind_color('one_shot') },
    { key = 'music', label = 'Music',        accent = kind_color('music') },
  }
  local cur_kind = s.gen_kind == 'music' and 'music' or 'sfx'
  local kind_clicked = theme.segmented(ctx, 'sfx_gen_kind', kind_items,
    cur_kind, { size = 'sm' })
  if kind_clicked then s.gen_kind = kind_clicked end

  reaper.ImGui_Spacing(ctx)
  local is_music = s.gen_kind == 'music'
  if is_music then
    render_describe_music(ctx, s)
  else
    render_describe_sfx(ctx, s)
  end

  reaper.ImGui_Spacing(ctx)
  local busy = #s.gen_entries > 0
  if busy then
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, voice_admin.spinner_glyph() .. ' Generating…')
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    if theme.button_neutral(ctx, 'Cancel##sfx_cancel') then s.req_cancel = true end
  else
    local prompt = is_music and s.music_text_buffer or s.text_buffer
    reaper.ImGui_BeginDisabled(ctx, prompt == '')
    local noun  = is_music and (s.variant_count == 1 and 'music take' or 'music takes')
                           or (s.variant_count == 1 and 'sound' or 'sounds')
    local label = ('Generate %d %s##sfx_gen'):format(s.variant_count, noun)
    if theme.button_primary(ctx, label) then
      if is_music then
        s.req_generate = {
          prompt       = s.music_text_buffer,
          kind         = 'music',
          duration     = (not s.music_duration_auto) and s.music_duration_seconds or nil,
          instrumental = s.music_instrumental,
          count        = s.variant_count,
        }
      else
        s.req_generate = {
          prompt    = s.text_buffer,
          kind      = 'sfx',
          duration  = (not s.duration_auto) and s.duration_seconds or nil,
          influence = s.prompt_influence,
          loop      = s.loop,
          count     = s.variant_count,
        }
      end
    end
    reaper.ImGui_EndDisabled(ctx)
    -- W3 quick win: mirror Analyze scene — disabled button tłumaczy się sam.
    if prompt == ''
       and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
      reaper.ImGui_SetTooltip(ctx,
        is_music and 'Describe the music first.' or 'Describe the sound first.')
    end
  end
end

----------------------------------------------------------------------------
-- Scene sub-mode.
----------------------------------------------------------------------------
local function render_scene(ctx, s)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'Select a source audio item in REAPER (optionally narrow the fragment with a time selection), '
    .. 'pick a style and let AI propose sounds for the scene. Proposals land exactly at the fragment position.')
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)

  -- Live fragment status
  local frag, ferr = mode().detect_scene_fragment()
  if frag then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_done)
    reaper.ImGui_Text(ctx, ('Fragment: %.1f s starting at %.1f s'):format(frag.len, frag.pos))
    reaper.ImGui_PopStyleColor(ctx, 1)
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_stale)
    reaper.ImGui_Text(ctx, ferr or 'Select a source audio item first.')
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  -- Style preset — T10: stockowe + WŁASNE style usera ('custom:<Name>' z
  -- ExtState) + edytor (nowy styl startuje jako kopia wybranego = template).
  local presets = mode().SCENE_PRESETS
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Scene style:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_SetNextItemWidth(ctx, 220)
  local cur_style = mode().resolve_scene_style(s.scene_preset)
  local is_custom_sel = type(s.scene_preset) == 'string'
    and s.scene_preset:match('^custom:') ~= nil
  local cur_label = (is_custom_sel and (cur_style.label .. ' ·custom·'))
    or cur_style.label or s.scene_preset
  if reaper.ImGui_BeginCombo(ctx, '##sfx_scene_style', cur_label) then
    for _, key in ipairs(mode().SCENE_PRESET_ORDER) do
      if reaper.ImGui_Selectable(ctx, presets[key].label, key == s.scene_preset) then
        s.scene_preset = key
      end
    end
    local custom_names = cfg.list_custom_style_names('sfx_scene')
    if #custom_names > 0 then
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextDisabled(ctx, 'Custom styles')
      for _, name in ipairs(custom_names) do
        local key = 'custom:' .. name
        if reaper.ImGui_Selectable(ctx, name .. '##cst_' .. name,
             key == s.scene_preset) then
          s.scene_preset = key
        end
      end
    end
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_Selectable(ctx, '+ New custom style\xe2\x80\xa6##cst_new', false) then
      -- Startowy template = aktualnie wybrany styl (user request).
      s.style_editor = {
        name    = is_custom_sel and cur_style.label or '',
        brief   = cur_style.brief or '',
        package = cur_style.package or '',
        can_delete = false,   -- "+ New" = zawsze nowy wpis (kopia templatu)
        pending_open = true,
      }
    end
    if is_custom_sel then
      -- (bez glyphu ✎ — dingbats brakują w Inter, KNOWN-ISSUES)
      if reaper.ImGui_Selectable(ctx, 'Edit this style\xe2\x80\xa6##cst_edit', false) then
        s.style_editor = {
          name      = cur_style.label,
          orig_name = cur_style.label,   -- delete/rename działa na oryginale
          brief     = cur_style.brief or '',
          package   = cur_style.package or '',
          can_delete = true,
          pending_open = true,
        }
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Sound-design style injected into the AI brief (character + typical\n'
      .. 'package for the genre). "+ New custom style" starts from a copy of\n'
      .. 'the selected one — edit the brief and package guidance freely.')
  end
  render_style_editor_modal(ctx, s)

  -- Music model dla propozycji ze sceny (user 2026-07-11: widoczny OD RAZU
  -- w From scene, nie dopiero na karcie kandydata; karta dziedziczy tę
  -- wartość i może ją nadpisać). Niezależny od zakładki Describe.
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.lg)
  reaper.ImGui_TextDisabled(ctx, 'Music model:')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
  reaper.ImGui_SetNextItemWidth(ctx, 150)
  local smm = s.scene_music_model or 'music_v2'
  local smm_label = (smm == 'music_v1') and 'Music v1' or 'Music v2 (new)'
  if reaper.ImGui_BeginCombo(ctx, '##sfx_scene_music_model', smm_label) then
    if reaper.ImGui_Selectable(ctx, 'Music v2 (new)', smm == 'music_v2') then
      s.scene_music_model = 'music_v2'
    end
    if reaper.ImGui_Selectable(ctx, 'Music v1', smm == 'music_v1') then
      s.scene_music_model = 'music_v1'
    end
    reaper.ImGui_EndCombo(ctx)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Model for music-bed proposals from this scene. Independent from the\n'
      .. 'Describe tab. You can still override it on each music candidate card.')
  end

  -- Optional refinement
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, 'Refine (optional):')
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local rd, dv = reaper.ImGui_InputText(ctx, '##sfx_scene_detail', s.scene_detail)
  if rd then s.scene_detail = dv end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Details the transcript does not say — e.g. the text mentions rain,\n'
      .. 'but you know it is rain hitting a tin roof. Overrides the transcript.')
  end

  reaper.ImGui_Spacing(ctx)

  local analyzing = s.scene_phase == 'transcribing' or s.scene_phase == 'analyzing'
  if analyzing then
    reaper.ImGui_AlignTextToFramePadding(ctx)
    local phase_txt = s.scene_phase == 'transcribing' and 'Transcribing fragment…' or 'Asking AI for sound ideas…'
    reaper.ImGui_Text(ctx, voice_admin.spinner_glyph() .. ' ' .. phase_txt)
  else
    reaper.ImGui_BeginDisabled(ctx, frag == nil)
    if theme.button_primary(ctx, 'Analyze scene##sfx_analyze') then
      s.req_analyze = true
    end
    reaper.ImGui_EndDisabled(ctx)
    -- W3 quick win: wyszarzony przycisk tłumaczy się sam (AllowWhenDisabled).
    if frag == nil
       and reaper.ImGui_IsItemHovered(ctx, reaper.ImGui_HoveredFlags_AllowWhenDisabled()) then
      reaper.ImGui_SetTooltip(ctx, ferr or 'Select a source audio item in REAPER first.')
    end
  end

  -- Candidates — T9e (user decision 2026-07-11): TABELA PRODUKCYJNA.
  -- Wiersz = pomysł (chevron | pill | excerpt | timing | takes | Generate);
  -- rozwinięcie = edytor promptu + kontrolki + TAKE'Y INLINE. Świeży take
  -- ląduje W wierszu (modes/sfx.finalize_entry auto-otwiera kandydata) —
  -- koniec scroll ping-ponga do dolnej sekcji. Wzorzec: tabela segmentów
  -- Dubbingu + expandable rows VR.
  if s.scene_phase == 'ready' and #s.scene_candidates > 0 then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SeparatorText(ctx,
      ('Sound ideas · %d — expand a row to edit and audition'):format(#s.scene_candidates))
    -- T9d: stepper NAD kandydatami.
    variants_stepper(ctx, s)
    reaper.ImGui_Spacing(ctx)

    -- Mapy: grupy wyników per kandydat + busy per kandydat (spinner w wierszu).
    local groups_by_cand, busy_by_cand = {}, {}
    do
      local by_id = {}
      for _, g in ipairs(s.result_groups) do
        if g.cand_index then
          groups_by_cand[g.cand_index] = groups_by_cand[g.cand_index] or {}
          table.insert(groups_by_cand[g.cand_index], g)
          by_id[g.id] = g
        end
      end
      for _, e in ipairs(s.gen_entries) do
        local g = by_id[e.group_id]
        if g and g.cand_index then busy_by_cand[g.cand_index] = true end
      end
    end
    local function cand_take_count(i)
      local n = 0
      for _, g in ipairs(groups_by_cand[i] or {}) do n = n + #g.takes end
      return n
    end
    -- Cięcie excerptu po ZNAKACH (utf8.offset), nie bajtach — M3-1.
    local function short(text, max_chars)
      local t = (text or ''):gsub('%s+', ' ')
      if util.utf8_len(t) <= max_chars then return t end
      local cut = utf8.offset(t, max_chars) or (#t + 1)
      return t:sub(1, cut - 1) .. '…'
    end

    local PLACE_LABELS = { intro = 'Opens scene (before)',
                           at    = 'At moment',
                           outro = 'Closes scene (after)' }
    local PLACE_SHORT  = { intro = 'before', outro = 'after' }

    local tbl_flags = reaper.ImGui_TableFlags_RowBg()
                    | reaper.ImGui_TableFlags_BordersInnerH()
                    | reaper.ImGui_TableFlags_NoSavedSettings()
    if reaper.ImGui_BeginTable(ctx, '##sfx_ideas_tbl', 6, tbl_flags) then
      reaper.ImGui_TableSetupColumn(ctx, '',
        reaper.ImGui_TableColumnFlags_WidthFixed(), 26)
      reaper.ImGui_TableSetupColumn(ctx, 'Kind',
        reaper.ImGui_TableColumnFlags_WidthFixed(), 84)
      reaper.ImGui_TableSetupColumn(ctx, 'Idea',
        reaper.ImGui_TableColumnFlags_WidthStretch())
      reaper.ImGui_TableSetupColumn(ctx, 'Timing',
        reaper.ImGui_TableColumnFlags_WidthFixed(), 120)
      reaper.ImGui_TableSetupColumn(ctx, 'Takes',
        reaper.ImGui_TableColumnFlags_WidthFixed(), 56)
      reaper.ImGui_TableSetupColumn(ctx, '',
        reaper.ImGui_TableColumnFlags_WidthFixed(), 190)
      reaper.ImGui_TableHeadersRow(ctx)

      for i, cand in ipairs(s.scene_candidates) do
        local is_music = cand.kind == 'music'
        local expanded = cand.open == true
        local busy_row = busy_by_cand[i] == true
        reaper.ImGui_TableNextRow(ctx)

        -- Chevron
        reaper.ImGui_TableNextColumn(ctx)
        if reaper.ImGui_SmallButton(ctx, (expanded and 'v' or '>') .. '##ideax_' .. i) then
          cand.open = not expanded
        end

        -- Kind pill (kolor rodzaju = dawny pasek karty). T9f: tooltip mówi,
        -- KTÓRY silnik wyrenderuje ten pomysł (user request).
        reaper.ImGui_TableNextColumn(ctx)
        kind_pill(ctx, cand.kind, 'cand_' .. i)
        if reaper.ImGui_IsItemHovered(ctx) then
          local eng = is_music
            and ('ElevenLabs Music (' ..
                 ((cand.music_model or s.scene_music_model or 'music_v2') == 'music_v1'
                   and 'v1' or 'v2') .. ')')
            or 'ElevenLabs Sound FX'
          reaper.ImGui_SetTooltip(ctx,
            ('Engine: %s\nExpand the row to switch the engine/model.'):format(eng))
        end

        -- Idea: zwinięty = excerpt (klik rozwija); rozwinięty = edytor +
        -- kontrolki + take'y inline
        reaper.ImGui_TableNextColumn(ctx)
        if not expanded then
          reaper.ImGui_AlignTextToFramePadding(ctx)
          if reaper.ImGui_Selectable(ctx, short(cand.prompt, 88) .. '##ideasel_' .. i,
               false) then
            cand.open = true
          end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, cand.prompt
              .. (cand.why ~= '' and ('\n\nWhy: ' .. cand.why) or '')
              .. '\n\nClick to expand — edit, generate and audition takes.')
          end
        else
          if cand.why ~= '' then
            theme.push_caption(ctx)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
            reaper.ImGui_TextWrapped(ctx, cand.why)
            reaper.ImGui_PopStyleColor(ctx, 1)
            theme.pop_caption(ctx)
          end
          local new_p = wrapped_input(ctx, ('##sfx_cand_%d'):format(i), cand.prompt, -1, 2)
          if new_p then cand.prompt = new_p end

          -- Kontrolki (Engine / Length / Place / Starts at / Instrumental | Loop)
          -- T9f (user request): silnik/model per kandydat + PRZEPIĘCIE —
          -- np. ambience zaproponowany jako SFX można oddać silnikowi
          -- muzycznemu (i odwrotnie: music → ambience, zyskuje loop).
          reaper.ImGui_AlignTextToFramePadding(ctx)
          reaper.ImGui_Text(ctx, 'Engine:')
          reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
          reaper.ImGui_SetNextItemWidth(ctx, 125)
          local cmm = cand.music_model or s.scene_music_model or 'music_v2'
          local eng_label = is_music
            and ((cmm == 'music_v1') and 'Music v1' or 'Music v2 (new)')
            or 'Sound FX'
          if reaper.ImGui_BeginCombo(ctx, ('##sfx_cand_eng_%d'):format(i), eng_label) then
            if reaper.ImGui_Selectable(ctx, 'Sound FX', not is_music) then
              if is_music then
                -- music → ambience (jedyny kind SFX z sensem dla materiału
                -- muzycznego; zyskuje loop, limit 30 s)
                cand.kind = 'ambience'
                cand.instrumental = nil
                cand.duration_seconds = math.min(mode().DUR_MAX,
                  math.max(mode().DUR_MIN, cand.duration_seconds or 10))
              end
            end
            if reaper.ImGui_Selectable(ctx, 'Music v2 (new)',
                 is_music and cmm == 'music_v2') then
              cand.kind = 'music'
              cand.music_model = 'music_v2'
              cand.loop = false
              if cand.instrumental == nil then cand.instrumental = true end
              cand.duration_seconds = math.max(mode().MUSIC_DUR_MIN,
                math.min(mode().MUSIC_DUR_MAX, cand.duration_seconds or 30))
            end
            if reaper.ImGui_Selectable(ctx, 'Music v1',
                 is_music and cmm == 'music_v1') then
              cand.kind = 'music'
              cand.music_model = 'music_v1'
              cand.loop = false
              if cand.instrumental == nil then cand.instrumental = true end
              cand.duration_seconds = math.max(mode().MUSIC_DUR_MIN,
                math.min(mode().MUSIC_DUR_MAX, cand.duration_seconds or 30))
            end
            reaper.ImGui_EndCombo(ctx)
          end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx,
              'Which model renders this idea:\n'
              .. 'Sound FX — /sound-generation (0.5-30 s, can loop; one-shots & ambience).\n'
              .. 'Music — /music (3-300 s, no loop; themes, beds, jingles).\n'
              .. 'Switching converts the kind accordingly.')
          end
          reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
          reaper.ImGui_Text(ctx, 'Length:')
          reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
          reaper.ImGui_SetNextItemWidth(ctx, 80)
          local dr, dvv = reaper.ImGui_InputDouble(ctx, ('s##sfx_cand_dur_%d'):format(i),
            cand.duration_seconds, 0, 0, '%.1f')
          if dr then
            local md = mode()
            local lo = is_music and md.MUSIC_DUR_MIN or md.DUR_MIN
            local hi = is_music and md.MUSIC_DUR_MAX or md.DUR_MAX
            cand.duration_seconds = math.max(lo, math.min(hi, dvv or cand.duration_seconds))
          end
          -- T9: placement — czołówka PRZED fragmentem / moment / outro PO.
          reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
          local place = cand.placement or 'at'
          reaper.ImGui_SetNextItemWidth(ctx, 155)
          if reaper.ImGui_BeginCombo(ctx, ('##sfx_cand_place_%d'):format(i),
               PLACE_LABELS[place]) then
            for _, pk in ipairs({ 'intro', 'at', 'outro' }) do
              if reaper.ImGui_Selectable(ctx, PLACE_LABELS[pk], place == pk) then
                cand.placement = pk
              end
            end
            reaper.ImGui_EndCombo(ctx)
          end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx,
              'Where "Insert at scene" places the result:\n'
              .. 'Opens scene — ends exactly where the fragment starts (show opener / theme).\n'
              .. 'At moment — anchored inside the fragment at "Starts at".\n'
              .. 'Closes scene — starts right after the fragment ends.')
          end
          if place == 'at' then
            reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
            reaper.ImGui_Text(ctx, 'Starts at:')
            reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
            reaper.ImGui_SetNextItemWidth(ctx, 80)
            local ar, avv = reaper.ImGui_InputDouble(ctx,
              ('s##sfx_cand_at_%d'):format(i), cand.starts_at or 0, 0, 0, '%.1f')
            if ar then
              local max_at = s.scene_frag and s.scene_frag.len or 9999
              cand.starts_at = math.max(0, math.min(max_at, avv or cand.starts_at or 0))
            end
            if reaper.ImGui_IsItemHovered(ctx) then
              reaper.ImGui_SetTooltip(ctx,
                'Seconds from the fragment start — AI anchored this to the word\n'
                .. 'where the event happens. Adjust freely; Insert at scene uses it.')
            end
          end
          reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
          if is_music then
            local ir, ivv = reaper.ImGui_Checkbox(ctx,
              ('Instrumental##sfx_cand_instr_%d'):format(i), cand.instrumental ~= false)
            if ir then cand.instrumental = ivv end
            if reaper.ImGui_IsItemHovered(ctx) then
              reaper.ImGui_SetTooltip(ctx,
                'No vocals — recommended for beds under narration or dialogue.')
            end
            -- (Model muzyki per kandydat żyje w combo Engine — T9f.)
          else
            local lr, lvv = reaper.ImGui_Checkbox(ctx,
              ('Loop##sfx_cand_loop_%d'):format(i), cand.loop)
            if lr then cand.loop = lvv end
          end

          -- Take'y INLINE (wszystkie grupy tego kandydata, numeracja ciągła)
          local n_take, remove_g, remove_ti = 0, nil, nil
          for _, g in ipairs(groups_by_cand[i] or {}) do
            for ti, t in ipairs(g.takes) do
              n_take = n_take + 1
              local pid = 'sfx_res_' .. t.id
              local playing = preview.is_playing(pid)
              if reaper.ImGui_SmallButton(ctx, (playing and '■' or '▶') .. '##' .. pid) then
                if playing then preview.stop() else preview.play_file(t.path, pid) end
              end
              reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
              reaper.ImGui_Text(ctx, ('take %d'):format(n_take))
              if t.from_cache and reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, 'From cache — not billed.')
              end
              reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
              if g.scene_pos then
                if reaper.ImGui_SmallButton(ctx, ('Insert at scene##ins_%d'):format(t.id)) then
                  -- T10b (user-caught): Insert słucha BIEŻĄCYCH kontrolek
                  -- wiersza (placement + Starts at), nie snapshotu grupy
                  -- z momentu Generate — zmiana "At moment"→"Closes scene"
                  -- po generacji ma działać przy ponownym wstawieniu.
                  s.req_insert = {
                    group_id = g.id, take_id = t.id, where = 'scene',
                    place     = cand.placement or 'at',
                    starts_at = cand.starts_at or 0,
                  }
                end
                if reaper.ImGui_IsItemHovered(ctx) then
                  reaper.ImGui_SetTooltip(ctx,
                    'Inserts using the CURRENT placement / Starts at above —\nadjust them freely between inserts.')
                end
                reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
              end
              if reaper.ImGui_SmallButton(ctx, ('Insert at playhead##insp_%d'):format(t.id)) then
                s.req_insert = { group_id = g.id, take_id = t.id, where = 'playhead' }
              end
              reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
              if reaper.ImGui_SmallButton(ctx, ('×##rm_%d'):format(t.id)) then
                remove_g, remove_ti = g, ti
              end
            end
          end
          if remove_g then table.remove(remove_g.takes, remove_ti) end
          if busy_row then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
            reaper.ImGui_Text(ctx, voice_admin.spinner_glyph() .. ' generating…')
            reaper.ImGui_PopStyleColor(ctx, 1)
          end
        end

        -- Timing (skrót w obu stanach)
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        local place2 = cand.placement or 'at'
        local timing = PLACE_SHORT[place2]
          and ('%s · %.0fs'):format(PLACE_SHORT[place2], cand.duration_seconds or 0)
          or  ('+%.1fs · %.0fs'):format(cand.starts_at or 0, cand.duration_seconds or 0)
        reaper.ImGui_TextDisabled(ctx, timing)

        -- Takes count
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        local n_tk = cand_take_count(i)
        if busy_row then
          reaper.ImGui_Text(ctx, voice_admin.spinner_glyph())
        elseif n_tk > 0 then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_done)
          reaper.ImGui_Text(ctx, ('●%d'):format(n_tk))
          reaper.ImGui_PopStyleColor(ctx, 1)
        else
          reaper.ImGui_TextDisabled(ctx, '—')
        end

        -- Actions
        reaper.ImGui_TableNextColumn(ctx)
        local busy_any = #s.gen_entries > 0
        reaper.ImGui_BeginDisabled(ctx, busy_any or cand.prompt == '')
        if theme.button_primary(ctx,
             ('Generate %d##sfx_cand_gen_%d'):format(s.variant_count, i)) then
          s.req_generate = {
            prompt       = cand.prompt,
            kind         = is_music and 'music' or 'sfx',
            duration     = cand.duration_seconds,
            influence    = (not is_music) and s.prompt_influence or nil,
            loop         = (not is_music) and cand.loop or false,
            instrumental = is_music and (cand.instrumental ~= false) or nil,
            music_model  = is_music and (cand.music_model or s.scene_music_model or 'music_v2') or nil,
            count        = s.variant_count,
            scene_pos    = s.scene_frag and (s.scene_frag.pos + (cand.starts_at or 0)) or nil,
            scene_offset = cand.starts_at or 0,
            place        = cand.placement or 'at',
            scene_start  = s.scene_frag and s.scene_frag.pos or nil,
            scene_len    = s.scene_frag and s.scene_frag.len or nil,
            -- T9f: kotwica żywego itemu (insert liczy deltę pozycji —
            -- przesunięty item nie zostawia dźwięków w polu).
            anchor_guid  = s.scene_frag and s.scene_frag.item_guid or nil,
            anchor_pos   = s.scene_frag and s.scene_frag.item_pos or nil,
            cand_index   = i,
          }
        end
        if reaper.ImGui_IsItemHovered(ctx) then
          -- T9d: zawsze mów, skąd bierze się N i gdzie je zmienić.
          local tip = ('Renders %d take(s) of this idea — change the count with\n'
            .. '"Takes per Generate" above (1 = cheapest).'):format(s.variant_count)
          if (cand.gen_count or 0) > 0 then
            tip = tip .. ('\nAlready generated ×%d. Each click creates fresh takes —\n'
              .. 'results always differ slightly, never identical copies.'):format(cand.gen_count)
          end
          reaper.ImGui_SetTooltip(ctx, tip)
        end
        reaper.ImGui_EndDisabled(ctx)
        if expanded then
          if cand.rephrase_handle then
            reaper.ImGui_AlignTextToFramePadding(ctx)
            reaper.ImGui_Text(ctx, voice_admin.spinner_glyph() .. ' new idea…')
          else
            if theme.button_neutral(ctx, ('New idea##sfx_cand_re_%d'):format(i)) then
              s.req_rephrase = i
            end
            if reaper.ImGui_IsItemHovered(ctx) then
              reaper.ImGui_SetTooltip(ctx,
                'Asks AI for a different take on this moment — same spot and type,\n'
                .. 'new sonic interpretation. Replaces the description (previous\n'
                .. 'versions are remembered so AI will not repeat them). You still\n'
                .. 'review and click Generate yourself.')
            end
          end
        end
      end
      reaper.ImGui_EndTable(ctx)
    end
    if #s.gen_entries > 0 then
      reaper.ImGui_AlignTextToFramePadding(ctx)
      reaper.ImGui_Text(ctx, voice_admin.spinner_glyph() .. ' Generating…')
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
      if theme.button_neutral(ctx, 'Cancel##sfx_scene_cancel') then s.req_cancel = true end
    end
  end
end

----------------------------------------------------------------------------
-- Shared results list — zwijane grupy per klik Generate (user decision
-- 2026-06-10: tylko najnowsza grupa otwarta, "żeby playerów nie było milion").
----------------------------------------------------------------------------
local function group_meta_label(g)
  return (g.from == 'scene')
    and ('scene +%.1fs'):format(g.scene_offset or 0)
    or  'described'
end

local function render_group_takes(ctx, s, g, generating)
  reaper.ImGui_Indent(ctx, 18)
  local remove_take = nil
  for ti, t in ipairs(g.takes) do
    local pid = 'sfx_res_' .. t.id
    local playing = preview.is_playing(pid)
    if reaper.ImGui_SmallButton(ctx, (playing and '■' or '▶') .. '##' .. pid) then
      if playing then preview.stop() else preview.play_file(t.path, pid) end
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    reaper.ImGui_Text(ctx, ('take %d'):format(ti))
    if t.from_cache and reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, 'From cache — not billed.')
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    if g.scene_pos then
      if reaper.ImGui_SmallButton(ctx, ('Insert at scene##ins_%d'):format(t.id)) then
        s.req_insert = { group_id = g.id, take_id = t.id, where = 'scene' }
      end
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    end
    if reaper.ImGui_SmallButton(ctx, ('Insert at playhead##insp_%d'):format(t.id)) then
      s.req_insert = { group_id = g.id, take_id = t.id, where = 'playhead' }
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.xs)
    if reaper.ImGui_SmallButton(ctx, ('×##rm_%d'):format(t.id)) then
      remove_take = ti
    end
  end
  if generating then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_Text(ctx, voice_admin.spinner_glyph() .. ' generating…')
    reaper.ImGui_PopStyleColor(ctx, 1)
  end
  reaper.ImGui_Unindent(ctx, 18)
  if remove_take then table.remove(g.takes, remove_take) end
end

local function render_results(ctx, s)
  -- T9e: take'y kandydatów sceny żyją INLINE w tabeli pomysłów — tu tylko
  -- grupy bez kandydata. T9f: scoping per widok — Describe pokazuje swoje
  -- wyniki, scena tylko SWOJE sieroty po re-Analyze (nie mieszamy).
  local in_scene = s.sub_mode == 'scene'
  local list = {}
  for _, g in ipairs(s.result_groups) do
    if not g.cand_index
       and ((in_scene and g.from == 'scene')
            or (not in_scene and g.from ~= 'scene')) then
      list[#list + 1] = g
    end
  end
  if #list == 0 then return end

  -- Grupy z generacją w toku (spinner w nagłówku + placeholder w środku).
  local generating = {}
  for _, e in ipairs(s.gen_entries) do generating[e.group_id] = true end

  local total = 0
  for _, g in ipairs(list) do total = total + #g.takes end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, (in_scene
      and 'Earlier results (previous analysis) · %d group%s, %d take%s'
      or  'Generated sounds · %d group%s, %d take%s')
    :format(#list, #list == 1 and '' or 's',
            total, total == 1 and '' or 's'))
  if reaper.ImGui_SmallButton(ctx, 'Clear all##sfx_clear_all') then
    preview.stop()
    -- Czyści tylko tę listę — take'y przypięte do kandydatów sceny i wyniki
    -- drugiego widoku zostają.
    local drop = {}
    for _, g in ipairs(list) do drop[g] = true end
    local keep = {}
    for _, g in ipairs(s.result_groups) do
      if not drop[g] then keep[#keep + 1] = g end
    end
    s.result_groups = keep
    return
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx,
      'Empties this list only. Generated audio stays cached on disk —\n'
      .. 'the same prompt + take regenerates instantly and free.')
  end

  local remove_group = nil
  for _, g in ipairs(list) do
    -- ASCII chevron > / v — mirror tracks_table (małe trójkąty ▸▾ brakują w Inter)
    local arrow = g.open and 'v' or '>'
    if reaper.ImGui_SmallButton(ctx, arrow .. '##grp_' .. g.id) then g.open = not g.open end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    kind_pill(ctx, g.kind == 'music' and 'music' or 'sfx', 'grp_' .. g.id)
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
    local label = g.prompt
    if #label > 48 then label = label:sub(1, 45) .. '...' end
    reaper.ImGui_Text(ctx, label)
    if reaper.ImGui_IsItemHovered(ctx) then
      local tip = g.prompt
      if g.scene_pos then
        tip = tip .. ('\nScene position: %.2fs (offset +%.1fs)')
          :format(g.scene_pos, g.scene_offset or 0)
      end
      reaper.ImGui_SetTooltip(ctx, tip)
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_Text(ctx, ('%s · %d take%s%s'):format(group_meta_label(g),
      #g.takes, #g.takes == 1 and '' or 's',
      generating[g.id] and (' ' .. voice_admin.spinner_glyph()) or ''))
    reaper.ImGui_PopStyleColor(ctx, 1)
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    if reaper.ImGui_SmallButton(ctx, ('×##grpx_%d'):format(g.id)) then
      remove_group = g
    end
    if g.open then
      render_group_takes(ctx, s, g, generating[g.id])
    end
  end
  if remove_group then
    for gi, g in ipairs(s.result_groups) do
      if g == remove_group then table.remove(s.result_groups, gi) break end
    end
  end
end

----------------------------------------------------------------------------
-- Public render.
----------------------------------------------------------------------------
local SUB_MODE_ITEMS = {
  { key = 'describe', label = 'Describe',
    tooltip = 'Describe the sound you need in your own words.' },
  { key = 'scene',    label = 'From scene',
    tooltip = 'Analyze a selected dialogue item and let AI propose matching sounds.' },
}

function M.render(ctx, s, _deps)
  reaper.ImGui_Spacing(ctx)

  -- Sub-mode toggle (W3 2026-06-11: radio → theme.segmented sm, akcent SFX —
  -- mirror paska trybów i TTS Single/Dialogue)
  local cur_sub = s.sub_mode == 'scene' and 'scene' or 'describe'
  local sub_clicked = theme.segmented(ctx, 'sfx_sub_mode', SUB_MODE_ITEMS,
    cur_sub, { size = 'sm', accent = theme.MODE_ACCENTS.sfx })
  if sub_clicked then s.sub_mode = sub_clicked end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  if s.sub_mode == 'scene' then
    render_scene(ctx, s)
  else
    render_describe(ctx, s)
  end

  -- Status line — NAD wynikami, czyli tuż pod przyciskami akcji (W3 quick
  -- win; wcześniej na samym dole panelu, pod listą wyników — łatwo przeoczyć).
  if s.status_text ~= '' then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), s.status_color or theme.COLORS.text_dim)
    reaper.ImGui_TextWrapped(ctx, s.status_text)
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  render_results(ctx, s)
end

return M
