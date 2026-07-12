-- modules/colors.lua
-- Paleta statusów (z docs/07-ux-spec.md) + helpery do kolorowania
-- itemów REAPER + ImGui RGBA do GUI badge'ów.

local M = {}

-- Każdy status ma:
--   rgb   — 3-elementowa tabela {r,g,b} (0-255) do reaper.ColorToNative
--   rgba  — 0xRRGGBBAA do ImGui_TextColored / ImGui_PushStyleColor
--   label — krótka nazwa do GUI
M.PALETTE = {
  new         = { rgb = {255, 200, 100}, rgba = 0xFFC864FF, label = 'new'      },
  in_progress = { rgb = { 80, 150, 255}, rgba = 0x5096FFFF, label = 'sending'  },
  converted   = { rgb = {100, 200, 120}, rgba = 0x64C878FF, label = 'done'     },
  error       = { rgb = {220,  90,  90}, rgba = 0xDC5A5AFF, label = 'error'    },
  stale       = { rgb = {234, 179,   8}, rgba = 0xEAB308FF, label = 'stale'    },
  output      = { rgb = {180, 130, 220}, rgba = 0xB482DCFF, label = 'output'   },
  skipped     = { rgb = {140, 140, 140}, rgba = 0x8C8C8CFF, label = 'skipped'  },
}

local function native_for(status)
  local p = M.PALETTE[status]
  if not p then return 0 end
  return reaper.ColorToNative(p.rgb[1], p.rgb[2], p.rgb[3]) | 0x1000000
end

-- Apply native color to item I_CUSTOMCOLOR. Returns true if changed.
function M.apply_to_item(item, status)
  local target = native_for(status)
  local current = math.floor(reaper.GetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR'))
  if current == target then return false end
  reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', target)
  return true
end

function M.clear_item(item)
  local current = math.floor(reaper.GetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR'))
  if current == 0 then return false end
  reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', 0)
  return true
end

----------------------------------------------------------------------------
-- Track color palette (Phase 11.x — track color management)
-- 12 nasyconych dialog-friendly kolorów + neutralna szarość.
-- Każdy element: {r, g, b, label} (0-255).
----------------------------------------------------------------------------
M.TRACK_PRESETS = {
  { 220,  60,  60, 'red'    },
  { 230, 130,  40, 'orange' },
  { 230, 200,  60, 'yellow' },
  { 150, 210,  60, 'lime'   },
  {  60, 180,  90, 'green'  },
  {  50, 180, 180, 'teal'   },
  {  60, 180, 230, 'cyan'   },
  {  70, 130, 230, 'blue'   },
  { 100,  90, 220, 'indigo' },
  { 160,  90, 220, 'violet' },
  { 220,  90, 200, 'magenta'},
  { 230, 110, 160, 'pink'   },
}

----------------------------------------------------------------------------
-- Conversions: native (REAPER I_CUSTOMCOLOR) ↔ RGBA (ImGui 0xRRGGBBAA).
----------------------------------------------------------------------------
function M.rgb_to_native(r, g, b)
  return reaper.ColorToNative(r, g, b) | 0x1000000
end

-- Cross-platform decode native → r, g, b ints (0-255).
-- Windows: COLORREF = 0x00BBGGRR (low byte = R)
-- macOS/Linux: 0x00RRGGBB
function M.native_to_rgb(c)
  if not c or c == 0 then return nil end
  c = c & 0xFFFFFF  -- strip 0x1000000 flag
  if reaper.GetOS():find('Win') then
    return c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF
  end
  return (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF
end

function M.native_to_rgba(c)
  local r, g, b = M.native_to_rgb(c)
  if not r then return nil end
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

function M.rgba_to_rgb(rgba)
  return (rgba >> 24) & 0xFF, (rgba >> 16) & 0xFF, (rgba >> 8) & 0xFF
end

-- Pulsing brightness modulation. Phase 5 użyje dla in_progress.
-- t = reaper.time_precise(); base_rgba = 0xRRGGBBAA.
function M.pulse(t, base_rgba)
  local b = 0.7 + 0.3 * math.sin(t * 3)
  local r  = (base_rgba >> 24) & 0xFF
  local g  = (base_rgba >> 16) & 0xFF
  local bl = (base_rgba >> 8)  & 0xFF
  return (math.floor(r * b) << 24)
       | (math.floor(g * b) << 16)
       | (math.floor(bl * b) << 8)
       | 0xFF
end

return M
