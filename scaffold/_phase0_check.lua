-- _phase0_check.lua
--
-- Walidator środowiska dla Reasonate (Faza 0 z docs/08-implementation-plan.md).
-- Uruchom przez Action List → "Load ReScript..." → wskaż ten plik.
-- Wynik wypisany do konsoli REAPER (View → Open Console).
--
-- Skrypt nie modyfikuje projektu, nie tworzy okien GUI, nie wywołuje API.
-- Sprawdza: REAPER, ReaImGui, curl, JS_ReaScriptAPI (opt), writable temp dir.

local function out(s)
  reaper.ShowConsoleMsg(s .. '\n')
end

local function fmt(...) return string.format(...) end

-- Wyczyść konsolę przed testem żeby output był czytelny
reaper.ShowConsoleMsg('')
reaper.ClearConsole()

out('=== Reasonate — Phase 0 environment check ===')
out('')

local pass_count, fail_count, warn_count = 0, 0, 0
local function pass(label, detail) pass_count = pass_count + 1; out(fmt('  [PASS] %s — %s', label, detail or 'ok')) end
local function fail(label, detail) fail_count = fail_count + 1; out(fmt('  [FAIL] %s — %s', label, detail or 'missing')) end
local function warn(label, detail) warn_count = warn_count + 1; out(fmt('  [WARN] %s — %s', label, detail or '')) end

-- 1. REAPER version ----------------------------------------------------------
out('1. REAPER version')
do
  local ver = reaper.GetAppVersion() or ''
  -- "7.28/macOS-arm64", "7.0/x64", etc.
  local major, minor = ver:match('^(%d+)%.(%d+)')
  major = tonumber(major); minor = tonumber(minor)
  if not major then
    fail('GetAppVersion', 'cannot parse: ' .. ver)
  elseif major < 7 then
    fail('REAPER >= 7.0', 'got ' .. ver)
  else
    pass('REAPER version', ver)
  end
end
out('')

-- 2. ReaImGui ----------------------------------------------------------------
out('2. ReaImGui')
do
  if not reaper.ImGui_GetVersion then
    fail('ReaImGui installed', 'ImGui_GetVersion missing — install via ReaPack: ReaTeam Extensions → ReaImGui')
  else
    -- Lua wariant zwraca trzy wartości: imgui_ver, imgui_ver_num, reaimgui_ver
    local imgui_ver, imgui_ver_num, reaimgui_ver = reaper.ImGui_GetVersion()
    pass('ReaImGui present', fmt('ImGui %s (build %s), ReaImGui %s',
      tostring(imgui_ver), tostring(imgui_ver_num), tostring(reaimgui_ver)))

    -- v0.10+ marker: ImGui_CreateFontFromFile (introduced in v0.10)
    if not reaper.ImGui_CreateFontFromFile then
      fail('ReaImGui >= 0.10', 'ImGui_CreateFontFromFile missing — update ReaImGui via ReaPack')
    else
      pass('ReaImGui >= 0.10', 'CreateFontFromFile available')
    end

    -- Drugi marker: PushFont z parametrem size (zmiana w v0.10)
    if not reaper.ImGui_PushFont then
      fail('ImGui_PushFont', 'missing')
    else
      pass('ImGui_PushFont', 'available (size argument expected per v0.10)')
    end

    -- Konstanty potrzebne dla tabeli/okna w fazie 1+
    local needed = {
      'ImGui_TableFlags_Borders',
      'ImGui_TableFlags_RowBg',
      'ImGui_TableFlags_Resizable',
      'ImGui_BeginTable',
      'ImGui_EndTable',
      'ImGui_BeginCombo',
      'ImGui_ProgressBar',
      'ImGui_BeginPopupModal',
    }
    local missing = {}
    for _, n in ipairs(needed) do
      if not reaper[n] then missing[#missing + 1] = n end
    end
    if #missing > 0 then
      fail('ImGui core widgets', 'missing: ' .. table.concat(missing, ', '))
    else
      pass('ImGui core widgets', fmt('%d/%d widgets present', #needed, #needed))
    end
  end
end
out('')

-- 3. curl --------------------------------------------------------------------
out('3. curl available to ExecProcess')
do
  -- ExecProcess(cmd, timeout_ms): pierwsza linia output to exit code,
  -- reszta to stdout (i ewentualnie stderr).
  --
  -- Uwaga (macOS): REAPER GUI nie dziedziczy PATH usera, więc 'curl' jako
  -- bare command może dać exit=-999 ("couldn't launch"). Próbujemy więc
  -- najpierw bare, potem fallback na typowe absolutne ścieżki.

  local function probe(cmd)
    local result = reaper.ExecProcess(cmd .. ' --version', 5000)
    if not result or result == '' then return nil, 'nil/empty' end
    local first_newline = result:find('\n')
    local exit_code = first_newline and result:sub(1, first_newline - 1) or result
    local body = first_newline and result:sub(first_newline + 1) or ''
    local first_line = body:match('([^\n]+)') or ''
    return exit_code, first_line
  end

  local IS_WIN = reaper.GetOS():find('Win') ~= nil
  local candidates = {'curl'}
  if IS_WIN then
    -- typowe lokalizacje na Win10+ (System32) i ewentualne instalacje
    candidates[#candidates+1] = 'C:\\Windows\\System32\\curl.exe'
  else
    candidates[#candidates+1] = '/usr/bin/curl'
    candidates[#candidates+1] = '/opt/homebrew/bin/curl'  -- macOS arm64 brew
    candidates[#candidates+1] = '/usr/local/bin/curl'     -- macOS intel brew / linux
  end

  local found_path, found_line
  for _, c in ipairs(candidates) do
    local code, line = probe(c)
    if code == '0' then
      found_path, found_line = c, line
      break
    end
  end

  if found_path then
    pass('curl resolvable', fmt('via "%s" — %s', found_path, found_line))
    if found_path ~= 'curl' then
      warn('curl PATH', 'bare "curl" nie działa z REAPER ExecProcess (typowe na macOS GUI). Workery i wywołania API będą używać absolutnej ścieżki: ' .. found_path)
    end
    -- Zapamiętaj dla przyszłych faz w ExtState — moduł api.lua to odczyta
    reaper.SetExtState('Reasonate', 'curl_path', found_path, true)
    pass('curl_path persisted', 'zapisane w ExtState["Reasonate"]["curl_path"]')
  else
    fail('curl', 'żadna z prób nie zwróciła exit 0: ' .. table.concat(candidates, ', '))
  end
end
out('')

-- 4. JS_ReaScriptAPI (optional) ---------------------------------------------
out('4. JS_ReaScriptAPI (optional)')
do
  if reaper.JS_File_GetAttributes then
    pass('JS_ReaScriptAPI', 'JS_File_GetAttributes available — fast file mtime')
  else
    warn('JS_ReaScriptAPI', 'not installed — file mtime fallback do shell out (działa, wolniej). Instalacja przez ReaPack opcjonalna.')
  end
end
out('')

-- 5. Resource paths + writable temp dir --------------------------------------
out('5. Resource paths')
do
  local res = reaper.GetResourcePath()
  if not res or res == '' then
    fail('GetResourcePath', 'empty')
  else
    pass('GetResourcePath', res)

    local sep = reaper.GetOS():find('Win') and '\\' or '/'
    local tmp_dir = res .. sep .. 'Scripts' .. sep .. 'reasonate_tmp'
    -- mkdir (natywnie — bez okna konsoli na Windows; 2026-07-12)
    reaper.RecursiveCreateDirectory(tmp_dir, 0)
    -- probe write
    local probe = tmp_dir .. sep .. '.phase0_probe'
    local f = io.open(probe, 'wb')
    if not f then
      fail('writable tmp dir', tmp_dir)
    else
      f:write('ok')
      f:close()
      local g = io.open(probe, 'rb')
      local ok = g and g:read('*a') == 'ok'
      if g then g:close() end
      os.remove(probe)
      if ok then
        pass('writable tmp dir', tmp_dir)
      else
        fail('writable tmp dir', 'wrote ale read mismatch — ' .. tmp_dir)
      end
    end
  end
end
out('')

-- 6. OS detection (informational) -------------------------------------------
out('6. OS')
do
  local os_str = reaper.GetOS()
  pass('reaper.GetOS()', os_str)
end
out('')

-- Summary --------------------------------------------------------------------
out('=== Summary ===')
out(fmt('  PASS: %d   FAIL: %d   WARN: %d', pass_count, fail_count, warn_count))
if fail_count == 0 then
  out('')
  out('Wynik: OK — można startować z Fazą 0 (reasonate.lua Hello World).')
else
  out('')
  out('Wynik: BLOCKED — najpierw napraw FAIL-e wyżej.')
end
