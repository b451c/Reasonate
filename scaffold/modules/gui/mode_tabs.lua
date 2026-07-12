-- modules/gui/mode_tabs.lua
--
-- NS-A: przełącznik trybów w trakcie sesji (po wybraniu trybu).
-- Renderowany pod header_bar, gdy state.current_mode != nil.
--
-- W3 (2026-06-11): natywny BeginTabBar → theme.segmented (premium rail,
-- akcent koloru per tryb — spójny z kartami startowymi mode_selector).
-- Custom control trzyma stan wyłącznie w state.current_mode, więc cały
-- sync_target / TabItemFlags_SetSelected hack z czasów TabBar (wewnętrzny
-- stan ImGui vs nasz → oscylacje) zniknął razem z TabBarem.
--
-- Returns: switched_mode (string) gdy user kliknął inny tryb, inaczej nil.

local theme = require 'modules.theme'

local M = {}

local TABS = {
  { key = 'tts',               label = 'TTS',               accent = theme.MODE_ACCENTS.tts },
  { key = 'voice_replacement', label = 'Voice Replacement', accent = theme.MODE_ACCENTS.voice_replacement },
  { key = 'dubbing',           label = 'Dubbing',           accent = theme.MODE_ACCENTS.dubbing },
  { key = 'repair',            label = 'Repair',            accent = theme.MODE_ACCENTS.repair },
  { key = 'sfx',               label = 'SFX & Music',       accent = theme.MODE_ACCENTS.sfx },
}

function M.render(ctx, current_mode)
  reaper.ImGui_Spacing(ctx)
  local clicked = theme.segmented(ctx, 'mode_tabs', TABS, current_mode)
  reaper.ImGui_Spacing(ctx)
  return clicked
end

return M
