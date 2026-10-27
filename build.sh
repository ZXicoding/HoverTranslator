#!/bin/bash
# HoverTranslator 一键编译打包（菜单栏常驻，无 Dock 图标）
#
# 用法：
#   ./build.sh                     # 增量编译（源码没改就复用已编译的 app）
#   ./build.sh --force             # 强制重新编译
#   ./build.sh --selftest          # 跑 OCR 自检（无需屏幕录制权限）
#   ./build.sh --test-translate hello
#   ./build.sh --test-tts hello
#   ./build.sh --check-permission
#
# 关于「屏幕与系统录音」权限（实测结论，别踩坑）：
#   macOS 的 TCC 对 ad-hoc 签名应用仍按二进制 cdhash 记账。只要重新编译过，
#   旧授权就匹配不上新二进制，表现为「设置里开关是开的，但应用仍被拒绝」。
#   本脚本做了两件事：① 显式写 identifier 型 designated requirement；
#   ② 增量编译，源码没改就不重建，权限不受影响。
#   若确实重建过（--force 或改了 main.swift），重新授权前先执行：
#       tccutil reset ScreenCapture com.example.hovertranslator
#   然后重新打开 App、在系统设置里打开开关、退出再重开。
#   彻底稳定需用真实 Apple 开发者证书（本机当前无可用签名身份）。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="HoverTranslator"
BUNDLE_ID="com.example.hovertranslator"
VERSION="1.4"
SRC="main.swift"
APP_DIR="$APP_NAME.app"
BIN="$APP_DIR/Contents/MacOS/$APP_NAME"

FORCE=0
TEST_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) TEST_ARGS+=("$arg") ;;
    esac
done

needs_build=0
if [ "$FORCE" -eq 1 ]; then
    needs_build=1
elif [ ! -f "$BIN" ]; then
    needs_build=1
elif [ "$SRC" -nt "$BIN" ]; then
    needs_build=1
elif [ "$0" -nt "$BIN" ]; then
    needs_build=1
elif [ ! -f "$APP_DIR/Contents/Info.plist" ]; then
    needs_build=1
fi

if [ "$needs_build" -eq 1 ]; then
    echo ">>> 编译中..."
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

    TARGET="$(uname -m)-apple-macos14.0"
    mkdir -p .module-cache
    swiftc -O -target "$TARGET" -module-cache-path "$PWD/.module-cache" -o "$BIN" "$SRC" \
        -framework Cocoa -framework Vision -framework ScreenCaptureKit \
        -framework AVFoundation -framework CoreGraphics -framework ImageIO

    cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
EOF
else
    echo ">>> 源码未变动，跳过编译（保持已授权二进制不变），只校验签名。"
fi

# 签名：ad-hoc + 固定 designated requirement（identifier 型），重编译不会丢权限
if ! codesign --verify --deep --strict "$APP_DIR" >/dev/null 2>&1; then
    echo ">>> 签名中..."
    if ! codesign --force --deep --sign - \
            --identifier "$BUNDLE_ID" \
            -r="designated => identifier \"$BUNDLE_ID\"" \
            "$APP_DIR" >/dev/null 2>&1; then
        echo ">>> 固定 requirement 签名失败，退回普通 ad-hoc 签名"
        codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR" >/dev/null 2>&1 || true
    fi
fi
xattr -cr "$APP_DIR" 2>/dev/null || true

DR="$(codesign -d -r- "$APP_DIR" 2>&1 | grep -E 'designated' | sed 's/^# //' || true)"
echo ""
echo "✅ 已生成 $APP_DIR"
echo "   签名要求: ${DR:-<ad-hoc 默认>}"
echo ""

if [ "${#TEST_ARGS[@]}" -gt 0 ]; then
    exec "$BIN" "${TEST_ARGS[@]}"
fi

cat <<'TIP'
首次运行需授权一次（否则截图会失败）：
  系统设置 → 隐私与安全性 → 屏幕与系统录音 → 打开 HoverTranslator
  授权后完全退出 App 再重新打开（权限必须重启才生效）

运行：open HoverTranslator.app
不授权也能先验证朗读和翻译：菜单栏 →「测试翻译与朗读（hello）」
TIP
