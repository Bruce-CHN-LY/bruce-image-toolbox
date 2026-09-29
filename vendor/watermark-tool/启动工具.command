!/usr/bin/env bash
# start tool
cd "$(dirname "$0")"
if [ ! -f "vendor/watermarks-remover/service/scripts/clean_file.py" ]; then
  echo "first run, setup..."
  bash setup.sh
fi
echo "start: http://127.0.0.1:8766"
python3 server.py --open-browser
