#!/bin/bash
# 打包成可以分发的安装包（本机和 GitHub Actions 共用）
#   scripts/package.sh    # 输出 build/Cleaner-<版本>.dmg 和 build/Cleaner-<版本>.zip
# 签名方式同 build-app.sh，可以用 CODESIGN_IDENTITY 指定证书
# 默认打通用版本（Apple 芯片 + Intel），可以用 ARCHS 覆盖
set -euo pipefail
cd "$(dirname "$0")/.."

export ARCHS="${ARCHS:-arm64 x86_64}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP=build/Cleaner.app
DMG="build/Cleaner-$VERSION.dmg"
ZIP="build/Cleaner-$VERSION.zip"

scripts/build-app.sh

# DMG：打开后把 Cleaner 拖到“应用程序”文件夹
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Cleaner.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
# GitHub 的 macOS 机器上 hdiutil 偶尔报 “资源忙”，失败时重试几次
for attempt in 1 2 3; do
  if hdiutil create -volname "Cleaner $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null; then
    break
  fi
  [ "$attempt" = 3 ] && exit 1
  sleep 5
done

# zip：用 ditto 压缩，保留签名
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "已生成 $DMG"
echo "已生成 $ZIP"
