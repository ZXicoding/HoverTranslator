#!/bin/bash
# 打包分发包
#
# 固定命名：HoverTranslator-macOS/ 与 HoverTranslator-macOS.zip
# 每次运行都会【先删掉旧包再生成】，所以新版本直接替代旧版本，不会堆积 v1.1/v1.2…
#
# 用法： ./package.sh
# 版本号只改 build.sh 里的 VERSION=… 一处（会写入 Info.plist 和 VERSION.txt）。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(grep -E '^VERSION=' build.sh | head -1 | sed 's/.*="\(.*\)"/\1/')"
OUT="dist"
NAME="HoverTranslator-macOS"
APP="${OUT}/${NAME}/HoverTranslator.app"
ZIP="${OUT}/${NAME}.zip"

echo ">>> 打包 v${VERSION}（固定命名，覆盖旧包）"
rm -rf "${OUT}/${NAME}" "${ZIP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${OUT}/${NAME}/源码" .module-cache

swiftc -O -suppress-warnings -target arm64-apple-macos14.0 -module-cache-path "$PWD/.module-cache" \
    -o "${OUT}/.ht-arm64" main.swift \
    -framework Cocoa -framework Vision -framework ScreenCaptureKit \
    -framework AVFoundation -framework CoreGraphics -framework ImageIO
swiftc -O -suppress-warnings -target x86_64-apple-macos14.0 -module-cache-path "$PWD/.module-cache" \
    -o "${OUT}/.ht-x86" main.swift \
    -framework Cocoa -framework Vision -framework ScreenCaptureKit \
    -framework AVFoundation -framework CoreGraphics -framework ImageIO
lipo -create "${OUT}/.ht-arm64" "${OUT}/.ht-x86" -output "${APP}/Contents/MacOS/HoverTranslator"
chmod +x "${APP}/Contents/MacOS/HoverTranslator"
rm -f "${OUT}/.ht-arm64" "${OUT}/.ht-x86"

cp AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HoverTranslator</string>
  <key>CFBundleDisplayName</key><string>HoverTranslator</string>
  <key>CFBundleExecutable</key><string>HoverTranslator</string>
  <key>CFBundleIdentifier</key><string>com.example.hovertranslator</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
EOF

codesign --force --deep --sign - --identifier "com.example.hovertranslator" \
    -r='designated => identifier "com.example.hovertranslator"' "${APP}" >/dev/null 2>&1 \
  || codesign --force --deep --sign - --identifier "com.example.hovertranslator" "${APP}" >/dev/null 2>&1 || true
xattr -cr "${APP}" 2>/dev/null || true

cp docs/使用说明.txt "${OUT}/${NAME}/"
cp docs/解决打不开的问题.command "${OUT}/${NAME}/"
chmod +x "${OUT}/${NAME}/解决打不开的问题.command"
cp main.swift build.sh AppIcon.icns 修复说明.md "${OUT}/${NAME}/源码/"

cat > "${OUT}/${NAME}/VERSION.txt" <<EOF
HoverTranslator v${VERSION}
构建日期: $(date +%F)
架构: Universal (arm64 + x86_64)
最低系统: macOS 14.0
签名: ad-hoc（无开发者证书，首次打开需右键->打开）
EOF

COPYFILE_DISABLE=1 ditto -c -k --keepParent "${OUT}/${NAME}" "${ZIP}"
echo ""
echo "✅ 已生成 ${ZIP}（v${VERSION}）"
ls -lh "${ZIP}" | awk '{print "   大小:", $5}'
shasum -a 256 "${ZIP}" | awk '{print "   SHA256:", $1}'
echo "   旧版包已删除：每次都是同一个文件名，直接覆盖。"
