#!/bin/sh
# scripts/check.sh — mechaniczna bramka jakości Reasonate (audit fix M0-2).
#
# Zastępuje ręczny rytuał "77 .lua syntax pass" + grep UI English-only
# z handover.md Krok 2. Wywoływane:
#   - ręcznie:  sh scripts/check.sh
#   - z .git/hooks/pre-commit (instalacja: sh scripts/install_hooks.sh)
#   - przez /handover (Krok 2)
#
# Bramki (każda porażka -> exit 1):
#   1. luac -p  — syntax wszystkich .lua w scaffold/
#   2. luacheck — statyczna analiza (OPCJONALNE: skip z notą gdy brak narzędzia)
#   3. UI English-only — diakrytyki w literałach stringów gui/ + modes/
#   4. tests/run.lua — testy headless pure-logic
#
# Zależności: luac + lua5.4 (brew install lua), opcjonalnie luacheck (luarocks).

set -u
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR" || exit 1

FAIL=0

echo "== [1/4] Syntax check (luac -p) =="
if find scaffold -name '*.lua' -type f -exec luac -p {} +; then
  echo "   OK: $(find scaffold -name '*.lua' -type f | wc -l | tr -d ' ') files"
else
  echo "   FAIL: syntax errors above"
  FAIL=1
fi

echo "== [2/4] luacheck (static analysis) =="
if command -v luacheck >/dev/null 2>&1; then
  if luacheck scaffold --quiet; then
    echo "   OK"
  else
    echo "   FAIL: luacheck findings above"
    FAIL=1
  fi
else
  echo "   SKIP: luacheck not installed (luarocks install luacheck)"
fi

echo "== [3/4] UI English-only (string literals in gui/ + modes/) =="
LUA_BIN=""
for cand in lua5.4 lua-5.4 lua; do
  if command -v "$cand" >/dev/null 2>&1; then LUA_BIN="$cand"; break; fi
done
if [ -n "$LUA_BIN" ]; then
  # shellcheck disable=SC2046
  if "$LUA_BIN" scripts/check_ui_lang.lua \
      $(find scaffold/modules/gui scaffold/modules/modes -name '*.lua' -type f); then
    echo "   OK"
  else
    echo "   FAIL: Polish text in UI strings above (per feedback_ui_english_only)"
    FAIL=1
  fi
else
  echo "   SKIP: no standalone lua interpreter (brew install lua)"
fi

echo "== [4/4] Headless unit tests (tests/run.lua) =="
if [ -n "$LUA_BIN" ]; then
  if "$LUA_BIN" tests/run.lua; then
    echo "   OK"
  else
    echo "   FAIL: test failures above"
    FAIL=1
  fi
else
  echo "   SKIP: no standalone lua interpreter (brew install lua)"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "== ALL GATES PASSED =="
else
  echo "== GATES FAILED — fix before commit =="
fi
exit "$FAIL"
