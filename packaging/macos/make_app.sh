#!/bin/sh
# Build Deadband.app: a launcher for THIS copy of Deadband, so it can be opened
# from Launchpad, Spotlight or the Dock like any other app.
#
#   sh packaging/macos/make_app.sh            # into /Applications (or ~/Applications)
#   sh packaging/macos/make_app.sh ~/Desktop  # somewhere else
#
# It runs Deadband with the Python from docs/macos.md ($HOME/deadband-venv);
# set DEADBAND_PYTHON to use another. The app points at this folder, so after
# moving the folder (or the venv), run this again. Output goes to
# ~/Library/Logs/Deadband.log.
set -e

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${DEADBAND_PYTHON:-$HOME/deadband-venv/bin/python}"
if [ -n "$1" ]; then
    DEST="$1"
elif [ -w /Applications ]; then
    DEST=/Applications
else
    DEST="$HOME/Applications"
fi

if [ ! -x "$PY" ]; then
    echo "No Python at $PY. Set it up first (docs/macos.md), or set DEADBAND_PYTHON."
    exit 1
fi

APP="$DEST/Deadband.app"
mkdir -p "$DEST"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# the icon, every size macOS asks for, from the 1024px artwork
WORK="$(mktemp -d)"
ICONSET="$WORK/Deadband.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$HERE/assets/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$HERE/assets/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Deadband.icns"
rm -rf "$WORK"

# A script can't say which CPU it's for, so macOS may start it under Rosetta
# (Intel) on Apple Silicon, where the arm64 hidapi/Qt the venv installed won't
# load. Ask for the native slice whenever the Mac has one.
cat > "$APP/Contents/MacOS/Deadband" <<EOF
#!/bin/sh
mkdir -p "\$HOME/Library/Logs"
exec >>"\$HOME/Library/Logs/Deadband.log" 2>&1
echo "--- \$(date)"
cd "$HERE" || exit 1
if [ "\$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then
    exec arch -arm64 "$PY" deadband.py "\$@"
fi
exec "$PY" deadband.py "\$@"
EOF
chmod +x "$APP/Contents/MacOS/Deadband"

VERSION="$(sed -n "s/^__version__ = '\(.*\)'/\1/p" "$HERE/version.py")"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>Deadband</string>
    <key>CFBundleDisplayName</key>        <string>Deadband</string>
    <key>CFBundleIdentifier</key>         <string>io.github.broroeror.deadband</string>
    <key>CFBundleExecutable</key>         <string>Deadband</string>
    <key>CFBundleIconFile</key>           <string>Deadband</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION:-0}</string>
    <key>LSApplicationCategoryType</key>  <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>LSArchitecturePriority</key>
    <array><string>arm64</string><string>x86_64</string></array>
</dict>
</plist>
EOF

# tell Launchpad / Spotlight about it now rather than whenever they next look
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true
touch "$APP"

echo "Built $APP"
