!/usr/bin/env bash
# setup.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/vendor/watermarks-remover"
if [ -d "$REPO_DIR/.git" ]; then
  echo "watermarks-remover already exists"
else
  echo "cloning..."
  git clone --depth 1 https://github.com/guillaumemeyer/watermarks-remover.git "$REPO_DIR"
fi
echo done
