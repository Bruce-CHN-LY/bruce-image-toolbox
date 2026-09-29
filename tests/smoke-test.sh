#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_path="$project_dir/Bruce 图片工具箱.app"
resources="$app_path/Contents/Resources"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/bruce-image-toolbox-smoke.XXXXXX")"

cleanup() {
    /bin/rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

"$resources/EmbeddedApps/ImageBatchRenamer.app/Contents/MacOS/ImageBatchRenamer" --self-test

/opt/homebrew/bin/magick -size 64x64 xc:white "$work_dir/sample.png"
"$resources/EmbeddedApps/CopyrightMetadata.app/Contents/MacOS/Image Copyright Metadata" \
    --write-metadata \
    "$work_dir/sample.png" \
    "$work_dir/sample-with-copyright.png"
[[ -f "$work_dir/sample-with-copyright.png" ]]

WP_PNG_NO_PAUSE=1 WP_PNG_NO_DIALOG=1 \
    "$resources/Scripts/WordPressImageCompressor.command" "$work_dir/sample.png"
[[ -f "$work_dir/compressed/sample.png" ]]

print "FUNCTIONAL_SMOKE_TEST_OK"
