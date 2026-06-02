#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export ANDROID_HOME=${ANDROID_HOME:-"$HOME/Library/Android/sdk"}

(cd "$ROOT/mac" && swift build)
(cd "$ROOT/android" && ./gradlew assembleDebug)
