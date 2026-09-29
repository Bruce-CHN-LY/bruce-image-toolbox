#!/bin/bash

# WordPress PNG/HEIC batch compressor for macOS.
# Originals are never modified. Results are written to <source>/compressed.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

TOOL_NAME="WordPress 图片批量压缩工具"
QUALITY_RANGE="80-95"
MAX_EDGE=1600
PNGQUANT_SPEED=1

print_rule() {
  printf '%s\n' '------------------------------------------------------------'
}

wait_before_exit() {
  local exit_code="${1:-0}"
  if [[ "${WP_PNG_NO_PAUSE:-0}" != "1" && -t 0 ]]; then
    printf '\n按回车键关闭此窗口...'
    IFS= read -r _unused
  fi
  exit "$exit_code"
}

show_error_dialog() {
  local message="$1"
  [[ "${WP_PNG_NO_DIALOG:-0}" == "1" ]] && return 0
  /usr/bin/osascript -e 'on run argv' \
    -e 'display alert "WordPress PNG 批量压缩工具" message (item 1 of argv) as critical' \
    -e 'end run' -- "$message" >/dev/null 2>&1 || true
}

print_dependency_help() {
  local missing_imagemagick="$1"
  local missing_pngquant="$2"

  printf '\n缺少运行所需的软件，工具尚未处理任何图片。\n\n'

  if ! command -v brew >/dev/null 2>&1; then
    printf '%s\n' '1. 未检测到 Homebrew。请在“终端”中运行：'
    printf '%s\n\n' '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    printf '%s\n' '2. Homebrew 安装完成后，再运行：'
    printf '%s\n' 'brew install imagemagick pngquant'
  else
    printf '%s\n' '请在“终端”中运行：'
    if [[ "$missing_imagemagick" == "1" && "$missing_pngquant" == "1" ]]; then
      printf '%s\n' 'brew install imagemagick pngquant'
    elif [[ "$missing_imagemagick" == "1" ]]; then
      printf '%s\n' 'brew install imagemagick'
    else
      printf '%s\n' 'brew install pngquant'
    fi
  fi

  printf '\n安装完成后，重新双击本工具即可。\n'
}

printf '\033]0;%s\007' "$TOOL_NAME"
printf '\n%s\n' "$TOOL_NAME"
print_rule

MISSING_IMAGEMAGICK=0
MISSING_PNGQUANT=0
IMAGEMAGICK_MODE=""

if command -v magick >/dev/null 2>&1; then
  IMAGEMAGICK_MODE="magick"
elif command -v identify >/dev/null 2>&1 && command -v convert >/dev/null 2>&1; then
  IMAGEMAGICK_MODE="legacy"
else
  MISSING_IMAGEMAGICK=1
fi

if ! command -v pngquant >/dev/null 2>&1; then
  MISSING_PNGQUANT=1
fi

if [[ "$MISSING_IMAGEMAGICK" == "1" || "$MISSING_PNGQUANT" == "1" ]]; then
  print_dependency_help "$MISSING_IMAGEMAGICK" "$MISSING_PNGQUANT"
  show_error_dialog "缺少 ImageMagick 或 pngquant。安装命令已经显示在终端窗口中。"
  wait_before_exit 1
fi

if (( $# > 0 )); then
  INPUT_PATHS=("$@")
else
  printf '请选择 PNG、HEIC 或 HEIF 图片（可多选）...\n'
  SELECTED_PATHS="$(/usr/bin/osascript \
    -e 'set selectedFiles to choose file with prompt "请选择 PNG、HEIC 或 HEIF 图片（可多选）" with multiple selections allowed' \
    -e 'set outputPaths to {}' \
    -e 'repeat with selectedFile in selectedFiles' \
    -e 'set end of outputPaths to POSIX path of selectedFile' \
    -e 'end repeat' \
    -e "set AppleScript's text item delimiters to linefeed" \
    -e 'return outputPaths as text' 2>/dev/null)"
  if [[ $? -ne 0 || -z "$SELECTED_PATHS" ]]; then
    printf '\n已取消，没有处理任何图片。\n'
    wait_before_exit 0
  fi
  INPUT_PATHS=()
  while IFS= read -r SELECTED_PATH; do
    [[ -n "$SELECTED_PATH" ]] && INPUT_PATHS+=("$SELECTED_PATH")
  done <<< "$SELECTED_PATHS"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wp-png-compressor.XXXXXX")"
if [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]]; then
  printf '\n无法建立临时工作目录。\n'
  wait_before_exit 1
fi

cleanup_work_dir() {
  rm -f "$WORK_DIR/converted.png" "$WORK_DIR/resized.png" "$WORK_DIR/quantized.png" 2>/dev/null || true
  rmdir "$WORK_DIR" 2>/dev/null || true
}
trap cleanup_work_dir EXIT INT TERM

identify_dimensions() {
  local source_file="$1"
  if [[ "$IMAGEMAGICK_MODE" == "magick" ]]; then
    magick identify -format '%w %h' "$source_file"
  else
    identify -format '%w %h' "$source_file"
  fi
}

resize_image() {
  local source_file="$1"
  local destination_file="$2"
  if [[ "$IMAGEMAGICK_MODE" == "magick" ]]; then
    magick "$source_file" -resize "${MAX_EDGE}x${MAX_EDGE}>" "$destination_file"
  else
    convert "$source_file" -resize "${MAX_EDGE}x${MAX_EDGE}>" "$destination_file"
  fi
}

convert_heic_to_png() {
  local source_file="$1"
  local destination_file="$2"
  if [[ "$IMAGEMAGICK_MODE" == "magick" ]]; then
    magick "$source_file" -auto-orient "$destination_file"
  else
    convert "$source_file" -auto-orient "$destination_file"
  fi
}

IMAGE_FILES=()

is_supported_image() {
  local candidate_file="$1"
  local candidate_name="${candidate_file##*/}"
  local candidate_extension="${candidate_name##*.}"
  candidate_extension="$(printf '%s' "$candidate_extension" | tr '[:upper:]' '[:lower:]')"
  [[ "$candidate_extension" == "png" || "$candidate_extension" == "heic" || "$candidate_extension" == "heif" ]]
}

add_image_file() {
  local candidate_file="$1"
  local existing_file

  [[ -f "$candidate_file" ]] || return 0
  if ! is_supported_image "$candidate_file"; then
    printf '跳过不支持的文件：%s\n' "${candidate_file##*/}"
    return 0
  fi

  for existing_file in "${IMAGE_FILES[@]}"; do
    [[ "$existing_file" == "$candidate_file" ]] && return 0
  done
  IMAGE_FILES+=("$candidate_file")
}

add_images_from_folder() {
  local source_folder="$1"
  local candidate_file

  shopt -s nullglob nocaseglob
  for candidate_file in "$source_folder"/*.png "$source_folder"/*.heic "$source_folder"/*.heif; do
    add_image_file "$candidate_file"
  done
  shopt -u nocaseglob
}

for INPUT_PATH in "${INPUT_PATHS[@]}"; do
  if [[ -d "$INPUT_PATH" ]]; then
    add_images_from_folder "${INPUT_PATH%/}"
  elif [[ -f "$INPUT_PATH" ]]; then
    add_image_file "$INPUT_PATH"
  else
    printf '跳过找不到的路径：%s\n' "$INPUT_PATH"
  fi
done

TOTAL=0
SUCCEEDED=0
FAILED=0
RESIZED=0
CONVERTED=0

printf '\n设置：最长边 %d px，质量 %s，速度 %d\n\n' "$MAX_EDGE" "$QUALITY_RANGE" "$PNGQUANT_SPEED"

if (( ${#IMAGE_FILES[@]} == 0 )); then
  printf '没有找到可处理的 PNG、HEIC 或 HEIF 图片。\n'
else
  for SOURCE_FILE in "${IMAGE_FILES[@]}"; do
    [[ -f "$SOURCE_FILE" ]] || continue

    TOTAL=$((TOTAL + 1))
    FILE_NAME="${SOURCE_FILE##*/}"
    FILE_STEM="${FILE_NAME%.*}"
    FILE_EXTENSION="${FILE_NAME##*.}"
    FILE_EXTENSION="$(printf '%s' "$FILE_EXTENSION" | tr '[:upper:]' '[:lower:]')"
    SOURCE_DIR="${SOURCE_FILE%/*}"
    OUTPUT_DIR="$SOURCE_DIR/compressed"
    if ! mkdir -p "$OUTPUT_DIR"; then
      printf '  失败：无法建立输出文件夹：%s\n' "$OUTPUT_DIR"
      FAILED=$((FAILED + 1))
      continue
    fi
    if [[ "$FILE_EXTENSION" == "png" ]]; then
      DESTINATION_FILE="$OUTPUT_DIR/$FILE_NAME"
    elif [[ -f "$SOURCE_DIR/$FILE_STEM.png" || -f "$SOURCE_DIR/$FILE_STEM.PNG" ]]; then
      DESTINATION_FILE="$OUTPUT_DIR/${FILE_STEM}_${FILE_EXTENSION}.png"
    else
      DESTINATION_FILE="$OUTPUT_DIR/${FILE_STEM}.png"
    fi
    CONVERTED_FILE="$WORK_DIR/converted.png"
    RESIZED_FILE="$WORK_DIR/resized.png"
    QUANTIZED_FILE="$WORK_DIR/quantized.png"
    rm -f "$CONVERTED_FILE" "$RESIZED_FILE" "$QUANTIZED_FILE"

    printf '[%d/%d] %s\n' "$TOTAL" "${#IMAGE_FILES[@]}" "$FILE_NAME"

    INPUT_FOR_PROCESSING="$SOURCE_FILE"
    if [[ "$FILE_EXTENSION" == "heic" || "$FILE_EXTENSION" == "heif" ]]; then
      if ! convert_heic_to_png "$SOURCE_FILE" "$CONVERTED_FILE" 2>/dev/null; then
        printf '  失败：无法读取或转换 HEIC/HEIF 图片。请确认 ImageMagick 已启用 HEIC 支持。\n'
        FAILED=$((FAILED + 1))
        continue
      fi
      INPUT_FOR_PROCESSING="$CONVERTED_FILE"
      CONVERTED=$((CONVERTED + 1))
      printf '  已转换：%s → PNG\n' "$FILE_EXTENSION"
    fi

    DIMENSIONS="$(identify_dimensions "$INPUT_FOR_PROCESSING" 2>/dev/null)"
    if [[ ! "$DIMENSIONS" =~ ^[0-9]+[[:space:]][0-9]+$ ]]; then
      printf '  失败：无法读取图片尺寸，文件可能已损坏。\n'
      FAILED=$((FAILED + 1))
      continue
    fi

    WIDTH="${DIMENSIONS%% *}"
    HEIGHT="${DIMENSIONS##* }"
    INPUT_FOR_QUANT="$INPUT_FOR_PROCESSING"

    if (( WIDTH > MAX_EDGE || HEIGHT > MAX_EDGE )); then
      if ! resize_image "$INPUT_FOR_PROCESSING" "$RESIZED_FILE" 2>/dev/null; then
        printf '  失败：缩放图片时出错。\n'
        FAILED=$((FAILED + 1))
        continue
      fi
      INPUT_FOR_QUANT="$RESIZED_FILE"
      RESIZED=$((RESIZED + 1))
      printf '  已等比例缩放：%s → 最长边 %d px\n' "$DIMENSIONS" "$MAX_EDGE"
    else
      printf '  尺寸无需缩放：%s px\n' "$DIMENSIONS"
    fi

    if pngquant --quality="$QUALITY_RANGE" --speed "$PNGQUANT_SPEED" --force \
      --output "$QUANTIZED_FILE" -- "$INPUT_FOR_QUANT" 2>/dev/null; then
      if mv -f "$QUANTIZED_FILE" "$DESTINATION_FILE"; then
        SUCCEEDED=$((SUCCEEDED + 1))
        printf '  完成\n'
      else
        printf '  失败：无法写入输出文件。\n'
        FAILED=$((FAILED + 1))
      fi
    else
      printf '  失败：pngquant 无法在最低质量 %s 下完成压缩。\n' "${QUALITY_RANGE%%-*}"
      FAILED=$((FAILED + 1))
    fi
  done
fi

printf '\n'
print_rule
printf '处理完成\n'
printf '发现图片：%d 张\n' "$TOTAL"
printf '成功处理：%d 张\n' "$SUCCEEDED"
printf '其中 HEIC/HEIF 转换：%d 张\n' "$CONVERTED"
printf '其中缩放：%d 张\n' "$RESIZED"
printf '处理失败：%d 张\n' "$FAILED"
printf '输出位置：每张图片同级的 compressed 文件夹\n'
print_rule

if (( ${#IMAGE_FILES[@]} > 0 )); then
  LAST_SOURCE_DIR="${IMAGE_FILES[${#IMAGE_FILES[@]} - 1]%/*}"
  LAST_OUTPUT_DIR="$LAST_SOURCE_DIR/compressed"
  if ! /usr/bin/open "$LAST_OUTPUT_DIR"; then
    printf '提示：无法自动打开输出文件夹，请按上面的路径手动打开。\n'
  fi
fi

if (( FAILED > 0 )); then
  show_error_dialog "处理结束：成功 $SUCCEEDED 张，失败 $FAILED 张。详情请查看终端窗口。"
fi

wait_before_exit 0
