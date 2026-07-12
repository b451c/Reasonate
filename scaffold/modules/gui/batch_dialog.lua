-- modules/gui/batch_dialog.lua
-- NS-1: single-window batch lifecycle (confirm → progress → summary).
--
-- Non-blocking floating window (regular ImGui_Begin, NIE BeginPopupModal),
-- żeby user mógł paralelnie pracować w main Reasonate UI (zaznaczać itemy,
-- otwierać voice picker, audition) podczas batch'u.
--
-- States:
--   'closed'   — window hidden
--   'confirm'  — pre-batch UI: jobs list + cost estimate, [Cancel] [Convert N]
--   'progress' — batch in flight: progress bar + per-job statuses + [Cancel batch]
--   'summary'  — batch finished: stats + per-job breakdown, [Close]
--
-- Transitions:
--   confirm + Convert click  → caller dostaje request, woła transition_to_progress
--   progress + has_active==false → state=summary (auto)
--   summary + Close click    → state=closed
--   X (close button)         → confirm: closed (cancel); progress: hidden
--                              (X niedostępny); summary: closed
--
-- Variants flow: open_progress() bypassuje confirm — variants_dialog
-- już był confirm step (count slider).

local theme = require 'modules.theme'
local util  = require 'modules.util'

local M = {}

local WINDOW_NAME = 'Reasonate — Batch'

local s = {
  state         = 'closed',     -- 'closed' | 'confirm' | 'progress' | 'summary'
  pending_pos   = false,        -- one-shot SetNextWindowPos (re-center on state change)
  -- confirm payload
  jobs          = nil,
  skipped_done  = 0,
  cache_hits    = 0,
  -- request emit (consumed by reasonate.lua loop)
  ready         = nil,
  -- summary snapshot (frozen po batch end)
  summary_snap  = nil,
}

local CHARS_PER_SEC    = 50
local USD_PER_1K_CHARS = 0.05

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------
-- M6-3: uczciwa estymata per-job — średnia z UKOŃCZONYCH jobów TEGO batcha
-- (expected_duration usunięte w audit M1-2; overlay pokazywał "~0.0s").
-- Pierwszy job bez historii = pasek indeterminate (sawtooth) + sam elapsed.
-- Definicje NAD open_progress (Lua lexical scoping — KNOWN-ISSUES).
local _dur = { sum = 0, n = 0, seen = {} }

local function reset_job_durations()
  _dur.sum, _dur.n, _dur.seen = 0, 0, {}
end

local function record_job_duration(job)
  if job.started_at and job.finished_at then
    local key = tostring(job.id or job.item_guid or job)
    if not _dur.seen[key] then
      _dur.seen[key] = true
      _dur.sum = _dur.sum + math.max(0, job.finished_at - job.started_at)
      _dur.n   = _dur.n + 1
    end
  end
end

function M.is_active() return s.state ~= 'closed' end

function M.open_confirm(opts)
  s.state        = 'confirm'
  s.pending_pos  = true
  s.jobs         = opts.jobs or {}
  s.skipped_done = opts.skipped_done or 0
  s.cache_hits   = opts.cache_hits or 0
  s.ready        = nil
  s.summary_snap = nil
end

-- Bypass confirm — używane przez variants flow (variants_dialog jest
-- pre-confirm step z count sliderem).
function M.open_progress()
  s.state        = 'progress'
  s.pending_pos  = true
  s.jobs         = nil
  s.ready        = nil
  s.summary_snap = nil
  reset_job_durations()   -- M6-3: świeża historia estymat per batch
end

-- Caller wywołuje po enqueue_batch żeby przepchnąć z confirm w progress.
function M.transition_to_progress()
  s.state        = 'progress'
  s.pending_pos  = true
  s.summary_snap = nil
  reset_job_durations()   -- M6-3
end

function M.consume_request()
  local r = s.ready
  s.ready = nil
  return r
end

----------------------------------------------------------------------------
-- Visual map per job status (verified ASCII fallback dla glyph'ów żeby
-- uniknąć '?' fallback'u w Inter — patrz NS-3 lekcja).
-- ●○ verified Geometric Shapes (renderują w Inter); ✓✗ NIE verified —
-- używamy ASCII safe ('+' / 'x' / '.').
----------------------------------------------------------------------------
local STATUS_VISUAL = {
  queued    = { glyph = '·', color = nil,        label = 'queued'    },
  sending   = { glyph = '●', color = nil,        label = 'in flight' },  -- Geometric Shapes
  done      = { glyph = '+', color = 0x80E090FF, label = 'done'      },
  error     = { glyph = 'x', color = 0xFF6464FF, label = 'error'     },
  cancelled = { glyph = '-', color = 0x808080FF, label = 'cancelled' },
}

----------------------------------------------------------------------------
-- Confirm state
----------------------------------------------------------------------------
local function group_by_voice(jobs)
  local map = {}
  for _, j in ipairs(jobs) do
    local key = j.voice_name or '?'
    map[key] = (map[key] or 0) + 1
  end
  local arr = {}
  for k, v in pairs(map) do arr[#arr + 1] = { name = k, count = v } end
  table.sort(arr, function(a, b) return a.count > b.count end)
  return arr
end

local function render_confirm(ctx, jm)
  local jobs = s.jobs or {}
  local n_items = #jobs
  local total_seconds = 0
  local api_seconds   = 0
  for _, j in ipairs(jobs) do
    local secs = j.audio_seconds or 0
    total_seconds = total_seconds + secs
    if not j.cache_hit then api_seconds = api_seconds + secs end
  end
  local est_chars = math.ceil(api_seconds * CHARS_PER_SEC)
  local est_usd   = est_chars * USD_PER_1K_CHARS / 1000
  local api_call_count = n_items - (s.cache_hits or 0)

  reaper.ImGui_TextWrapped(ctx, ('Convert %d item%s?'):format(
    n_items, n_items == 1 and '' or 's'))
  reaper.ImGui_Spacing(ctx)

  if (s.skipped_done or 0) > 0 then
    reaper.ImGui_TextDisabled(ctx, ('(%d already up-to-date — skipped)')
      :format(s.skipped_done))
  end
  if (s.cache_hits or 0) > 0 then
    reaper.ImGui_TextColored(ctx, 0x80E090FF,
      ('Cache hits: %d (instant, no API call)'):format(s.cache_hits))
  end

  reaper.ImGui_Text(ctx, ('Total audio:  %.1f seconds (~%.1f minutes)')
    :format(total_seconds, total_seconds / 60))
  reaper.ImGui_Text(ctx, ('Est. API cost: ~%d characters (~$%.4f at $%.2f/1k) for %d call%s')
    :format(est_chars, est_usd, USD_PER_1K_CHARS, api_call_count,
            api_call_count == 1 and '' or 's'))

  local groups = group_by_voice(jobs)
  if #groups > 0 then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, 'Voices:')
    for _, g in ipairs(groups) do
      reaper.ImGui_BulletText(ctx, ('%d × %s'):format(g.count, g.name))
    end
  end

  if n_items <= 8 then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    for _, j in ipairs(jobs) do
      reaper.ImGui_BulletText(ctx, ('%s · %.1fs'):format(
        j.item_label or '?', j.audio_seconds or 0))
    end
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), theme.COLORS.text_dim)
  reaper.ImGui_TextWrapped(ctx,
    'Items with existing AI output: new take appended (Tab in REAPER cycles takes).')
  reaper.ImGui_TextWrapped(ctx,
    ('Concurrency = %d (change in Settings). Cancel keeps in-flight jobs.')
      :format(jm.max_concurrent or 3))
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  if theme.button_neutral(ctx, 'Cancel##bd_cancel', 100, 0) then
    s.state = 'closed'
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)

  if theme.button_primary(ctx, ('Convert (%d)##bd_go'):format(n_items), 150, 0) then
    s.ready = { jobs = s.jobs }
    -- caller (reasonate.lua loop) wywoła enqueue_batch + transition_to_progress
  end
end

----------------------------------------------------------------------------
-- Progress state
----------------------------------------------------------------------------
local cancel_pending_open = false

local function render_cancel_confirm(ctx, jm)
  if cancel_pending_open then
    reaper.ImGui_OpenPopup(ctx, 'Cancel batch?##bd_cancel_popup')
    cancel_pending_open = false
  end
  theme.center_next_modal(ctx, 440, 0)
  theme.popup_keep_top(ctx, 'Cancel batch?##bd_cancel_popup')
  local visible, p_open = reaper.ImGui_BeginPopupModal(ctx, 'Cancel batch?##bd_cancel_popup', true,
    reaper.ImGui_WindowFlags_NoCollapse())
  if not visible then return end
  if not p_open then reaper.ImGui_CloseCurrentPopup(ctx) end

  reaper.ImGui_TextWrapped(ctx,
    ('In-flight jobs (%d) will finish; queued jobs (%d) will be dropped.')
      :format(jm.active_count(), jm.queue_length()))
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  if theme.button_neutral(ctx, 'Keep going##bd_keep', 120, 0) then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
  if theme.button_danger(ctx, 'Cancel batch##bd_cancel_yes', 140, 0) then
    jm.cancel_all()
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

-- PM9 iter3: truncate label żeby per-job ProgressBar zawsze fit w viewport
-- (UX issue: long source filenames push'ują bar poza window boundary).
-- Middle truncation (40% head + '...' + 60% tail) zachowuje początek nazwy
-- pliku i koniec (voice name) — oba relevant dla identyfikacji jobu.
local MAX_LABEL_LEN = 60

local function truncate_middle(s, max)
  if #s <= max then return s, false end
  local body = max - 3  -- 3 chars for "..."
  local head_n = math.floor(body * 0.4)
  local tail_n = body - head_n
  return s:sub(1, head_n) .. '...' .. s:sub(#s - tail_n + 1), true
end

local function render_job_row(ctx, job, jm)
  local vis = STATUS_VISUAL[job.status] or STATUS_VISUAL.queued
  if vis.color then
    reaper.ImGui_TextColored(ctx, vis.color, vis.glyph)
  else
    reaper.ImGui_Text(ctx, vis.glyph)
  end
  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)

  local full_label = ('%s → %s'):format(
    job.item_label or (job.source_item_guid or '?'):sub(2, 9),
    job.voice_name or '?')
  local label, was_truncated = truncate_middle(full_label, MAX_LABEL_LEN)
  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, label)
  if was_truncated and reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, full_label)
  end

  -- Per-job bar shows during active processing. Detection via timestamps
  -- (started_at set, finished_at not yet set) — bardziej robust niż status
  -- string check. job_manager nigdy nie ustawia status='sending' (legacy
  -- field name z dawnego API), używamy timestamps mirror M.has_active.
  record_job_duration(job)
  if job.started_at and not job.finished_at then
    local elapsed = util.now() - job.started_at
    -- M6-3: estymata ze średniej ukończonych jobów; bez historii = sawtooth.
    local avg = _dur.n > 0 and (_dur.sum / _dur.n) or nil
    local progress_est = avg
      and math.min(0.95, elapsed / math.max(0.1, avg))
      or ((elapsed % 3.0) / 3.0)
    reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
    -- W cancelled state per-job bar gray (in-flight finishing naturally per
    -- niezmiennik #7) zamiast amber primary — visual signal że to się kończy.
    local bar_color = (jm and jm.is_cancelled()) and theme.COLORS.text_muted
      or theme.COLORS.primary
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PlotHistogram(), bar_color)
    -- Opaque bar bg lokalnie — global frame_bg ma reduced alpha (~B0) dla
    -- bg.png prześwitu, ale ProgressBar potrzebuje solidne tło żeby pasek
    -- był widoczny przy 0% fill (PM9 iter3 fix).
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x2D2D2DFF)
    -- Bar height musi pomieścić Inter overlay text (~17px tall) +
    -- vertical padding. 20 jest bezpieczne; 14 ucinało tekst u dołu.
    reaper.ImGui_ProgressBar(ctx, progress_est, 160, 20,
      avg and ('%.1fs / ~%.1fs'):format(elapsed, avg)
          or ('%.1fs'):format(elapsed))
    reaper.ImGui_PopStyleColor(ctx, 2)
  end
  if job.status == 'error' and job.error_msg then
    theme.push_caption(ctx)
    reaper.ImGui_TextColored(ctx, 0xFF6464FF, '   ' .. job.error_msg)
    theme.pop_caption(ctx)
  end
end

local function render_progress(ctx, jm)
  local stats     = jm.get_stats()
  local active_n  = jm.active_count()
  local queue_len = jm.queue_length()
  local resolved  = (stats.done or 0) + (stats.error or 0) + (stats.cancelled or 0)
  local pct       = (stats.total or 0) > 0 and (resolved / stats.total) or 0

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PlotHistogram(), theme.COLORS.primary)
  -- Opaque bar bg lokalnie — global frame_bg ma reduced alpha (~B0) dla
  -- bg.png prześwitu, ale main batch ProgressBar potrzebuje solidne tło
  -- żeby pasek był widoczny przy 0% fill (PM9 iter3 regresja fix).
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x2D2D2DFF)
  local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  reaper.ImGui_ProgressBar(ctx, pct, math.max(220, avail_w - 150), 22,
    ('%d / %d'):format(resolved, stats.total or 0))
  reaper.ImGui_PopStyleColor(ctx, 2)

  reaper.ImGui_SameLine(ctx, 0, theme.SPACING.md)
  if not jm.is_cancelled() then
    -- Auto-size button do content (drop fixed 130×22 — text alignment issue
    -- gdy width nie matches text+padding). ImGui sam dobiera optimal size.
    -- Label "Cancel queued" (NIE "Cancel batch") — clarifies że queued jobs
    -- are dropped, in-flight finish naturally per niezmiennik #7.
    if theme.button_danger(ctx, 'Cancel queued##bd_jcancel') then
      cancel_pending_open = true
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Drops queued jobs; in-flight curl processes finish naturally\n' ..
        '(prevents corrupt audio mid-stream).')
    end
  else
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_TextDisabled(ctx, 'Cancelled — finishing in-flight…')
  end

  -- Stats caption
  theme.push_caption(ctx)
  local extras = {}
  if (stats.cache_hits or 0) > 0 then extras[#extras+1] = ('%d cache'):format(stats.cache_hits) end
  if (stats.retries  or 0) > 0  then extras[#extras+1] = ('%d retries'):format(stats.retries)  end
  if (stats.error    or 0) > 0  then extras[#extras+1] = ('%d error'):format(stats.error)  end
  if (stats.cancelled or 0) > 0 then extras[#extras+1] = ('%d cancelled'):format(stats.cancelled) end
  reaper.ImGui_TextDisabled(ctx,
    ('%d active · %d queued · %d done%s'):format(
      active_n, queue_len, stats.done or 0,
      #extras > 0 and ('  ·  ' .. table.concat(extras, ' · ')) or ''))
  theme.pop_caption(ctx)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Per-job rows (scrollable). Per-row height = ImGui frame height z spacing
  -- (zawiera progress bar + label + framing). Plus generous bottom pad
  -- żeby zostawić miejsce na error caption (drugi line gdy job.status=='error').
  local jobs = jm.get_batch_jobs()
  local row_h = reaper.ImGui_GetFrameHeightWithSpacing(ctx)
  local content_h = #jobs * row_h + 8
  local CHILD_H = math.min(260, math.max(row_h + 8, content_h))
  local child_visible = reaper.ImGui_BeginChild(ctx, 'bd_jobs_scroll', -1, CHILD_H)
  if child_visible then
    for _, job in ipairs(jobs) do
      render_job_row(ctx, job, jm)
    end
    reaper.ImGui_EndChild(ctx)
  end
end

----------------------------------------------------------------------------
-- Summary state
----------------------------------------------------------------------------
local function build_summary_snap(jm)
  local stats = jm.get_stats()
  local elapsed = (stats.finished_at or util.now()) - (stats.started_at or util.now())
  local jobs = {}
  for _, j in ipairs(jm.get_batch_jobs()) do
    jobs[#jobs + 1] = {
      item_label  = j.item_label or '?',
      voice_name  = j.voice_name or '?',
      status      = j.status or 'unknown',
      error_msg   = j.error_msg,
      retry_count = j.retry_count or 0,
    }
  end
  return {
    total      = stats.total or 0,
    done       = stats.done or 0,
    error      = stats.error or 0,
    cancelled  = stats.cancelled or 0,
    cache_hits = stats.cache_hits or 0,
    retries    = stats.retries or 0,
    elapsed    = elapsed,
    jobs       = jobs,
  }
end

local function render_summary(ctx)
  local sm = s.summary_snap
  if not sm then return end

  local headline_color = theme.COLORS.status_done
  local headline = 'Done'
  if (sm.error or 0) > 0 then
    headline_color = theme.COLORS.status_error
    headline = ('Done with %d error%s'):format(sm.error, sm.error == 1 and '' or 's')
  elseif (sm.cancelled or 0) > 0 then
    headline_color = theme.COLORS.status_pending
    headline = ('Cancelled (%d cancelled)'):format(sm.cancelled)
  end
  theme.push_heading(ctx)
  reaper.ImGui_TextColored(ctx, headline_color, headline)
  theme.pop_heading(ctx)

  reaper.ImGui_Spacing(ctx)

  theme.push_caption(ctx)
  local parts = {
    ('%d / %d converted'):format(sm.done, sm.total),
    ('%.1fs elapsed'):format(sm.elapsed),
  }
  if sm.cache_hits > 0 then parts[#parts+1] = ('%d cache hit%s'):format(sm.cache_hits, sm.cache_hits == 1 and '' or 's') end
  if sm.retries > 0    then parts[#parts+1] = ('%d retr%s'):format(sm.retries, sm.retries == 1 and 'y' or 'ies')  end
  if sm.error > 0      then parts[#parts+1] = ('%d error%s'):format(sm.error, sm.error == 1 and '' or 's') end
  if sm.cancelled > 0  then parts[#parts+1] = ('%d cancelled'):format(sm.cancelled) end
  reaper.ImGui_TextDisabled(ctx, table.concat(parts, ' · '))
  theme.pop_caption(ctx)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  local row_h = reaper.ImGui_GetFrameHeightWithSpacing(ctx)
  local CHILD_H = math.min(320, math.max(row_h + 8, #sm.jobs * row_h + 8))
  local child_visible = reaper.ImGui_BeginChild(ctx, 'bd_summary_scroll', -1, CHILD_H)
  if child_visible then
    for _, j in ipairs(sm.jobs) do
      local vis = STATUS_VISUAL[j.status] or STATUS_VISUAL.queued
      if vis.color then
        reaper.ImGui_TextColored(ctx, vis.color, vis.glyph)
      else
        reaper.ImGui_Text(ctx, vis.glyph)
      end
      reaper.ImGui_SameLine(ctx, 0, theme.SPACING.sm)
      reaper.ImGui_AlignTextToFramePadding(ctx)
      local retry_suffix = j.retry_count > 0 and (' (after %d retries)'):format(j.retry_count) or ''
      reaper.ImGui_Text(ctx, ('%s → %s%s'):format(
        j.item_label, j.voice_name, retry_suffix))
      if j.status == 'error' and j.error_msg then
        theme.push_caption(ctx)
        reaper.ImGui_TextColored(ctx, 0xFF6464FF, '   ' .. j.error_msg)
        theme.pop_caption(ctx)
      end
    end
    reaper.ImGui_EndChild(ctx)
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  if theme.button_primary(ctx, 'Close##bd_close', 120, 0) then
    s.state = 'closed'
  end
end

----------------------------------------------------------------------------
-- Main render — every frame
-- opts: { main_geom = {cx, cy} } — center coords of main Reasonate window
----------------------------------------------------------------------------
function M.render(ctx, jm, opts)
  opts = opts or {}

  -- Auto-transition progress → summary
  if s.state == 'progress' then
    if not jm.has_active() and (jm.get_stats().total or 0) > 0 then
      s.summary_snap = build_summary_snap(jm)
      s.state        = 'summary'
      s.pending_pos  = true   -- re-center on auto-state-transition
    end
  end

  -- Cancel-confirm popup zawsze (no-op gdy zamknięty) — żeby modal zachowywał
  -- się idempotentnie pomiędzy stanami.
  render_cancel_confirm(ctx, jm)

  if s.state == 'closed' then return end

  -- Re-center on every state change (Cond_Always with pivot 0.5,0.5 means
  -- pos arg = where the window CENTER should appear). main_geom captured w
  -- frame() podczas main Begin scope — pos aktualnego Reasonate main window.
  if s.pending_pos and opts.main_geom then
    reaper.ImGui_SetNextWindowPos(ctx,
      opts.main_geom.cx, opts.main_geom.cy,
      reaper.ImGui_Cond_Always(), 0.5, 0.5)
  end
  s.pending_pos = false

  -- Sizing per state:
  --   confirm — AlwaysAutoResize (małe content, nie warto explicit size).
  --   progress + summary — TA SAMA explicit size 720x560 z Cond_Always.
  --     Wcześniej summary używał AutoResize → user widział "shrink" effect
  --     po batch end (progress big, summary small, frame lag w resize).
  --     Trzymanie tej samej wielkości eliminuje wizualny jump.
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 560, 0, 1400, 4096)
  if s.state == 'progress' or s.state == 'summary' then
    reaper.ImGui_SetNextWindowSize(ctx, 720, 560, reaper.ImGui_Cond_Always())
  end

  local flags = reaper.ImGui_WindowFlags_NoCollapse()
              | reaper.ImGui_WindowFlags_NoSavedSettings()
  if s.state == 'confirm' then
    flags = flags | reaper.ImGui_WindowFlags_AlwaysAutoResize()
  end

  -- Per-state close-button policy:
  --   confirm  → X visible (X = cancel)
  --   progress → no X (force user przez Cancel batch button)
  --   summary  → X visible (X = close)
  local p_open
  if s.state == 'progress' then
    p_open = nil
  else
    p_open = true
  end

  local visible, open = reaper.ImGui_Begin(ctx, WINDOW_NAME, p_open, flags)
  if visible then
    if s.state == 'confirm' then
      render_confirm(ctx, jm)
    elseif s.state == 'progress' then
      render_progress(ctx, jm)
    elseif s.state == 'summary' then
      render_summary(ctx)
    end
    reaper.ImGui_End(ctx)
  end

  if p_open ~= nil and open == false then
    s.state = 'closed'
  end
end

return M
