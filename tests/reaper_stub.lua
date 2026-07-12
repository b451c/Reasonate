-- tests/reaper_stub.lua — minimalna atrapa REAPER API dla testów headless.
-- Pokrywa WYŁĄCZNIE to, czego moduły pure-logic (util / cache / tempo_math /
-- lib.json) potrzebują w momencie require() i w testowanych ścieżkach.
-- NIE symuluje REAPER-a — testy UI/audio pozostają manualne (VALIDATION.md).

local ext = {}

return {
  GetOS           = function() return 'OSX64' end,
  GetResourcePath = function() return '/tmp/reasonate-test-resource' end,
  -- Realny mkdir (testy cache/housekeeping piszą prawdziwe pliki w /tmp).
  RecursiveCreateDirectory = function(path, _)
    os.execute(("mkdir -p '%s'"):format(path))
    return 1
  end,
  ShowConsoleMsg  = function(_) end,
  time_precise    = function() return os.clock() end,
  -- Realna enumeracja przez ls — testy housekeeping/cache operują na
  -- prawdziwych plikach w /tmp/reasonate-test-resource.
  EnumerateFiles  = function(path, i)
    local fh = io.popen(("ls -1 '%s' 2>/dev/null"):format(path))
    if not fh then return nil end
    local files = {}
    for line in fh:lines() do files[#files + 1] = line end
    fh:close()
    return files[i + 1]
  end,
  EnumProjects    = function(_) return nil, '' end,

  -- ExtState in-memory (per-run, bez persistence)
  GetExtState = function(ns, key) return ext[ns .. '\0' .. key] or '' end,
  SetExtState = function(ns, key, val, _) ext[ns .. '\0' .. key] = tostring(val) end,
  DeleteExtState = function(ns, key, _) ext[ns .. '\0' .. key] = nil end,

  -- NS-SFX (2026-06-10): preview.lua rejestruje atexit cleanup przy require
  -- (modes/sfx → gui/sfx_panel → preview). No-op w headless.
  atexit = function(_) end,
}
