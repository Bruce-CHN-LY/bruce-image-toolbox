#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
app_name="Bruce 图片工具箱.app"
app_path="$script_dir/$app_name"
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"

# 只清理本项目固定的生成目录，不触碰任何外部工具或用户文件。
if [[ -d "$app_path" ]]; then
    /bin/rm -rf "$app_path"
fi

/bin/mkdir -p \
    "$macos_path" \
    "$resources_path/EmbeddedApps" \
    "$resources_path/Scripts"

/usr/bin/swiftc \
    -parse-as-library \
    -O \
    -framework AppKit \
    "$script_dir/BruceImageToolbox.swift" \
    -o "$macos_path/BruceImageToolbox"

/bin/cp "$script_dir/Info.plist" "$contents_path/Info.plist"

build_component() {
    local source_file="$1"
    local plist_file="$2"
    local output_app="$3"
    local executable_name="$4"
    local parse_mode="$5"
    local output_path="$resources_path/EmbeddedApps/$output_app"
    local output_macos="$output_path/Contents/MacOS"
    local swift_args=(
        -O
        -framework AppKit
        -framework ImageIO
        -framework UniformTypeIdentifiers
    )

    if [[ "$parse_mode" == "library" ]]; then
        swift_args=(-parse-as-library $swift_args)
    fi

    /bin/mkdir -p "$output_macos"
    /usr/bin/swiftc $swift_args "$source_file" -o "$output_macos/$executable_name"
    /bin/cp "$plist_file" "$output_path/Contents/Info.plist"
}

build_component \
    "$script_dir/components/image-batch-renamer/ImageBatchRenamer.swift" \
    "$script_dir/components/image-batch-renamer/Info.plist" \
    "ImageBatchRenamer.app" \
    "ImageBatchRenamer" \
    "library"

build_component \
    "$script_dir/components/heic-batch-converter/HEICBatchConverter.swift" \
    "$script_dir/components/heic-batch-converter/Info.plist" \
    "HEICBatchConverter.app" \
    "HEIC Batch Converter" \
    "top-level"

build_component \
    "$script_dir/components/copyright-metadata/ImageCopyrightMetadata.swift" \
    "$script_dir/components/copyright-metadata/Info.plist" \
    "CopyrightMetadata.app" \
    "Image Copyright Metadata" \
    "top-level"

/bin/cp \
    "$script_dir/vendor/scripts/WordPressImageCompressor.command" \
    "$resources_path/Scripts/WordPressImageCompressor.command"
/bin/chmod +x "$resources_path/Scripts/WordPressImageCompressor.command"

/usr/bin/ditto \
    "$script_dir/vendor/watermark-tool" \
    "$resources_path/WatermarkTool"

# 先验证并签名嵌套应用，再签名外层工具箱。
for nested_app in "$resources_path/EmbeddedApps"/*.app; do
    /usr/bin/codesign --force --deep --sign - "$nested_app"
    /usr/bin/codesign --verify --deep --strict "$nested_app"
done

/usr/bin/codesign --force --deep --sign - "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"

print "Built: $app_path"
