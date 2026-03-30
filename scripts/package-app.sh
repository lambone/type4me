#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && /bin/pwd -P)"
APP_PATH="${APP_PATH:-$PROJECT_DIR/dist/Type4Me.app}"
APP_NAME="Type4Me"
APP_EXECUTABLE="Type4Me"
APP_ICON_NAME="AppIcon"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.type4me.app}"
APP_VERSION="${APP_VERSION:-1.5.0}"
APP_BUILD="${APP_BUILD:-1}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
MICROPHONE_USAGE_DESCRIPTION="${MICROPHONE_USAGE_DESCRIPTION:-Type4Me 需要访问麦克风以录制语音并将其转换为文本。}"
APPLE_EVENTS_USAGE_DESCRIPTION="${APPLE_EVENTS_USAGE_DESCRIPTION:-Type4Me 需要辅助功能权限来注入转写文字到其他应用}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGNING_IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Type4Me Dev"; then
    SIGNING_IDENTITY="Type4Me Dev"
else
    SIGNING_IDENTITY="-"
fi

echo "Building universal release (arm64 + x86_64)..."
swift build -c release --package-path "$PROJECT_DIR" --arch arm64 --arch x86_64 2>&1 | grep -E "Build complete|Build succeeded|error:|warning:" || true

if [ -f "$PROJECT_DIR/.build/apple/Products/Release/Type4Me" ]; then
    BINARY="$PROJECT_DIR/.build/apple/Products/Release/Type4Me"
elif [ -f "$PROJECT_DIR/.build/release/Type4Me" ]; then
    BINARY="$PROJECT_DIR/.build/release/Type4Me"
else
    BINARY="$(find "$PROJECT_DIR/.build" -path '*/release/Type4Me' -type f -not -path '*/x86_64/*' -not -path '*/arm64/*' | head -n 1)"
fi

if [ ! -f "$BINARY" ]; then
    echo "Build failed: binary not found"
    exit 1
fi

echo "Packaging app bundle at $APP_PATH..."
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY" "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
cp "$PROJECT_DIR/Type4Me/Resources/${APP_ICON_NAME}.icns" "$APP_PATH/Contents/Resources/${APP_ICON_NAME}.icns" 2>/dev/null || true

cat >"$INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_EXECUTABLE}</string>
    <key>CFBundleIconFile</key>
    <string>${APP_ICON_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_SYSTEM_VERSION}</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>${MICROPHONE_USAGE_DESCRIPTION}</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>${APPLE_EVENTS_USAGE_DESCRIPTION}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

mkdir -p "$APP_PATH/Contents/Resources/Sounds"
cp "$PROJECT_DIR/Type4Me/Resources/Sounds/"*.wav "$APP_PATH/Contents/Resources/Sounds/" 2>/dev/null || true

# Copy SenseVoice model if available (for full DMG builds)
SENSEVOICE_MODEL_CACHE="$HOME/.cache/modelscope/hub/models/iic/SenseVoiceSmall"
if [ "${BUNDLE_SENSEVOICE_MODEL:-0}" = "1" ] && [ -d "$SENSEVOICE_MODEL_CACHE" ]; then
    echo "Bundling SenseVoice model..."
    mkdir -p "$APP_PATH/Contents/Resources/Models"
    cp -R "$SENSEVOICE_MODEL_CACHE" "$APP_PATH/Contents/Resources/Models/SenseVoiceSmall"
    echo "SenseVoice model bundled."
fi

# Copy sensevoice-server if built and BUNDLE_LOCAL_ASR is set
SENSEVOICE_DIST="$PROJECT_DIR/sensevoice-server/dist/sensevoice-server"
if [ "${BUNDLE_LOCAL_ASR:-0}" = "1" ] && [ -d "$SENSEVOICE_DIST" ]; then
    echo "Bundling sensevoice-server..."
    rm -rf "$APP_PATH/Contents/MacOS/sensevoice-server-dist" "$APP_PATH/Contents/MacOS/sensevoice-server"
    cp -R "$SENSEVOICE_DIST" "$APP_PATH/Contents/MacOS/sensevoice-server-dist"
    # Create a wrapper script at the expected path
    cat > "$APP_PATH/Contents/MacOS/sensevoice-server" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/sensevoice-server-dist/sensevoice-server" "$@"
WRAPPER
    chmod +x "$APP_PATH/Contents/MacOS/sensevoice-server"
    # Sign all binaries in the server dist for Gatekeeper
    find "$APP_PATH/Contents/MacOS/sensevoice-server-dist" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) \
        -exec codesign --force --sign "${SIGNING_IDENTITY}" {} \; 2>/dev/null || true
    echo "sensevoice-server bundled and signed."
fi

# Copy qwen3-asr-server if built and BUNDLE_LOCAL_ASR is set
QWEN3_DIST="$PROJECT_DIR/qwen3-asr-server/dist/qwen3-asr-server"
if [ "${BUNDLE_LOCAL_ASR:-0}" = "1" ] && [ -d "$QWEN3_DIST" ]; then
    echo "Bundling qwen3-asr-server..."
    rm -rf "$APP_PATH/Contents/MacOS/qwen3-asr-server-dist" "$APP_PATH/Contents/MacOS/qwen3-asr-server"
    cp -R "$QWEN3_DIST" "$APP_PATH/Contents/MacOS/qwen3-asr-server-dist"
    # Create a wrapper script at the expected path
    cat > "$APP_PATH/Contents/MacOS/qwen3-asr-server" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/qwen3-asr-server-dist/qwen3-asr-server" "$@"
WRAPPER
    chmod +x "$APP_PATH/Contents/MacOS/qwen3-asr-server"
    # Sign all binaries in the server dist for Gatekeeper
    find "$APP_PATH/Contents/MacOS/qwen3-asr-server-dist" -type f \( -name "*.dylib" -o -name "*.so" -o -name "*.metallib" -o -perm +111 \) \
        -exec codesign --force --sign "${SIGNING_IDENTITY}" {} \; 2>/dev/null || true
    echo "qwen3-asr-server bundled and signed."
fi

# Copy LLM model if available (for local LLM DMG builds)
LLM_MODEL_DIR="$PROJECT_DIR/sensevoice-server/models"
LLM_MODEL_SIZE="${BUNDLE_LOCAL_LLM:-0}"  # 0=none, 4b, 9b
if [ "$LLM_MODEL_SIZE" = "9b" ] && [ -f "$LLM_MODEL_DIR/Qwen3.5-9B-Q4_K_M.gguf" ]; then
    echo "Bundling Qwen3.5-9B LLM model (5.3GB)..."
    mkdir -p "$APP_PATH/Contents/Resources/Models"
    cp "$LLM_MODEL_DIR/Qwen3.5-9B-Q4_K_M.gguf" "$APP_PATH/Contents/Resources/Models/qwen3.5-9b-q4_k_m.gguf"
    echo "Qwen3.5-9B model bundled."
elif [ "$LLM_MODEL_SIZE" = "4b" ] && [ -f "$LLM_MODEL_DIR/qwen3-4b-q4_k_m.gguf" ]; then
    echo "Bundling Qwen3-4B LLM model (2.3GB)..."
    mkdir -p "$APP_PATH/Contents/Resources/Models"
    cp "$LLM_MODEL_DIR/qwen3-4b-q4_k_m.gguf" "$APP_PATH/Contents/Resources/Models/qwen3-4b-q4_k_m.gguf"
    echo "Qwen3-4B model bundled."
fi

# Copy third-party licenses
cp "$PROJECT_DIR/Type4Me/Resources/THIRD_PARTY_LICENSES.txt" "$APP_PATH/Contents/Resources/" 2>/dev/null || true

echo "Signing with '${SIGNING_IDENTITY}'..."
# PyInstaller dist dirs contain .dylibs and dist-info dirs that confuse
# codesign's bundle detection. Move server files out temporarily.
SERVER_TEMP=""
SV_DIST="$APP_PATH/Contents/MacOS/sensevoice-server-dist"
SV_WRAPPER="$APP_PATH/Contents/MacOS/sensevoice-server"
Q3_DIST="$APP_PATH/Contents/MacOS/qwen3-asr-server-dist"
Q3_WRAPPER="$APP_PATH/Contents/MacOS/qwen3-asr-server"
if [ -d "$SV_DIST" ] || [ -f "$SV_WRAPPER" ] || [ -d "$Q3_DIST" ] || [ -f "$Q3_WRAPPER" ]; then
    SERVER_TEMP="$(mktemp -d)"
    [ -d "$SV_DIST" ] && mv "$SV_DIST" "$SERVER_TEMP/sensevoice-server-dist"
    [ -f "$SV_WRAPPER" ] && mv "$SV_WRAPPER" "$SERVER_TEMP/sensevoice-server"
    [ -d "$Q3_DIST" ] && mv "$Q3_DIST" "$SERVER_TEMP/qwen3-asr-server-dist"
    [ -f "$Q3_WRAPPER" ] && mv "$Q3_WRAPPER" "$SERVER_TEMP/qwen3-asr-server"
fi
codesign -f -s "$SIGNING_IDENTITY" "$APP_PATH" 2>/dev/null && echo "Signed." || echo "Signing skipped (no identity available)."
if [ -n "$SERVER_TEMP" ]; then
    [ -d "$SERVER_TEMP/sensevoice-server-dist" ] && mv "$SERVER_TEMP/sensevoice-server-dist" "$SV_DIST"
    [ -f "$SERVER_TEMP/sensevoice-server" ] && mv "$SERVER_TEMP/sensevoice-server" "$SV_WRAPPER"
    [ -d "$SERVER_TEMP/qwen3-asr-server-dist" ] && mv "$SERVER_TEMP/qwen3-asr-server-dist" "$Q3_DIST"
    [ -f "$SERVER_TEMP/qwen3-asr-server" ] && mv "$SERVER_TEMP/qwen3-asr-server" "$Q3_WRAPPER"
    rm -rf "$SERVER_TEMP"
fi

echo "App bundle ready at $APP_PATH"
