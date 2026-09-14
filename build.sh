#!/bin/zsh
set -eu
cd "${0:A:h}"
# Rebuild from a clean generated bundle so optional assets never persist.
rm -rf -- "MacDuo.app"
mkdir -p "MacDuo.app/Contents/MacOS" "MacDuo.app/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.2 Sources/*.swift -o "MacDuo.app/Contents/MacOS/DuoFoldDesktop" -framework Cocoa -framework MetalKit -framework ScreenCaptureKit -framework AVFoundation -framework IOKit -framework Vision -framework LocalAuthentication

if [[ -f Resources/HingeCreak.wav ]]; then
 cp Resources/HingeCreak.wav "MacDuo.app/Contents/Resources/"
fi
cp Resources/MacDuo.icns "MacDuo.app/Contents/Resources/"
cp Resources/Fold.metal "MacDuo.app/Contents/Resources/"
cp ThirdParty/Bendable/LICENSE "MacDuo.app/Contents/Resources/Bendable-LICENSE.txt"
cat > "MacDuo.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>DuoFoldDesktop</string><key>CFBundleIdentifier</key><string>com.berryxia.duofold.desktop.v1</string><key>CFBundleName</key><string>MacDuo</string><key>CFBundleDisplayName</key><string>MacDuo</string><key>CFBundleIconFile</key><string>MacDuo</string><key>CFBundleVersion</key><string>1200</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.2.0</string><key>LSMinimumSystemVersion</key><string>15.2</string><key>NSCameraUsageDescription</key><string>注视模式使用内置摄像头在本机判断您是否面向屏幕，转开时显示毛玻璃。不保存或上传摄像头画面。</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
# Local source builds use ad-hoc signing. Set your own identity for signed builds.
identity="${DUOFOLD_SIGNING_IDENTITY:--}"
codesign --force --sign "$identity" "MacDuo.app"
codesign --verify --strict "MacDuo.app"
