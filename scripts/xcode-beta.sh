#!/bin/bash
# xcode-beta.sh — 选择本机安装的 Xcode Beta 作为 Apple 平台开发工具链。
# 用法:
#   source ~/codex-apple-env/xcode-beta.sh     # 在当前 shell 设置 DEVELOPER_DIR
#   . "$(dirname "$0")/xcode-beta.sh"          # 在其他脚本内复用
# 说明: 本机只有 /Applications/Xcode-beta.app，没有正式版 Xcode。
set -euo pipefail

XCODE_BETA_APP="${XCODE_BETA_APP:-/Applications/Xcode-beta.app}"

if [ ! -x "$XCODE_BETA_APP/Contents/Developer/usr/bin/xcodebuild" ]; then
    printf 'Xcode Beta 不可用: %s\n' "$XCODE_BETA_APP" >&2
    return 1 2>/dev/null || exit 1
fi

export DEVELOPER_DIR="$XCODE_BETA_APP/Contents/Developer"

if [ -t 1 ]; then
    printf 'DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"
fi
