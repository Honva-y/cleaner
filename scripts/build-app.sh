#!/bin/bash
# 构建 Cleaner.app（不需要 Xcode，只需 Command Line Tools）
#   scripts/build-app.sh            # release 构建，输出 build/Cleaner.app
#   scripts/build-app.sh --open     # 构建后直接打开
#   scripts/build-app.sh --install  # 构建后复制到 /Applications（启动台里才能看到）
#   两个参数可以一起用，此时打开的是 /Applications 里的副本
#   CODESIGN_IDENTITY="证书名" scripts/build-app.sh   # 指定签名证书，设为 - 强制 ad-hoc
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
APP=build/Cleaner.app
INSTALL_DIR=/Applications
# 默认用本机已有的自签名证书
SIGN_IDENTITY="${CODESIGN_IDENTITY:-SnapLite Dev}"

OPEN=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --open) OPEN=1 ;;
    --install) INSTALL=1 ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done

swift build -c "$CONFIG" --product Cleaner
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Cleaner"

# logo 源图或生成脚本有更新时重新生成图标
if [ ! -f Resources/AppIcon.icns ] || [ Resources/AppIcon-source.png -nt Resources/AppIcon.icns ] \
   || [ scripts/make-icon.swift -nt Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift Resources/AppIcon-source.png Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cleaner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 用固定证书签名，系统按“Bundle ID + 证书”识别 App，重新构建后“完全磁盘访问”授权仍然有效。
# 找不到证书时退回 ad-hoc：系统只能按代码哈希识别，每次重新构建都要重新授权。
if [ "$SIGN_IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
  echo "找不到签名证书“$SIGN_IDENTITY”，改用 ad-hoc 签名，重新构建后需要重新授予完全磁盘访问权限" >&2
  SIGN_IDENTITY=-
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

echo "已生成 $APP（签名：$([ "$SIGN_IDENTITY" = "-" ] && echo ad-hoc || echo "$SIGN_IDENTITY")）"

if [ "$INSTALL" = 1 ]; then
  # 正在运行时先退出，避免替换掉运行中的 App
  if pgrep -xq Cleaner; then
    osascript -e 'quit app id "com.cleaner.app"' 2>/dev/null || true
  fi
  rm -rf "$INSTALL_DIR/Cleaner.app"
  ditto "$APP" "$INSTALL_DIR/Cleaner.app"
  APP="$INSTALL_DIR/Cleaner.app"
  echo "已安装到 $APP"
fi

if [ "$OPEN" = 1 ]; then
  open "$APP"
fi
