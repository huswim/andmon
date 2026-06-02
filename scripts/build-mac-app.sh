#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MAC_ROOT="$ROOT/mac"

find_libusb() {
    if [ -n "${LIBUSB_DYLIB:-}" ] && [ -f "$LIBUSB_DYLIB" ]; then
        printf '%s\n' "$LIBUSB_DYLIB"
        return
    fi
    for candidate in \
        /opt/homebrew/opt/libusb/lib/libusb-1.0.dylib \
        /usr/local/opt/libusb/lib/libusb-1.0.dylib
    do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    printf '%s\n' "libusb was not found. Install it for packaging with: brew install libusb" >&2
    exit 1
}

LIBUSB=$(find_libusb)
LIBUSB_PREFIX=$(CDPATH= cd -- "$(dirname -- "$LIBUSB")/.." && pwd)
cd "$MAC_ROOT"
swift build -c release
BIN_DIR=$(cd "$MAC_ROOT" && swift build -c release --show-bin-path)
APP="$BIN_DIR/Andmon.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources"
cp "$BIN_DIR/AndmonHost" "$CONTENTS/MacOS/AndmonHost"
cp -L "$LIBUSB" "$CONTENTS/Frameworks/libusb-1.0.dylib"
chmod u+w "$CONTENTS/Frameworks/libusb-1.0.dylib"
install_name_tool -id "@rpath/libusb-1.0.dylib" "$CONTENTS/Frameworks/libusb-1.0.dylib"

if [ -f "$LIBUSB_PREFIX/COPYING" ]; then
    cp "$LIBUSB_PREFIX/COPYING" "$CONTENTS/Resources/LICENSE-libusb.txt"
fi

plutil -create xml1 "$CONTENTS/Info.plist"
plutil -insert CFBundleExecutable -string AndmonHost "$CONTENTS/Info.plist"
plutil -insert CFBundleIdentifier -string dev.andmon.host "$CONTENTS/Info.plist"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$CONTENTS/Info.plist"
plutil -insert CFBundleName -string Andmon "$CONTENTS/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$CONTENTS/Info.plist"
plutil -insert CFBundleShortVersionString -string 0.1 "$CONTENTS/Info.plist"
plutil -insert CFBundleVersion -string 1 "$CONTENTS/Info.plist"
plutil -insert LSMinimumSystemVersion -string 26.0 "$CONTENTS/Info.plist"
plutil -insert LSUIElement -bool true "$CONTENTS/Info.plist"

codesign --force --sign - "$CONTENTS/Frameworks/libusb-1.0.dylib"
codesign --force --sign - "$CONTENTS/MacOS/AndmonHost"
codesign --force --sign - "$APP"

printf 'Built %s\n' "$APP"
