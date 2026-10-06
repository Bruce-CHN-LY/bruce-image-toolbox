#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_path="$project_dir/Bruce 图片工具箱.app"

[[ -d "$app_path" ]]
/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
/bin/bash -n "$app_path/Contents/Resources/WatermarkTool/启动工具.command"
/bin/bash -n "$app_path/Contents/Resources/WatermarkTool/setup.sh"
"$app_path/Contents/MacOS/BruceImageToolbox" --self-check

print "BUNDLE_VERIFICATION_OK"
