#!/usr/bin/env bash
set -euo pipefail

# Start the local tool with Python 3.10+. macOS may provide Python 3.9 at
# /usr/bin/python3, which cannot run the bundled type annotations.
cd "$(dirname "$0")"
if [ ! -f "vendor/watermarks-remover/service/scripts/clean_file.py" ]; then
  echo "first run, setup..."
  bash setup.sh
fi

python_is_supported() {
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
    >/dev/null 2>&1
}

PYTHON_BIN=""
PYTHON_CANDIDATES=(
  "/opt/homebrew/bin/python3"
  "/usr/local/bin/python3"
  "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"
  "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3"
  "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3"
  "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"
  "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3"
  "/Library/Frameworks/Python.framework/Versions/3.10/bin/python3"
  "/usr/bin/python3"
)

for candidate in "${PYTHON_CANDIDATES[@]}"; do
  if [ -x "$candidate" ] && python_is_supported "$candidate"; then
    PYTHON_BIN="$candidate"
    break
  fi
done

if [ -z "$PYTHON_BIN" ]; then
  echo "Error: Python 3.10 or newer is required."
  echo "Please install it with Homebrew, then reopen this tool:"
  echo "  brew install python"
  printf '\nPress Return to close...'
  read -r _unused
  exit 1
fi

echo "start: http://127.0.0.1:8766"
echo "python: $($PYTHON_BIN --version 2>&1) ($PYTHON_BIN)"
exec "$PYTHON_BIN" server.py --open-browser
