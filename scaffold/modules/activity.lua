-- modules/activity.lua
-- Pakiet A (W3, 2026-06-10): collector aktywności dla globalnego paska w
-- stopce ("jeden pasek prawdy"). PULL model — co klatkę DERYWUJE listę z
-- istniejącego stanu trybów (zero rejestracji, zero pisania → nie może się
-- rozjechać ze stanem; nowy tryb = nowy collect_* tutaj). Rdzeń nie woła
-- reaper API — headless-testowany w tests/run.lua. Części reaper-zależne
-- (batch VR z job_manager, recording) wchodzą przez `deps` z call site
-- w reasonate.lua.
--
-- Entry: { id, label, done?, total?, kind = 'running'|'error'|'record',
--          tooltip?, retry? } — retry to bezargumentowa closure (footer
-- woła ją po kliku [Retry]). Labels = UI strings → ENGLISH ONLY.

local M = {}

local function count_keys(t)
  if type(t) ~= 'table' then return 0 end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- Handle "żyje" w obu konwencjach statusów spotykanych w codebase
-- (voice_admin/llm: 'running'; stt: 'pending').
local function is_live(h)
  return type(h) == 'table' and (h.status == 'running' or h.status == 'pending')
end

local function push(out, e) out[#out + 1] = e end

----------------------------------------------------------------------------
-- TTS (single + dialogue) — pojedyncze handle + mapy regen per item.
----------------------------------------------------------------------------
local function collect_tts(s, out)
  if not s then return end
  if is_live(s.gen_handle) then
    local label = 'TTS · generating'
    if (s.variants_remaining or 0) > 0 then
      label = ('TTS · variants (%d left)'):format(s.variants_remaining)
    end
    push(out, { id = 'tts_gen', kind = 'running', label = label })
  end
  if is_live(s.dialogue_gen_handle) then
    -- Variants ×3 w dialogu usunięte (s4) — jedna stała etykieta.
    push(out, { id = 'tts_dialogue', kind = 'running', label = 'TTS · dialogue generating' })
  end
  if is_live(s.dialogue_split_handle) then
    push(out, { id = 'tts_split', kind = 'running', label = 'TTS · splitting speakers' })
  end
  if is_live(s.enhance_handle) then
    push(out, { id = 'tts_enhance', kind = 'running', label = 'TTS · enhancing (audio tags)' })
  end
  if is_live(s.take_align_handle) then
    push(out, { id = 'tts_take_align', kind = 'running', label = 'TTS · aligning line timings' })
  end
  local regen = count_keys(s.row_handles) + count_keys(s.dialogue_row_handles)
              + count_keys(s.dialogue_split_regen_handles)
  if regen > 0 then
    push(out, { id = 'tts_regen', kind = 'running',
      label = (regen == 1) and 'TTS · regenerating take'
                           or ('TTS · regenerating %d takes'):format(regen) })
  end
end

----------------------------------------------------------------------------
-- Dubbing — fazy pipeline'u + pompy translate/generate (progress i/n
-- liczony z translation_status/dub_status) + failed translations z Retry.
----------------------------------------------------------------------------
local function collect_dubbing(state, s, out)
  if not s then return end
  local phase = s.phase or 'idle'
  if phase == 'starting' or phase == 'isolating' then
    push(out, { id = 'dub_iso', kind = 'running', label = 'Dubbing · isolating voice' })
  elseif phase == 'chunking' then
    push(out, { id = 'dub_chunk', kind = 'running', label = 'Dubbing · rendering chunks' })
  elseif phase == 'transcribing' then
    local total = #(s.chunks_plan or {})
    if total > 0 then
      push(out, { id = 'dub_stt', kind = 'running', label = 'Dubbing · transcribing',
                  done = count_keys(s.chunks_results), total = total })
    else
      -- Flow B (multi-track source): per-item STT, brak chunk planu.
      local n = count_keys(s.flow_b_item_handles)
      push(out, { id = 'dub_stt', kind = 'running',
        label = (n > 0) and ('Dubbing · transcribing %d item(s)'):format(n)
                         or 'Dubbing · transcribing' })
    end
  end

  local proj = s.project
  local lang = proj and proj.active_target_language
  if proj and lang then
    if s.translate_pending or count_keys(s.translate_handles) > 0 then
      local total, done = 0, 0
      for _, seg in ipairs(proj.segments or {}) do
        if not seg.dub_excluded then
          total = total + 1
          if seg.translation_status and seg.translation_status[lang] == 'translated' then
            done = done + 1
          end
        end
      end
      push(out, { id = 'dub_translate', kind = 'running',
                  label = 'Dubbing · translating', done = done, total = total })
    end
    if s.generate_pending or count_keys(s.tts_handles) > 0
       or count_keys(s.align_handles) > 0 then
      local total, done = 0, 0
      for _, seg in ipairs(proj.segments or {}) do
        if not seg.dub_excluded then
          local text = seg.translations and seg.translations[lang]
          if text and text ~= '' then
            total = total + 1
            if seg.dub_status and seg.dub_status[lang] == 'generated' then
              done = done + 1
            end
          end
        end
      end
      push(out, { id = 'dub_generate', kind = 'running',
                  label = 'Dubbing · generating dub', done = done, total = total })
    end

    -- Terminalne porażki tłumaczeń → chip error z [Retry].
    -- request_translate_all resetuje failed→pending (M1-4b) — chip znika
    -- natychmiast po kliku, pompa podnosi segmenty w next tick.
    local failed, first_err = 0, nil
    for _, seg in ipairs(proj.segments or {}) do
      if seg.translation_status and seg.translation_status[lang] == 'failed' then
        failed = failed + 1
        if not first_err then
          first_err = ('%s — %s'):format(tostring(seg.id or '?'),
            (seg.translation_error and seg.translation_error[lang]) or 'unknown error')
        end
      end
    end
    if failed > 0 then
      push(out, {
        id = 'dub_failed', kind = 'error',
        label = (failed == 1) and '1 translation failed'
                               or ('%d translations failed'):format(failed),
        tooltip = ('First failure: %s\n\nRetry re-runs every failed segment.'):format(first_err),
        retry = function()
          -- Lazy require: activity core zostaje czysty dla headless testów.
          require('modules.modes.dubbing').request_translate_all(state)
        end,
      })
    end

    -- W3 Pakiet B+: terminalne porażki GENEROWANIA dubu (TTS/splice) → chip
    -- error z [Retry] (mirror failed translations; request_generate_dub
    -- resetuje failed→pending, pompa podnosi segmenty w next tick).
    local gen_failed, gen_first_err = 0, nil
    for _, seg in ipairs(proj.segments or {}) do
      if seg.dub_status and seg.dub_status[lang] == 'failed' then
        gen_failed = gen_failed + 1
        if not gen_first_err then
          gen_first_err = ('%s — %s'):format(tostring(seg.id or '?'),
            (seg.dub_error and seg.dub_error[lang]) or 'unknown error')
        end
      end
    end
    if gen_failed > 0 then
      push(out, {
        id = 'dub_gen_failed', kind = 'error',
        label = (gen_failed == 1) and '1 dub failed'
                                   or ('%d dubs failed'):format(gen_failed),
        tooltip = ('First failure: %s\n\nRetry re-runs every failed segment.'):format(gen_first_err),
        retry = function()
          require('modules.modes.dubbing').request_generate_dub(state)
        end,
      })
    end
  end

  local clones = count_keys(s.clone_handles)
  if clones > 0 then
    push(out, { id = 'dub_clone', kind = 'running',
      label = (clones == 1) and 'Dubbing · training voice clone'
                             or ('Dubbing · training %d voice clones'):format(clones) })
  end
  if count_keys(s.similar_handles) + count_keys(s.similar_more_handles) > 0 then
    push(out, { id = 'dub_similar', kind = 'running', label = 'Dubbing · finding similar voices' })
  end
end

----------------------------------------------------------------------------
-- Repair — dwie maszyny stanów (STT pipeline + regen) + clone flow.
----------------------------------------------------------------------------
local STT_STAGE_LABELS = {
  preparing_isolate = 'Repair · cleaning audio',
  transcribing      = 'Repair · transcribing',
  aligning_source   = 'Repair · aligning words',
}
local REGEN_STAGE_LABELS = {
  tts          = 'Repair · generating TTS',
  aligning_tts = 'Repair · aligning TTS',
  splicing     = 'Repair · splicing',
}

local function collect_repair(s, out)
  if not s then return end
  local l = STT_STAGE_LABELS[s.stt_state]
  if l then push(out, { id = 'rep_stt', kind = 'running', label = l }) end
  l = REGEN_STAGE_LABELS[s.regen_state]
  if l then push(out, { id = 'rep_regen', kind = 'running', label = l }) end
  if is_live(s.clone_train_handle) then
    push(out, { id = 'rep_clone', kind = 'running', label = 'Repair · training voice clone' })
  end
  if is_live(s.clone_diarize_handle) then
    push(out, { id = 'rep_diarize', kind = 'running', label = 'Repair · analyzing speakers' })
  end
end

----------------------------------------------------------------------------
-- SFX & Music — generacje (gen_entries) + scene pipeline + rephrase.
----------------------------------------------------------------------------
local function collect_sfx(s, out)
  if not s then return end
  local n = #(s.gen_entries or {})
  if n > 0 then
    push(out, { id = 'sfx_gen', kind = 'running',
      label = (n == 1) and 'SFX · generating 1 take'
                        or ('SFX · generating %d takes'):format(n) })
  end
  if s.scene_phase == 'transcribing' then
    push(out, { id = 'sfx_scene', kind = 'running', label = 'SFX · transcribing scene' })
  elseif s.scene_phase == 'analyzing' then
    push(out, { id = 'sfx_scene', kind = 'running', label = 'SFX · asking AI for sound ideas' })
  end
  local re = 0
  for _, cand in ipairs(s.scene_candidates or {}) do
    if cand.rephrase_handle then re = re + 1 end
  end
  if re > 0 then
    push(out, { id = 'sfx_rephrase', kind = 'running', label = 'SFX · rephrasing idea' })
  end
end

----------------------------------------------------------------------------
-- Public: collect(state, deps) → activities[]
-- deps (opcjonalne, reaper-zależne — wstrzykiwane z reasonate.lua):
--   job_stats  = job_manager.get_stats()   (tylko gdy job_manager.has_active())
--   recording  = { elapsed = secs, pre_roll = bool }   (tylko gdy aktywne)
----------------------------------------------------------------------------
function M.collect(state, deps)
  local out = {}
  deps = deps or {}

  local js = deps.job_stats
  if js then
    local done = (js.done or 0) + (js.error or 0) + (js.cancelled or 0)
    push(out, { id = 'vr_batch', kind = 'running', label = 'Converting',
      done = done, total = js.total or 0,
      tooltip = ((js.error or 0) > 0)
        and ('%d item(s) failed so far — per-item details in the batch summary.'):format(js.error)
        or nil })
  end

  local rec = deps.recording
  if rec then
    local secs = math.max(0, math.floor(rec.elapsed or 0))
    push(out, { id = 'rec', kind = 'record',
      label = rec.pre_roll and 'REC · pre-roll'
                            or ('REC %d:%02d'):format(secs // 60, secs % 60) })
  end

  local modes = state and state.modes or {}
  collect_tts(modes.tts, out)
  collect_dubbing(state, modes.dubbing, out)
  collect_repair(modes.repair, out)
  collect_sfx(modes.sfx, out)
  return out
end

return M
