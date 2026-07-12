#!/bin/sh
# scripts/build_reapack_index.sh — generuje ReaPack index.xml dla Reasonate.
#
# Pakiet typu "script" z ~150 plikami (moduły + workery + fonty) — źródła
# emitowane z listy trackowanych plików scaffold/ (git ls-files), URL-e =
# raw.githubusercontent PUBLICZNEGO repo pod podanym refem (tagiem).
#
# Semantyka index.xml (zweryfikowana 2026-07-12, wiki reapack):
#   <source file="X">URL</source> — file = ścieżka DOCELOWA względem
#   kategorii; instalacja: Scripts/<index name>/<category>/<file>.
#   main="main" rejestruje plik w Action List (sekcja Main).
#
# Użycie:
#   sh scripts/build_reapack_index.sh <owner/repo> <ref> <version> [out.xml]
#   np. sh scripts/build_reapack_index.sh b4s1c/reasonate v1.0.0 1.0.0
#
# Flow publikacji: push publicznego repo + tag → wygeneruj index.xml z tym
# tagiem → commit index.xml do ROOTA publicznego repo → import URL dla
# userów = https://raw.githubusercontent.com/<owner/repo>/main/index.xml
#
# Wykluczenia z pakietu: reacast.lua (legacy shim pre-rename — świeże
# instalacje ReaPack go nie potrzebują).

set -e

SLUG="$1"; REF="$2"; VERSION="$3"; OUT="${4:-/tmp/reasonate-index.xml}"
if [ -z "$SLUG" ] || [ -z "$REF" ] || [ -z "$VERSION" ]; then
  echo "usage: $0 <owner/repo> <ref> <version> [out.xml]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RAW="https://raw.githubusercontent.com/$SLUG/$REF"
STAMP=$(git log -1 --format=%cI 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

{
  printf '<?xml version="1.0" encoding="utf-8"?>\n'
  printf '<index version="1" name="Reasonate">\n'
  printf '  <category name="AI voice tools">\n'
  printf '    <reapack name="reasonate.lua" type="script" desc="Reasonate - AI voice tools (TTS, voice replacement, dubbing, repair, SFX and music)">\n'
  printf '      <metadata>\n'
  printf '        <description><![CDATA[\n'
  printf 'AI audio production toolkit for REAPER built on the ElevenLabs API:\n'
  printf 'text to speech (single voice and multi-speaker dialogue), voice\n'
  printf 'replacement on recorded takes, dubbing into other languages, word-level\n'
  printf 'repair of recordings, and sound effects / music generation - all\n'
  printf 'non-destructive, all inside REAPER.\n'
  printf '\n'
  printf 'Requires ReaImGui 0.10+ (via ReaPack), the SWS extension (in-app\n'
  printf 'previews) and your own ElevenLabs API key. Optional: an LLM API key\n'
  printf 'for dubbing translation and scene analysis. By falami.studio (b4s1c), MIT.\n'
  printf ']]></description>\n'
  printf '        <link rel="website">https://falami.studio</link>\n'
  printf '        <link rel="donation">https://ko-fi.com/quickmd</link>\n'
  printf '      </metadata>\n'
  printf '      <version name="%s" author="falami.studio (b4s1c)" time="%s">\n' "$VERSION" "$STAMP"
  printf '        <changelog><![CDATA[Initial public release: five modes (TTS, Voice Replacement, Dubbing, Repair, SFX and Music), cast registry, deterministic cache, Windows/macOS/Linux workers.]]></changelog>\n'

  git ls-files scaffold | grep -v '^scaffold/reacast\.lua$' | LC_ALL=C sort | while IFS= read -r f; do
    rel="${f#scaffold/}"
    case "$rel" in
      reasonate.lua|_phase0_check.lua) mainattr=' main="main"' ;;
      *) mainattr='' ;;
    esac
    printf '        <source%s file="%s">%s/%s</source>\n' "$mainattr" "$rel" "$RAW" "$f"
  done

  printf '      </version>\n'
  printf '    </reapack>\n'
  printf '  </category>\n'
  printf '</index>\n'
} > "$OUT"

N=$(grep -c '<source' "$OUT")
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$OUT"
  echo "OK: $OUT ($N sources, xmllint valid)"
else
  echo "OK: $OUT ($N sources; xmllint not found - skipped validation)"
fi
