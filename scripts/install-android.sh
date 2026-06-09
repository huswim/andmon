#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export ANDROID_HOME=${ANDROID_HOME:-"$HOME/Library/Android/sdk"}

(cd "$ROOT/android" && ./gradlew assembleDebug)
adb install -r "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
adb shell am start -n dev.andmon.receiver/.MainActivity

