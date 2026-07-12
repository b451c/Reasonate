-- modules/gui/dubbing_voice_design.lua
-- NS-B M4.1: Voice Design — text-to-voice (2-step API).
--
-- Flow:
--   1. User opens modal z Cast sidebar "Change voice v" -> "Design voice from prompt..."
--   2. User wpisuje voice_name + voice_description + sample text (auto-filled z first segment)
--      + clicks Generate previews.
--   3. Modal pokazuje N previews (typowo 3-5) z play button per preview + Pick button.
--   4. User picks → spawn create_from_preview → on done speaker.voices[lang] = new voice_id.
--
-- Audio playback: ElevenLabs returns audio_base64 per preview. We decode (pure Lua)
-- + write to tmp file, then modules.preview.play_url(file://...).

local theme       = require 'modules.theme'
local preview     = require 'modules.preview'
local util        = require 'modules.util'
local voice_admin = require 'modules.voice_admin'

local M = {}

local POPUP_ID = 'Design voice from prompt'

local s = {
  pending_open = false,
  speaker_id   = nil,
  speaker_label= nil,
  -- Form buffers
  buf_name        = '',
  buf_description = '',
  buf_sample_text = '',
  -- Stage: 'form' | 'previewing' | 'pick' | 'creating'
  stage = 'form',
  previews_handle = nil,
  previews        = nil,   -- array of { audio_base64, generated_voice_id, audio_file_path, play_id }
  create_handle   = nil,
  picked_preview_idx = nil,
  -- Callback when voice created — caller responsibility (cast sidebar code)
  on_voice_created = nil,
}

local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

local function reset_state()
  if s.previews then
    for _, p in ipairs(s.previews) do
      if p.audio_file_path and util.file_exists(p.audio_file_path) then
        os.remove(p.audio_file_path)
      end
    end
  end
  preview.stop()
  s.stage = 'form'
  s.previews_handle = nil
  s.previews = nil
  s.create_handle = nil
  s.picked_preview_idx = nil
  s.speaker_id = nil
  s.speaker_label = nil
  s.buf_name = ''
  s.buf_description = ''
  s.buf_sample_text = ''
  s.on_voice_created = nil
end

function M.open(opts)
  s.pending_open  = true
  s.speaker_id    = opts.speaker_id
  s.speaker_label = opts.speaker_label or opts.speaker_id or 'speaker'
  s.buf_name      = opts.default_name or (s.speaker_label .. '_designed')
  s.buf_description = opts.default_description or ''
  s.buf_sample_text = opts.default_sample_text or 'Welcome to the show. Today we explore something rare.'
  s.stage = 'form'
  s.on_voice_created = opts.on_voice_created
end

function M.is_open() return s.speaker_id ~= nil end

----------------------------------------------------------------------------
-- After spawn_voice_design_previews done → decode each preview's
-- audio_base64 + save tmp mp3 file dla preview.play_url.
----------------------------------------------------------------------------
local function materialize_previews(result)
  if not result or type(result.previews) ~= 'table' then return false, 'no previews array' end
  util.mkdir_p(tmp_dir())
  s.previews = {}
  for i, p in ipairs(result.previews) do
    if p.audio_base64 and p.audio_base64 ~= '' then
      local decoded, derr = util.base64_decode(p.audio_base64)
      if decoded then
        local path = tmp_dir() .. path_sep() .. ('vdesign_preview_%x_%d.mp3'):format(os.time(), i)
        local f = io.open(path, 'wb')
        if f then
          f:write(decoded)
          f:close()
          s.previews[#s.previews + 1] = {
            audio_base64       = nil,        -- drop heavy string, kept only path
            generated_voice_id = p.generated_voice_id,
            audio_file_path    = path,
            play_id            = 'vd_prev_' .. tostring(i),
            duration_secs      = p.duration_secs,
          }
        end
      end
    end
  end
  return #s.previews > 0
end

function M.render(ctx, state, mode_module)
  if not s.speaker_id then return nil end
  if s.pending_open then
    reaper.ImGui_OpenPopup(ctx, POPUP_ID)
    s.pending_open = false
  end

  -- Poll any active handles
  if s.previews_handle then
    voice_admin.poll(s.previews_handle)
    if s.previews_handle.status == 'done' then
      if materialize_previews(s.previews_handle.result) then
        s.stage = 'pick'
      else
        s.stage = 'form'
        if mode_module then
          mode_module.set_status(state, 'Voice Design: no previews returned', theme.COLORS.status_stale)
        end
      end
      s.previews_handle = nil
    elseif s.previews_handle.status == 'error' then
      if mode_module then
        mode_module.set_status(state, ('Voice Design previews err: %s'):format(s.previews_handle.error or '?'), theme.COLORS.status_error)
      end
      s.stage = 'form'
      s.previews_handle = nil
    end
  end

  if s.create_handle then
    voice_admin.poll(s.create_handle)
    if s.create_handle.status == 'done' then
      if s.on_voice_created and s.create_handle.result then
        s.on_voice_created(s.create_handle.result.voice_id, s.create_handle.result.name or s.buf_name)
      end
      reset_state()
      reaper.ImGui_CloseCurrentPopup(ctx)
      return 'created'
    elseif s.create_handle.status == 'error' then
      if mode_module then
        mode_module.set_status(state, ('Voice Design create err: %s'):format(s.create_handle.error or '?'), theme.COLORS.status_error)
      end
      s.stage = 'pick'
      s.create_handle = nil
    end
  end

  theme.center_next_modal(ctx, 640, 540)
  theme.popup_keep_top(ctx, POPUP_ID)
  local visible = reaper.ImGui_BeginPopupModal(ctx, POPUP_ID, true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then
    reset_state()
    return 'close'
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx, ('Designing voice for %s. Voice description = plain English describing tone / age / accent / vibe.'):format(s.speaker_label))
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  if s.stage == 'form' then
    reaper.ImGui_Text(ctx, 'Voice name (label w your library):')
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local rv_n, new_n = reaper.ImGui_InputText(ctx, '##vd_name', s.buf_name)
    if rv_n then s.buf_name = new_n end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, 'Voice description (free text, ~100-1000 chars):')
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local rv_d, new_d = reaper.ImGui_InputTextMultiline(ctx, '##vd_desc', s.buf_description, -1, 80)
    if rv_d then s.buf_description = new_d end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
    reaper.ImGui_TextWrapped(ctx,
      'Examples: "Calm middle-aged male narrator, British accent, low pitch, slow pace."\n'
        .. '"Energetic young female streamer, American accent, fast bouncy delivery."')
    reaper.ImGui_PopStyleColor(ctx, 1)

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, 'Sample text (used dla preview generation, ~100-1000 chars):')
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local rv_s, new_s = reaper.ImGui_InputTextMultiline(ctx, '##vd_sample', s.buf_sample_text, -1, 60)
    if rv_s then s.buf_sample_text = new_s end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    local can_generate = #s.buf_description >= 20 and #s.buf_sample_text >= 20 and #s.buf_name > 0
    if theme.button_neutral(ctx, 'Cancel') then
      reset_state()
      reaper.ImGui_CloseCurrentPopup(ctx)
      reaper.ImGui_EndPopup(ctx)
      return 'cancel'
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    reaper.ImGui_BeginDisabled(ctx, not can_generate)
    if theme.button_primary(ctx, 'Generate previews') then
      local h = voice_admin.spawn_voice_design_previews({
        voice_description = s.buf_description,
        text              = s.buf_sample_text,
        model_id          = 'eleven_multilingual_v2',
        guidance_scale    = 5,
      })
      if h.status == 'error' then
        if mode_module then
          mode_module.set_status(state, ('Voice Design start err: %s'):format(h.error or '?'), theme.COLORS.status_error)
        end
      else
        s.previews_handle = h
        s.stage = 'previewing'
      end
    end
    reaper.ImGui_EndDisabled(ctx)
    if not can_generate and reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, 'Need name + at least 20 chars description + 20 chars sample text.')
    end

  elseif s.stage == 'previewing' then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_running)
    reaper.ImGui_Text(ctx, 'Generating previews... (typically 5-15 seconds)')
    reaper.ImGui_PopStyleColor(ctx, 1)

  elseif s.stage == 'pick' then
    reaper.ImGui_Text(ctx, ('Generated %d preview(s). Play + pick the best fit:'):format(s.previews and #s.previews or 0))
    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_BeginChild(ctx, '##vd_previews', -1, -56, 0, 0) then
      for i, p in ipairs(s.previews or {}) do
        reaper.ImGui_PushID(ctx, 'vd_p_' .. i)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_Text(ctx, ('Preview %d'):format(i))
        if p.duration_secs then
          reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
          reaper.ImGui_Text(ctx, ('%.1fs'):format(p.duration_secs))
          reaper.ImGui_PopStyleColor(ctx, 1)
        end
        local playing = preview.is_playing(p.play_id)
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
        if playing then
          if reaper.ImGui_SmallButton(ctx, 'Stop##stop_' .. i) then preview.stop() end
        else
          if reaper.ImGui_SmallButton(ctx, '> Play##play_' .. i) then
            preview.play_url('file://' .. p.audio_file_path, p.play_id)
          end
        end
        reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
        if theme.button_primary(ctx, 'Use this voice##use_' .. i) then
          -- Spawn step 2: create permanent voice. Mark others as "played not selected".
          preview.stop()
          local others = {}
          for j, q in ipairs(s.previews) do
            if j ~= i and q.generated_voice_id then others[#others + 1] = q.generated_voice_id end
          end
          local h = voice_admin.spawn_voice_design_create({
            voice_name        = s.buf_name,
            voice_description = s.buf_description,
            generated_voice_id = p.generated_voice_id,
            played_not_selected_voice_ids = others,
          })
          if h.status == 'error' then
            if mode_module then
              mode_module.set_status(state, ('Voice create err: %s'):format(h.error or '?'), theme.COLORS.status_error)
            end
          else
            s.create_handle = h
            s.picked_preview_idx = i
            s.stage = 'creating'
          end
        end
        reaper.ImGui_PopID(ctx)
        reaper.ImGui_Spacing(ctx)
      end
      reaper.ImGui_EndChild(ctx)
    end
    if theme.button_neutral(ctx, 'Back to form') then
      preview.stop()
      -- Drop preview files
      if s.previews then
        for _, p in ipairs(s.previews) do
          if p.audio_file_path and util.file_exists(p.audio_file_path) then
            os.remove(p.audio_file_path)
          end
        end
      end
      s.previews = nil
      s.stage = 'form'
    end
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    if theme.button_neutral(ctx, 'Cancel') then
      reset_state()
      reaper.ImGui_CloseCurrentPopup(ctx)
      reaper.ImGui_EndPopup(ctx)
      return 'cancel'
    end

  elseif s.stage == 'creating' then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.status_running)
    reaper.ImGui_Text(ctx, ('Creating voice "%s"... (typically 3-5 seconds)'):format(s.buf_name))
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_EndPopup(ctx)
  return nil
end

return M
