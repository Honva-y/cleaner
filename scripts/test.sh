#!/bin/bash
# 运行单元测试。只装了 Command Line Tools 时，Testing 框架不在默认搜索路径里，需要手动指定。
set -euo pipefail
cd "$(dirname "$0")/.."

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$FW/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
  swift test --disable-xctest --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" -Xlinker -rpath -Xlinker "$FW" "$@"
else
  swift test "$@"
fi
