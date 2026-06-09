# Andmon Wired Galaxy Tab Submonitor MVP

Developer prototype for using a Galaxy Tab S8 Ultra as a wired extended display
for an Apple-silicon Mac. The runtime path is:

1. The macOS menu bar host switches the tablet into Android Open Accessory (AOA)
   mode through `libusb`.
2. Android launches the native accessory receiver and sends `HELLO`.
3. The host creates a private `CGVirtualDisplay` alongside a SwiftUI menu bar UI.
   It captures video and audio with ScreenCaptureKit, encodes HEVC with VideoToolbox
   and Opus with AudioToolbox, then streams them over the accessory bulk endpoints.
4. Android decodes HEVC directly into a landscape `SurfaceView`.

This is a direct-run prototype. It uses undocumented macOS APIs and is not
appropriate for App Store distribution. It intentionally targets one fixed
Galaxy Tab S8 Ultra profile: a `1480 x 924` HiDPI desktop backed by the tablet's
native `2960 x 1848` landscape panel pixels at `60 FPS`.
Set the tablet's screen mode to `Natural`; the virtual display and full-range
HEVC stream use the matching sRGB / BT.709 SDR color profile.

## Prerequisites

- macOS 26 or newer and Xcode 26.5
- Apple-silicon Mac
- Homebrew `libusb` for building the distributable macOS app: `brew install libusb`
- Android Studio or JDK 17: `brew install openjdk@17`
- Android SDK 36 and Build Tools 36.0.0
- Galaxy Tab S8 Ultra with the Android app installed once during development

The cable-only acceptance test does not use USB debugging. Disable USB
debugging after installing the receiver.

## Build

Build and test the macOS host:

```sh
cd mac
swift test
swift build
swift run AndmonHost --virtual-display-gate
swift run AndmonHost --aoa-gate
swift run AndmonHost
```

Build a distributable macOS menu bar app with a bundled `libusb`:

```sh
./scripts/build-mac-app.sh
open mac/.build/release/Andmon.app
```

The generated `Andmon.app` does not require Homebrew or a separately installed
`libusb` at runtime. The packaging script uses Homebrew `libusb` as its input,
copies the dylib and its LGPL license into the app bundle, and applies an ad hoc
signature for direct local distribution.

Build and test Android with Gradle 9.4.1:

```sh
export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
cd android
./gradlew test
./gradlew lint
./gradlew assembleDebug
```

The root scripts wrap the common workflows:

```sh
./scripts/test.sh
./scripts/build.sh
./scripts/install-android.sh
./scripts/run.sh
```

To provision the SDK from Homebrew command-line tools:

```sh
brew install --cask android-commandlinetools
export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
sdkmanager --licenses
sdkmanager 'platforms;android-36' 'build-tools;36.0.0'
```

Install `android/app/build/outputs/apk/debug/app-debug.apk` once with Android
Studio or `adb install`. Runtime connections use AOA and do not depend on ADB.

## Compatibility Gates

The host performs two gates before streaming:

1. It creates a private virtual display and validates a `1480 x 924` logical
   HiDPI mode backed by `2960 x 1848` pixels.
2. It negotiates AOA, reconnects after the USB mode switch, opens accessory
   bulk endpoints, receives Android `HELLO`, and completes `PING` / `PONG`.

Failures are visible in the menu bar status and logged to stderr. The virtual
display is retained only for an active accessory session, so detach removes the
extra Mac display. The menu bar host automatically retries after cable detach or
recoverable failures until `Stop` is selected; `Resume` starts negotiation again.
If the Android receiver app is closed while the cable remains attached, launch
`Andmon Receiver` again from the tablet app launcher. It reopens the existing AOA
accessory session without requiring a cable reconnect.

ScreenCaptureKit requires Screen Recording permission. On the first run, grant
the prompt in System Settings. The host reports the missing permission and
retries instead of leaving a stale virtual display behind.

## Troubleshooting

Android accessory mode can remain latched to the identity of a previously run
AOA tool. If `--aoa-gate` opens USB but times out waiting for `PONG`, disconnect
and reconnect the cable before retrying. Reboot the tablet if Samsung's USB
stack continues advertising the older accessory identity.

## References

The `references/` symlinks point to the local AOA throughput tester and virtual
display CLI used to validate this MVP. Measured verified Mac-to-Android AOA
throughput reached `16.3 MiB/s`, with a raw ceiling of `20.2 MiB/s`.

The dynamic SwiftUI menu bar popover provides real-time encoding metrics and a
slider to adjust the streaming bitrate dynamically between `10` and `100 Mbps`.
Changing the bitrate restarts only the active encoder so the new value takes
effect without reopening USB or recreating the virtual display. The UI also
includes a toggle for the low-latency Opus audio stream. The encoder uses
`AverageBitRate` with a one-second `DataRateLimits` cap. Recoverable connection
failures deactivate the virtual display before retrying and create a fresh
display only after the tablet reconnects. The default `12 Mbps` HEVC stream
leaves comfortable headroom.

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the wire format.
