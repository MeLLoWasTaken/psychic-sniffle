#!/usr/bin/env bash
# Install the Git pre-commit hook that runs tools/check_all --quick before every commit.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cat > "$REPO/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
cd "$(git rev-parse --show-toplevel)"
tools/check_all --quick || { echo "pre-commit: checks failed; commit aborted"; exit 1; }
HOOK
chmod +x "$REPO/.git/hooks/pre-commit"
echo "pre-commit hook installed"
