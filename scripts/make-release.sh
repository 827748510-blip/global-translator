#!/bin/bash
# Builds a distributable zip from the packaged .app.
# Prerequisite: run scripts/package-app.sh first (produces .build/desktop).
# This script only writes into ./dist and never touches installed copies.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

app="$project_dir/.build/desktop/Global Translator.app"
dist="$project_dir/dist"

if [[ ! -d "$app" ]]; then
    echo "错误：未找到 \"$app\"，请先运行 scripts/package-app.sh" >&2
    exit 1
fi
if [[ ! -f "$project_dir/LICENSE" ]]; then
    echo "错误：缺少 LICENSE，发行包必须带许可证" >&2
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
archs=$(lipo -archs "$app/Contents/MacOS/global-translator" 2>/dev/null | tr -d ' ')
[[ -n "$archs" ]] || archs="unknown"

# A broken seal must never reach a release artifact.
codesign --verify --strict "$app"
# Read the full output first: piping into an early-exiting awk sends SIGPIPE to
# codesign, which `set -o pipefail` would surface as exit 141.
codesign_output=$(codesign -dv --verbose=4 "$app" 2>&1 || true)
authority=$(printf '%s\n' "$codesign_output" | awk -F= '/^Authority=/{value=$2} END{print value}')
[[ -n "$authority" ]] || { echo "错误：产物没有签名身份" >&2; exit 1; }

release_name="Global-Translator-${version}-${archs}"
stage="$dist/stage/$release_name"
zip_name="${release_name}.zip"

rm -rf "$dist/stage"
mkdir -p "$stage"
ditto "$app" "$stage/Global Translator.app"
cp "$project_dir/LICENSE" "$stage/LICENSE"
cp "$project_dir/README.md" "$stage/README.md"

cat > "$stage/安装说明.txt" <<'GUIDE'
安装
1. 把「Global Translator.app」拖入「应用程序」文件夹。
2. 首次打开请右键点击 App → 打开（本版本未经 Apple 公证，直接双击可能被
   Gatekeeper 拦截）。
3. 系统设置 → 隐私与安全性：为「全局翻译」开启辅助功能与屏幕录制权限。
4. 打开后在菜单栏或「全局翻译」菜单里进入设置，选择翻译后端：
   - 本地模型：需要本机运行 Ollama（默认 http://127.0.0.1:11434/v1）。
   - DeepSeek 云端：需要在设置里填入 API Key，密钥只保存在系统钥匙串。

卸载
停止应用后，把 App 拖到废纸篓；配置文件位于
~/Library/Application Support/GlobalTranslator，日志位于
~/Library/Logs/GlobalTranslator。

许可证
MIT，见随包 LICENSE。
GUIDE

mkdir -p "$dist"
rm -f "$dist/$zip_name" "$dist/$zip_name.sha256"
ditto -c -k --sequesterRsrc --keepParent "$stage" "$dist/$zip_name"

# Checksums are generated from inside dist so the file holds bare names.
( cd "$dist" && shasum -a 256 "$zip_name" > "$zip_name.sha256" )

size=$(du -h "$dist/$zip_name" | cut -f1)
echo "发行包：$dist/$zip_name"
echo "版本：$version (build $build)  架构：$archs  大小：$size"
echo "签名：$authority"
echo "SHA256：$(cut -d' ' -f1 "$dist/$zip_name.sha256")"
