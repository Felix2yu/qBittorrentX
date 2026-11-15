#!/bin/bash
# 组装 .app。**必须在有 Xcode 的机器上跑**：CommandLineTools 缺 libSwiftUIMacros.dylib，
# @State / @Binding / @AppStorage 全部编不过（已实测）。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="qBittorrentX"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "构建 ${APP_NAME}（release）…"
swift build -c release -Xswiftc -disable-sandbox

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/"
cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# 没有 *.bundle 拷贝循环：本工程不用 String Catalog，中文字面量直接写在源码里。

echo "代码签名…"
# 钥匙串 ACL 的「始终允许」记的是 App 的 designated requirement。
# ad-hoc 签名的 DR 只有 cdhash，每次重新编译都变，授权随即失效、每次启动都重新弹窗；
# 用证书签名后 DR 变成 anchor apple generic + certificate leaf，与二进制内容无关，授权一次即可长期生效。
IDENTITY="${QBX_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/^[[:space:]]*[0-9]*) [A-Fa-f0-9]* "\(.*\)"/\1/p' \
        | grep -E '^(Apple Development|Developer ID Application):' | head -1 || true)"
fi
if [[ -n "$IDENTITY" ]]; then
    codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP_BUNDLE"
    echo "  身份：$IDENTITY"
else
    codesign --force --deep --sign - "$APP_BUNDLE"
    echo "  警告：未找到代码签名身份，退回 ad-hoc；每次重新打包后钥匙串「始终允许」都会失效。"
fi

echo "完成：$APP_BUNDLE"
echo "  运行：open $APP_BUNDLE"
echo "  安装：cp -R $APP_BUNDLE /Applications/"