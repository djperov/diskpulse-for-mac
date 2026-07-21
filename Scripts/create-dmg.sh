#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DiskPulse for Mac"
APP_SLUG="DiskPulse-for-Mac"
VERSION="${1:-1.0.0}"
BUILD_DIR="$ROOT_DIR/.build-cache"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$DIST_DIR"

cd "$ROOT_DIR"
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/swiftpm" \
swift build -c release --disable-sandbox

cp "$ROOT_DIR/.build/release/MestoNaMak" "$CONTENTS_DIR/MacOS/$APP_NAME"
chmod +x "$CONTENTS_DIR/MacOS/$APP_NAME"

ASSET_DIR="$DIST_DIR/AppIcon.xcassets"
APP_ICONSET="$ASSET_DIR/AppIcon.appiconset"
rm -rf "$ASSET_DIR"
mkdir -p "$APP_ICONSET"
sips -z 16 16 "$ROOT_DIR/Assets/DiskPulseIcon.png" --out "$APP_ICONSET/icon-16.png" >/dev/null
sips -z 32 32 "$ROOT_DIR/Assets/DiskPulseIcon.png" --out "$APP_ICONSET/icon-16@2x.png" >/dev/null
sips -z 32 32 "$ROOT_DIR/Assets/DiskPulseIcon.png" --out "$APP_ICONSET/icon-32.png" >/dev/null
sips -z 64 64 "$ROOT_DIR/Assets/DiskPulseIcon.png" --out "$APP_ICONSET/icon-32@2x.png" >/dev/null
sips -z 128 128 "$ROOT_DIR/Assets/DiskPulseIcon.png" --out "$APP_ICONSET/icon-128.png" >/dev/null
sips -z 256 256 "$ROOT_DIR/Assets/DiskPulseIcon.png" --out "$APP_ICONSET/icon-128@2x.png" >/dev/null
sips -z 256 256 "$ROOT_DIR/Assets/DiskPulseIcon.png" --out "$APP_ICONSET/icon-256.png" >/dev/null
sips -z 512 512 "$ROOT_DIR/Assets/DiskPulseIcon.png" --out "$APP_ICONSET/icon-256@2x.png" >/dev/null
sips -z 512 512 "$ROOT_DIR/Assets/DiskPulseIcon.png" --out "$APP_ICONSET/icon-512.png" >/dev/null
sips -z 1024 1024 "$ROOT_DIR/Assets/DiskPulseIcon.png" --out "$APP_ICONSET/icon-512@2x.png" >/dev/null
cat > "$APP_ICONSET/Contents.json" <<'EOF'
{"images":[
{"filename":"icon-16.png","idiom":"mac","scale":"1x","size":"16x16"},
{"filename":"icon-16@2x.png","idiom":"mac","scale":"2x","size":"16x16"},
{"filename":"icon-32.png","idiom":"mac","scale":"1x","size":"32x32"},
{"filename":"icon-32@2x.png","idiom":"mac","scale":"2x","size":"32x32"},
{"filename":"icon-128.png","idiom":"mac","scale":"1x","size":"128x128"},
{"filename":"icon-128@2x.png","idiom":"mac","scale":"2x","size":"128x128"},
{"filename":"icon-256.png","idiom":"mac","scale":"1x","size":"256x256"},
{"filename":"icon-256@2x.png","idiom":"mac","scale":"2x","size":"256x256"},
{"filename":"icon-512.png","idiom":"mac","scale":"1x","size":"512x512"},
{"filename":"icon-512@2x.png","idiom":"mac","scale":"2x","size":"512x512"}
],"info":{"author":"xcode","version":1}}
EOF
xcrun actool "$ASSET_DIR" --compile "$CONTENTS_DIR/Resources" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$DIST_DIR/AppIcon-Info.plist" >/dev/null
rm -rf "$ASSET_DIR" "$DIST_DIR/AppIcon-Info.plist"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.djperov.diskpulse</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

plutil -lint "$CONTENTS_DIR/Info.plist"

DMG_DIR="$DIST_DIR/dmg-root"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_DIR" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

DMG_PATH="$DIST_DIR/$APP_SLUG-$VERSION.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_DIR"

echo "Created: $DMG_PATH"
