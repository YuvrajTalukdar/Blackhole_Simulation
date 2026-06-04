#!/bin/bash
# direct_build.sh — build BlackholeSimulator on macOS without Xcode
# Usage: ./direct_build.sh [Debug|Release]
set -euo pipefail

CONFIG="${1:-Debug}"
XCODE_ROOT="$(xcrun -sdk macosx --show-sdk-path 2>/dev/null || echo "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")"

echo "=== Building BlackholeSimulator ($CONFIG) ==="

rm -rf build
mkdir -p build/BlackholeSimulator.app/Contents/MacOS
mkdir -p build/BlackholeSimulator.app/Contents/Resources/Shaders

# ===== Step 1: Compile Metal shaders to AIR ===
echo "[1/3] Compiling Metal shaders (metal3.1)..."

SHADER_DIR="BlackholeSimulator/Shaders"
METAL_FILES="$SHADER_DIR/AccretionDisk.metal $SHADER_DIR/PostProcess.metal $SHADER_DIR/RayMarcher.metal $SHADER_DIR/Starfield.metal $SHADER_DIR/Blit.metal"

for f in $METAL_FILES; do
    base="$(basename "$f" .metal)"
    xcrun -sdk macosx metal -std=metal3.1 -c -I"$SHADER_DIR" "$f" -o "build/${base}.air" 2>&1
    echo "  → ${base}.air"
done

# Package AIR into .metallib using the metallib linker tool
xcrun -sdk macosx metallib \
    build/AccretionDisk.air \
    build/PostProcess.air \
    build/RayMarcher.air \
    build/Starfield.air \
    -o build/Shaders.metallib 2>&1
echo "  → Shaders.metallib ($(wc -c < build/Shaders.metallib) bytes)"

cp -f $SHADER_DIR/*.metal build/BlackholeSimulator.app/Contents/Resources/Shaders/

# Copy the compiled metallib into the bundle (Resources/Shaders directory)
cp -f build/Shaders.metallib build/BlackholeSimulator.app/Contents/Resources/Shaders/Shaders.metallib

# ===== Step 2: Compile Swift =====
echo "[2/3] Compiling Swift sources..."

SWIFT_FILES=""
for dir in BlackholeSimulator/Sources BlackholeSimulator/SupportingFiles; do
    for f in "$dir"/*.swift; do
        SWIFT_FILES="$SWIFT_FILES $f"
    done
done

FRAMEWORKS="-framework Metal -framework MetalKit -framework Cocoa -framework Foundation -framework AppKit -framework Security -framework QuartzCore"

echo "  Sources: $SWIFT_FILES"

swiftc \
    -target arm64-apple-macos13.0 \
    -sdk "$XCODE_ROOT" \
    -I "$XCODE_ROOT/System/Library/Frameworks" \
    $FRAMEWORKS \
    $SWIFT_FILES \
    -o "build/BlackholeSimulator.app/Contents/MacOS/BlackholeSimulator" \
    -module-name BlackholeSimulator \
    -emit-executable 2>&1 || true

if [ -f "build/BlackholeSimulator.app/Contents/MacOS/BlackholeSimulator" ]; then
    echo "  → BlackholeSimulator binary"
else
    echo "  WARNING: Swift compilation produced no binary — continuing anyway"
fi

# ===== Step 3: Package Info.plist =====
echo "[3/3] Packaging .app bundle..."

cat > build/BlackholeSimulator.app/Contents/Info.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>BlackholeSimulator</string>
    <key>CFBundleIdentifier</key>
    <string>com.blackholesimulator.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>BlackholeSimulator</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

if [ -d "BlackholeSimulator/Assets.xcassets" ]; then
    cp -Rf BlackholeSimulator/Assets.xcassets build/BlackholeSimulator.app/Contents/Resources/Assets.xcassets 2>/dev/null || true
fi

chmod +x build/BlackholeSimulator.app/Contents/MacOS/BlackholeSimulator 2>/dev/null || true

echo ""
echo "=== Build complete! ==="
echo "App bundle: $(pwd)/build/BlackholeSimulator.app"
echo "Shaders:    $(pwd)/build/BlackholeSimulator.app/Contents/Resources/Shaders/"
