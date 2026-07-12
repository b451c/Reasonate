-- modules/preview.lua
-- Wspólny CF_Preview wrapper (SWS extension) — jeden global preview na raz,
-- z auto-stop po końcu source'a. Używany przez Voice Picker i Audition Panel.
--
-- Wymaga SWS (większość userów ma); fallback na external `open` jeśli brak.
-- preview_url może też być URL — wtedy download do tmp + play.

local util   = require 'modules.util'
local config = require 'modules.config'

local M = {}

----------------------------------------------------------------------------
-- State (singleton — jeden preview na raz w obrębie skryptu)
----------------------------------------------------------------------------
local state = {
  preview     = nil,    -- CF_Preview object
  source      = nil,    -- PCM_source — destroy ręcznie po Stop
  identifier  = nil,    -- string ID (do is_playing(id) checku)
  started_at  = nil,
  duration    = nil,
}

local function path_sep() return util.path_sep() end

local function tmp_dir()
  return reaper.GetResourcePath() .. path_sep() .. 'Scripts' .. path_sep() .. 'reasonate_tmp'
end

----------------------------------------------------------------------------
-- Public
----------------------------------------------------------------------------
function M.is_playing(identifier)
  if not state.preview then return false end
  if identifier == nil then return true end
  return state.identifier == identifier
end

function M.stop()
  if state.preview and reaper.CF_Preview_Stop then
    reaper.CF_Preview_Stop(state.preview)
  end
  state.preview = nil
  if state.source and reaper.PCM_Source_Destroy then
    reaper.PCM_Source_Destroy(state.source)
  end
  state.source = nil
  state.identifier = nil
  state.started_at = nil
  state.duration = nil
end

-- Play file via CF_Preview (in-app) lub fallback na system default app.
-- Returns: true (started) or false, err
function M.play_file(path, identifier, opts)
  opts = opts or {}
  if not path or path == '' or not util.file_exists(path) then
    return false, 'file not found: ' .. tostring(path)
  end

  if reaper.CF_CreatePreview then
    M.stop()
    local source = reaper.PCM_Source_CreateFromFile(path)
    if not source then return false, 'PCM_Source_CreateFromFile failed' end
    local p = reaper.CF_CreatePreview(source)
    if not p then
      if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(source) end
      return false, 'CF_CreatePreview failed'
    end
    if reaper.CF_Preview_SetValue then
      reaper.CF_Preview_SetValue(p, 'D_VOLUME', opts.volume or 0.8)
    end
    reaper.CF_Preview_Play(p)
    state.preview    = p
    state.source     = source
    state.identifier = identifier
    state.started_at = util.now()
    state.duration   = reaper.GetMediaSourceLength(source)
    return true
  end

  -- Fallback: external player (no SWS installed)
  local os_str = reaper.GetOS()
  local cmd
  if os_str:find('Win') then
    cmd = 'cmd /c start "" ' .. util.shell_escape(path)
  elseif os_str:find('OSX') or os_str:find('macOS') then
    cmd = '/usr/bin/open ' .. util.shell_escape(path)
  else
    cmd = 'xdg-open ' .. util.shell_escape(path)
  end
  -- exec_hidden (2026-07-12): na Windows 'cmd /c start' błyskał własną
  -- konsolą zanim otworzył player — teraz konsola od razu ukryta.
  util.exec_hidden(cmd)
  state.identifier = identifier  -- nie mamy CF_Preview ale chcemy badge play state
  state.started_at = util.now()
  state.duration   = 5            -- assumption fallback (nie wiemy real)
  return true
end

-- NS-F: Play file z określonego zakresu (start_sec, end_sec). Używane dla
-- per-word preview w Repair mode. CF_Preview API ma D_POSITION dla start;
-- stop monitorujemy w tick() po (end_sec - start_sec) duration.
function M.play_file_range(path, start_sec, end_sec, identifier, opts)
  opts = opts or {}
  if not path or path == '' or not util.file_exists(path) then
    return false, 'file not found: ' .. tostring(path)
  end
  if end_sec <= start_sec then return false, 'invalid range' end

  if reaper.CF_CreatePreview then
    M.stop()
    local source = reaper.PCM_Source_CreateFromFile(path)
    if not source then return false, 'PCM_Source_CreateFromFile failed' end
    local p = reaper.CF_CreatePreview(source)
    if not p then
      if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(source) end
      return false, 'CF_CreatePreview failed'
    end
    if reaper.CF_Preview_SetValue then
      reaper.CF_Preview_SetValue(p, 'D_VOLUME',   opts.volume or 0.8)
      reaper.CF_Preview_SetValue(p, 'D_POSITION', math.max(0, start_sec))
    end
    reaper.CF_Preview_Play(p)
    state.preview    = p
    state.source     = source
    state.identifier = identifier
    state.started_at = util.now()
    -- Duration limit dla tick() auto-stop po reach end_sec
    state.duration   = math.max(0.05, end_sec - start_sec)
    return true
  end

  -- Fallback bez CF_Preview: open whole file in external player (no range support)
  return M.play_file(path, identifier, opts)
end

-- Download URL do tmp + play. Sync (krótki freeze ~1s na download).
function M.play_url(url, identifier, opts)
  if not url or url == '' then return false, 'no url' end
  util.mkdir_p(tmp_dir())
  -- Hash URL do stabilnej nazwy pliku → cache między klikami
  local fname = ('preview_%s.mp3'):format(util.simple_hash(url))
  local out = tmp_dir() .. path_sep() .. fname
  if not util.file_exists(out) or (util.file_size(out) or 0) < 1024 then
    local cmd = table.concat({
      util.shell_escape(config.get_curl_path()),
      '-sSL', '--max-time', '10',
      '-o', util.shell_escape(out),
      util.shell_escape(url),
    }, ' ')
    reaper.ExecProcess(cmd, 12000)
  end
  return M.play_file(out, identifier, opts)
end

-- Wywoływane KAŻDY frame (z głównego defer loopa) — auto-stop po końcu.
function M.tick()
  if state.started_at and state.duration then
    if (util.now() - state.started_at) >= (state.duration + 0.2) then
      M.stop()
    end
  end
end

reaper.atexit(function()
  if reaper.CF_Preview_StopAll then reaper.CF_Preview_StopAll() end
end)

return M
