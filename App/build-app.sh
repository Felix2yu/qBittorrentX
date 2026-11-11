#!/bin/bash
# 组装 .app。**必须在有 Xcode 的机器上跑**：CommandLineTools 缺 libSwiftUIMacros.dylib，
# @State / @Binding / @AppStorage 全部编不过（已实测）。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="qBittorrentX"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "构建 $APP_NAME（release）…"
swift build -c release -Xswiftc -disable-sandbox

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/"

# 没有 *.bundle 拷贝循环：本工程不用 String Catalog，中文字面量直接写在源码里。

echo "ad-hoc 签名…"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "完成：$APP_BUNDLE"
echo "  运行：open $APP_BUNDLE"
echo "  安装：cp -R $APP_BUNDLE /Applications/"