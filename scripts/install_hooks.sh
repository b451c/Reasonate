#!/bin/sh
# scripts/install_hooks.sh — instaluje git pre-commit hook wywołujący
# scripts/check.sh. Hooki nie są wersjonowane przez git, stąd installer.
# Uruchom raz po sklonowaniu repo: sh scripts/install_hooks.sh

set -u
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_DIR/.git/hooks/pre-commit"

cat > "$HOOK" <<'EOF'
#!/bin/sh
# pre-commit — Reasonate quality gate (zainstalowane przez scripts/install_hooks.sh)
exec sh "$(git rev-parse --show-toplevel)/scripts/check.sh"
EOF

chmod +x "$HOOK"
echo "Installed: $HOOK"
