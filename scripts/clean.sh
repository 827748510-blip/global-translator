#!/bin/bash
# 安全清理项目内可再生的构建缓存、测试产物与临时打包目录。
# 默认保留 .build/desktop/Global Translator.app、dist/*.zip、dist/*.sha256、
# 离线依赖缓存与 .env*/密钥文件；传入 --all 可同时清理旧备份与 SwiftPM 离线依赖缓存。
set -euo pipefail
shopt -s nullglob

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

deep_clean=false
dry_run=false

usage() {
    cat <<'EOF'
用法 / Usage: scripts/clean.sh [--all|--deep] [--dry-run|-n] [-h|--help]

选项:
  (默认)          清理可再生 SwiftPM 编译产物、测试截图/日志、覆盖率与 dist/stage/
                  保留 .build/desktop/Global Translator.app、dist/*.zip/.sha256 与离线依赖缓存
  --all, --deep   额外清理 .build/desktop/backup-*、.build/extension/ 与 SwiftPM 离线依赖缓存
  --dry-run, -n   仅预览将要删除的路径，不执行删除
  -h, --help      显示本帮助信息
EOF
}

for arg in "$@"; do
    case "$arg" in
        --all|--deep) deep_clean=true ;;
        --dry-run|-n) dry_run=true ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

candidates=(
    .build/out
    .build/arm64-apple-macosx
    .build/build.db
    .build/manifest.pif
    .build/debug.yaml
    .build/release.yaml
    .build/plugin-tools.yaml
    .build/.buildSystem_debug
    .build/.buildSystem_release
    .build/debug
    .build/release
    .build/shots
    .build/launchagents-baseline.txt
    .build/*.log
    dist/stage
    test-results
    screenshots
    videos
    traces
    .screenshots
    .playwright-cli
    coverage
    *.log
    *.heapsnapshot
    *.hprof
)

if [[ "$deep_clean" == true ]]; then
    candidates+=(
        .build/desktop/backup-*
        .build/extension
        .build/prebuilts
        .build/repositories
        .build/checkouts
        .build/workspace-state.json
    )
fi

removed_count=0
for target in "${candidates[@]}"; do
    if [[ -e "$target" || -L "$target" ]]; then
        if [[ "$dry_run" == true ]]; then
            echo "[dry-run] 会删除: $target"
        else
            rm -rf "$target"
            echo "已删除: $target"
        fi
        removed_count=$((removed_count + 1))
    fi
done

if [[ "$removed_count" -eq 0 ]]; then
    echo "工作区已干净，没有需要清理的产物。"
elif [[ "$dry_run" == true ]]; then
    echo "演习完成：共匹配 ${removed_count} 项。"
else
    echo "清理完成：共清除 ${removed_count} 项。"
fi
