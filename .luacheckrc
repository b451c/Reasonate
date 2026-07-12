-- .luacheckrc — konfiguracja luacheck dla Reasonate (audit fix M0-2).
--
-- Filozofia: bramka łapie REALNE błędy (undefined globals — klasyczny
-- footgun Lua, który spowodował m.in. bug "render_header callbacks=nil"),
-- nie styl. Unused/redefined/line-length wyłączone — codebase ma własne
-- konwencje (np. `_ = fn` dla intencjonalnie dead code).

std = 'lua54'

-- REAPER injectuje globalne API
read_globals = { 'reaper' }

-- Tylko błędy + undefined globals; bez warningów stylistycznych
unused = false          -- 211/212/213: unused var/arg/loop var
redefined = false       -- 4xx: shadowing (świadomie używane w renderach)
unused_args = false
max_line_length = false
ignore = {
  '542',  -- empty if branch (używane jako udokumentowane no-op gates)
}

exclude_files = {
  '.checkpoints/**',
}
