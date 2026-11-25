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
allow_adhoc="${ALLOW_ADHOC:-0}"
if ! printf '%s\n' "$codesign_output" | grep -q 'flags=.*runtime'; then
    if [[ "$allow_adhoc" != "1" ]]; then
        echo "错误：应用未启用硬化运行时 (--options runtime)，拒绝打包对外发行。请重新运行 scripts/package-app.sh。" >&2
        exit 1
    fi
fi
if [[ -z "$authority" ]] && printf '%s\n' "$codesign_output" | grep -q '^Signature=adhoc$'; then
    if [[ "$allow_adhoc" != "1" ]]; then
        echo "错误：检测到无身份的 ad-hoc (-) 签名。正式发行请传入有效签名证书（例如 CODESIGN_IDENTITY=\"Developer ID Application: ...\"），仅限本地测试可显式设置 ALLOW_ADHOC=1。" >&2
        exit 1
    fi
    authority="adhoc (-) [仅限本地测试]"
fi
[[ -n "$authority" ]] || { echo "错误：产物没有签名身份" >&2; exit 1; }

release_name="Global-Translator-${version}-${archs}"
stage="$dist/stage/$release_name"
zip_name="${release_name}.zip"

rm -rf "$dist/stage"
mkdir -p "$stage"
ditto "$app" "$stage/Global Translator.app"
cp "$project_dir/LICENSE" "$stage/LICENSE"
cp "$project_dir/README.md" "$stage/README.md"
[[ -f "$project_dir/README_EN.md" ]] && cp "$project_dir/README_EN.md" "$stage/README_EN.md"

cat > "$stage/安装说明.txt" <<'GUIDE'
安装
1. 把「Global Translator.app」拖入「应用程序」（或 ~/Applications）文件夹。
2. 首次打开建议通过正式 Developer ID 签名与 Apple 公证校验后再运行；若为本地自签名开发测试包，请按住 Control 右键点击 App → 打开并在系统安全提示中确认，切勿随意对来历不明的应用清除系统隔离属性。
3. 系统设置 → 隐私与安全性：为「全局翻译」开启辅助功能与屏幕录制权限。
4. 打开后在菜单栏或「全局翻译」菜单里进入设置，选择翻译后端：
   - 本地模型：需要本机运行 Ollama（默认 http://127.0.0.1:11434/v1）。
   - DeepSeek 云端：需要在设置里填入 API Key，密钥只保存在系统钥匙串。

Chrome 浏览器扩展（可选）
解压同版本 Global-Translator-Bridge-<版本>.zip（或使用仓库内的 extension/ 目录），在 Chrome 打开 chrome://extensions/ 开启「开发者模式」，点击「加载已解压的扩展程序」选择解压后的目录。

卸载
停止应用后，把 App 拖到废纸篓；配置文件位于
~/Library/Application Support/GlobalTranslator，日志位于
~/Library/Logs/GlobalTranslator。

许可证
MIT，见随包 LICENSE。

作者与项目主页
作者：maodashu
如果觉得好用，欢迎在 GitHub 点个 Star 支持：
https://github.com/827748510-blip/global-translator
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

if [[ -f "$project_dir/extension/manifest.json" ]]; then
    ext_version=$(python3 -c 'import json; print(json.load(open("extension/manifest.json"))["version"])')
    ext_name="Global-Translator-Bridge-${ext_version}"
    ext_stage="$dist/stage/$ext_name"
    ext_zip="${ext_name}.zip"
    mkdir -p "$ext_stage"
    for f in "$project_dir"/extension/*; do
        base=$(basename "$f")
        case "$base" in
            *.test.js|fixtures|.DS_Store) continue ;;
        esac
        cp -R "$f" "$ext_stage/$base"
    done
    cp "$project_dir/LICENSE" "$ext_stage/LICENSE"
    rm -f "$dist/$ext_zip" "$dist/$ext_zip.sha256"
    ditto -c -k --sequesterRsrc --keepParent "$ext_stage" "$dist/$ext_zip"
    ( cd "$dist" && shasum -a 256 "$ext_zip" > "$ext_zip.sha256" )
    ext_size=$(du -h "$dist/$ext_zip" | cut -f1)
    echo "浏览器扩展包：$dist/$ext_zip  大小：$ext_size"
    echo "扩展 SHA256：$(cut -d' ' -f1 "$dist/$ext_zip.sha256")"
fi
