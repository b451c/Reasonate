# ReaImGui v0.9 → v0.10 — API Deltas

Krótka ściąga z breakingów. Pełne info: https://github.com/cfillion/reaimgui/releases/tag/v0.10

## Fonts (najgorszy breaking)

```diff
- local font = reaper.ImGui_CreateFont('sans-serif', 16)
- reaper.ImGui_Attach(ctx, font)
- reaper.ImGui_PushFont(ctx, font)
+ local font = reaper.ImGui_CreateFont('sans-serif')
+ reaper.ImGui_Attach(ctx, font)
+ reaper.ImGui_PushFont(ctx, font, 16)
```

Z pliku:
```diff
- local font = reaper.ImGui_CreateFont('/path/to/font.ttf', 14)
+ local font = reaper.ImGui_CreateFontFromFile('/path/to/font.ttf')
+ -- size podajesz w PushFont
```

## Renames (find-and-replace safe)

| v0.9 i wcześniejsze | v0.10+ |
|--|--|
| `ImGui_ChildFlags_Border` | `ImGui_ChildFlags_Borders` |
| `ImGui_Col_NavHighlight` | `ImGui_Col_NavCursor` |
| `ImGui_SelectableFlags_DontClosePopups` | `ImGui_SelectableFlags_NoAutoClosePopups` |
| `ImGui_TreeNodeFlags_SpanTextWidth` | `ImGui_TreeNodeFlags_SpanLabelWidth` |
| `ImGui_Col_TabActive` (już zmienione w v0.9.2) | `ImGui_Col_TabSelected` |
| `ImGui_Col_TabUnfocused` | `ImGui_Col_TabDimmed` |
| `ImGui_Col_TabUnfocusedActive` | `ImGui_Col_TabDimmedSelected` |
| `ImGui_DragDropFlags_SourceAutoExpirePayload` | `ImGui_DragDropFlags_PayloadAutoExpire` |

## Removed — substytuty

| Usunięte | Czego użyć zamiast |
|--|--|
| `ImGui_GetContentRegionMax()` | `ImGui_GetContentRegionAvail()` |
| `ImGui_GetWindowContentRegionMin()` | brak — przelicz z `GetCursorPos`/`GetWindowPos` |
| `ImGui_GetWindowContentRegionMax()` | jw. lub `GetContentRegionAvail` |
| `Image(ctx, tex, w, h, u0, v0, u1, v1, tint, border)` | parametry `tint` i `border` zniknęły. Użyj `ImageWithBg` jeśli potrzebujesz tint/border |
| `ImGui_ColorEditFlags_AlphaPreview` | `ImGui_ColorEditFlags_AlphaOpaque` lub `_AlphaNoBg` |
| `ImGui_PushButtonRepeat` / `PopButtonRepeat` | `PushItemFlag(ctx, ImGui_ItemFlags_ButtonRepeat(), true)` |
| `ImGui_PushTabStop` / `PopTabStop` | `PushItemFlag(ctx, ImGui_ItemFlags_NoTabStop(), true/false)` |
| `ImGui_ConfigFlags_NavEnableSetMousePos` | `SetConfigVar(ctx, ImGui_ConfigVar_NavMoveSetMousePos(), 1)` |
| `ImGui_ConfigFlags_NavNoCaptureKeyboard` | `SetConfigVar(ctx, ImGui_ConfigVar_NavCaptureKeyboard(), 0)` |

## Subtelne zmiany zachowania

- **Default vertical frame padding**: 3 → 2. Layout się może rozjechać o 2px.
- **Keyboard navigation**: domyślnie WŁĄCZONA. Tab między widgetami działa bez konfiguracji.
- **System sans-serif jako default font** zamiast Proggy Clean. Lepszy UTF-8.
- **Saved state okien jest zresetowany** po update do v0.10 — pierwszy launch po update'ie da świeży layout.

## Nowe rzeczy które warto wykorzystać

| Nowe | Co daje |
|--|--|
| `ImGui_TextLink` / `ImGui_TextLinkOpenURL` | klikalne linki w tekście |
| `ImGui_Col_TextLink` | styling dla linków |
| `ImGui_TreeNodeFlags_DrawLines*` | linie w drzewie (ładniej wygląda) |
| `ImGui_SelectableFlags_Highlight` | force highlight bez hover |
| `ImGui_SliderFlags_ClampOnInput` | clamp od razu w input boxie |
| `ImGui_SliderFlags_NoSpeedTweaks` | wyłączenie shift/alt accel |
| `ImGui_PushStyleVarX` / `PushStyleVarY` | jednowymiarowy push (tylko X albo Y) |
| `ImGui_StyleVar_TabBarOverlineSize` | linia nad tab barem |
| `ImGui_IsMouseReleasedWithDelay` | release po hold-time (drag-tolerant clicks) |
| `ImGui_MouseCursor_Progress` / `_Wait` | kursory "busy" |
| `ImGui_DebugLog` | debug log window |

## Sprawdzenie wersji w runtime

```lua
local function require_reaimgui(min_major, min_minor)
  if not reaper.ImGui_GetVersion then
    reaper.MB('ReaImGui not installed.\nGet it via ReaPack: ReaTeam Extensions repo.', 'Error', 0)
    return false
  end
  -- Sprawdź funkcję wprowadzoną w v0.10:
  if not reaper.ImGui_CreateFontFromFile then
    reaper.MB('ReaImGui v0.10+ required.\nUpdate via ReaPack.', 'Error', 0)
    return false
  end
  return true
end
```

---

## 2026-05-09 — Lua API confirmations + new gaps (NS-1 + async STT session)

### Verified working in Lua (despite mcp `available_in` not listing 'lua')

mcp `reaper-dev` `get_function_info` field `available_in` is NIEKOMPLETNE
dla niektórych functions. Below verified live in REAPER 7.71 / ReaImGui
0.10.0.5 / Lua:

- `ImGui_Begin(ctx, name, p_open?, flags?)` — main window + sub-windows ✓
  (already used pre-2026-05-09)
- `ImGui_GetWindowPos(ctx)` → x, y (2 returns) ✓ (used live in `reasonate.lua`
  frame() for batch_dialog centering capture)
- `ImGui_GetWindowSize(ctx)` → w, h (2 returns) ✓ (same use case)
- `ImGui_GetMainViewport(ctx)` → viewport handle ✓ (briefly tested; not used
  in final batch_dialog — switched do `GetWindowPos` z main scope)
- `ImGui_TableSetBgColor(ctx, target, color, column?)` ✓ (used w batch_dialog
  + tracks_table dla row-wide tint)
- `ImGui_TableBgTarget_RowBg0()` constant ✓
- `ImGui_SelectableFlags_AllowOverlap()` constant ✓
- `ImGui_SelectableFlags_SpanAllColumns()` constant ✓
- `ImGui_GetFrameHeightWithSpacing(ctx)` → number ✓ (mcp lists [c, eel2, lua]
  correctly — used dla per-row height calc w batch_dialog scrollable child)
- `ImGui_Indent(ctx, indent_w?)` / `ImGui_Unindent(ctx, indent_w?)` ✓ (per
  mcp `available_in: [c, eel2, lua]`; used w transcript_editor voice settings
  collapsible)

### NIE w Lua (confirmed via mcp + live test fail)

- `ImGui_CollapsingHeader(ctx, label, p_visible?, flags?)` — `available_in:
  [c, eel2]` only. Lua workaround: manual button toggle z bool state +
  `if expanded then render_content end`. Used w `transcript_editor.lua`
  voice settings section (NS-4): button label `[+]` / `[-]` ASCII indicators.
- `ImGui_InputTextWithHint` — already documented in KNOWN-ISSUES; same pattern.
- `ImGui_CalcTextSize` — already documented; estimate `#text * 6` (caption)
  / `#text * 7` (body) px.

### Pattern: ImGui_Begin z `p_open=nil` dla "no X button"

Standard Dear ImGui semantics: pass `nil` (or omit) `p_open` argument →
window has no close X button. ReaImGui Lua honors this:

```lua
local p_open = (s.state == 'progress') and nil or true
local visible, open = reaper.ImGui_Begin(ctx, NAME, p_open, flags)
if visible then
  -- render
  reaper.ImGui_End(ctx)
end
if p_open ~= nil and open == false then
  -- user clicked X (only when X was shown)
  s.state = 'closed'
end
```

Used w `batch_dialog.lua` dla per-state X policy (confirm/summary = X visible,
progress = no X to force user przez explicit Cancel batch button). Verified
live 2026-05-09.

### Pattern: SetNextWindowPos z pivot dla center-on-target

Aby pojawić window na środku jakiegoś target obszaru (np. main Reasonate
window):

```lua
-- 1. W obrębie main Begin scope, capture geom
local mw_x, mw_y = reaper.ImGui_GetWindowPos(ctx)
local mw_w, mw_h = reaper.ImGui_GetWindowSize(ctx)
local cx, cy = mw_x + mw_w/2, mw_y + mw_h/2
-- (store cx/cy for later modal)

-- 2. Przed Begin floating window:
reaper.ImGui_SetNextWindowPos(ctx, cx, cy, reaper.ImGui_Cond_Always(), 0.5, 0.5)
-- pivot=(0.5, 0.5) means cx/cy is the WINDOW CENTER (not top-left)
```

Re-trigger na state change via `pending_pos` flag (set true gdy state
mutates, consumed in render). Used w `batch_dialog.lua` dla auto-centering
on confirm/progress/summary transitions.

### Pattern: TableSetBgColor row tint zamiast Selectable+SpanAllColumns

Anti-pattern: row-spanning Selectable z `SpanAllColumns | AllowOverlap`
flags + InputText/buttons w cells = z-order conflict, ugly hover/selected
visual.

Better pattern: split visual signal:
- Row tint via `TableSetBgColor(target=RowBg0, color=alpha-blended, col=-1)`
  (drawn at table level, no z-order conflict z cell content)
- Click target = small contained Selectable (np. na cell index "1", 24px
  width)

Used w `tracks_table.lua` dla audition row select. Pattern: `0xF59E0B22`
amber primary @ ~13% alpha over alt-row stripe.

## CalcTextSize JEST w Lua (errata 2026-06-11)

`local w, h = reaper.ImGui_CalcTextSize(ctx, text)` — multi-return, działa
(ReaImGui_Demo.lua:4788). Wcześniejsze "brak w Lua" pochodziło z MCP index
(błędny `available_in` dla funkcji z output-paramami — ten sam bug co
Viewport_Get*). Konsument: theme.segmented (pomiar etykiet segmentów).
InputTextWithHint — nadal naprawdę brak w Lua.
