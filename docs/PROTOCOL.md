# Andmon Wire Protocol

The host and receiver communicate over the Android Open Accessory bulk stream.
Every message is a 24-byte big-endian header followed by `payloadLength` bytes.
USB reads may split or combine messages. Both implementations retain partial
input until a complete frame is available.

```text
offset size field
0      4    magic = ASCII "ANDM"
4      1    version = 1
5      1    type
6      2    flags
8      4    payloadLength
12     4    sequence
16     8    ptsMicros
```

Payloads larger than `8 MiB`, invalid magic, and versions other than `1` are
protocol errors. All JSON payloads are UTF-8.

| Type | Value | Direction | Payload |
| --- | ---: | --- | --- |
| `HELLO` | 1 | Android -> Mac | JSON panel and decoder capabilities |
| `CONFIG` | 2 | Mac -> Android | JSON stream configuration |
| `CODEC_CONFIG` | 3 | Mac -> Android | Annex B parameter sets (SPS/PPS for AVC, VPS/SPS/PPS for HEVC) |
| `VIDEO` | 4 | Mac -> Android | One Annex B access unit |
| `PING` | 5 | Either | Optional opaque token |
| `PONG` | 6 | Either | Exact `PING` payload |
| `STOP` | 7 | Either | Optional UTF-8 reason |
| `ERROR` | 8 | Either | JSON diagnostic |
| `KEYFRAME_REQUEST` | 9 | Android -> Mac | Empty payload requesting an IDR access unit |
| `AUDIO` | 10 | Mac -> Android | One raw Opus audio packet |
| `TOUCH` | 11 | Android -> Mac | JSON touch event parameters |

`VIDEO` flag bit `0` marks an IDR access unit. `ptsMicros` is the presentation
timestamp in microseconds and is meaningful for `VIDEO`.

## Session

Android sends `HELLO` after accessory streams open:

```json
{"panelWidth":2960,"panelHeight":1848,"landscape":true,"decoder":"video/hevc"}
```

Android also sends a fresh `HELLO` when its receiver session reopens after the
app returns to the foreground. If the host is already streaming, it restarts
the encoder and repeats configuration so the new decoder receives fresh HEVC
parameter sets and an IDR access unit.

The host rejects mismatched panel dimensions, creates the virtual monitor, and
sends:

```json
{"width":2960,"height":1848,"fps":60,"bitrate":12000000,"dataRateLimit":12000000,"codec":"video/hevc","audioEnabled":true,"touchEnabled":false}
```

The host sends an initial `PING` and waits for the matching `PONG` before
starting capture. Codec parameter sets are sent as `CODEC_CONFIG` before the first
`VIDEO`, after reconnect, and whenever VideoToolbox produces new values.
`audioEnabled` is an optional boolean indicating if system audio streaming is enabled.
`touchEnabled` is an optional boolean indicating if mouse input simulation from the tablet is enabled (default to false).
While streaming, the host sends a heartbeat `PING` every two seconds. If Android
does not return the matching `PONG` within three seconds, the host stops capture,
deactivates the virtual display, and publishes `Negotiating`. The host creates a
fresh virtual display and repeats configuration after the receiver returns with
a new `HELLO`.
`bitrate` is the selected encoder target and `dataRateLimit` is its one-second
cap. When the selected bitrate changes, the host keeps the accessory stream
open, re-sends `CONFIG` and `PING`, and starts a new encoder after the matching
`PONG`.
If Android drops a video access unit because its decoder has no immediately
available input buffer, it sends `KEYFRAME_REQUEST`. The host forces a new IDR
access unit so the low-latency receiver can resume from a valid reference frame.

If `touchEnabled` is configured true, Android captures touch events on the display surface and sends them to the Mac as `TOUCH` messages:

* **Cursor Movement / Click**:
  ```json
  {"action":0,"x":0.5,"y":0.5}
  ```
  Where:
  * `action` is `0` (touch down), `1` (touch move/drag), or `2` (touch up).
  * `x` and `y` are normalized floats from `0.0` to `1.0`.

* **Scroll**:
  ```json
  {"action":3,"dx":12.5,"dy":-4.0}
  ```
  Where:
  * `action` is `3` (swipe scrolling).
  * `dx` and `dy` are relative pixel offsets since the last touch event.

* **Mouse Move (Hover)**:
  ```json
  {"action":4,"x":0.5,"y":0.5}
  ```
  Where:
  * `action` is `4` (cursor position update without click).
  * `x` and `y` are normalized floats from `0.0` to `1.0`.


## AOA Connection Handshake & Identification

Before the bulk stream starts, the macOS host identifies the connected Android device and performs a handshake to switch it into Accessory Mode.

### USB Control Transfers

The host uses standard AOA control requests (standard USB requests with vendor-specific values):

1. **Get Protocol (Request 51)**: Query if the device supports the Android Accessory Protocol.
   * `bmRequestType`: `0xC0` (Device-to-Host, Vendor, Device)
   * `bRequest`: 51
   * `wValue`: 0
   * `wIndex`: 0
   * `wLength`: 2
   * Returns the protocol version (must be >= 1).

2. **Send Identification (Request 52)**: Send identification strings to the device.
   * `bmRequestType`: `0x40` (Host-to-Device, Vendor, Device)
   * `bRequest`: 52
   * `wValue`: 0
   * `wIndex`: String index (0 to 5)
   * `wLength`: String length + 1 (null-terminated)
   * `data`: The identification string.

3. **Start Accessory (Request 53)**: Request the device to restart in accessory mode.
   * `bmRequestType`: `0x40` (Host-to-Device, Vendor, Device)
   * `bRequest`: 53
   * `wValue`: 0
   * `wIndex`: 0
   * `wLength`: 0

### Identification Strings

The host sends the following identification strings to identify itself to the Android OS:

| Index | Field | Value |
| :--- | :--- | :--- |
| 0 | Manufacturer | `Andmon` |
| 1 | Model | `Galaxy Tab S8 Ultra Submonitor` |
| 2 | Description | `Wired extended desktop receiver` |
| 3 | Version | `1.0` |
| 4 | URI | `https://localhost/andmon` |
| 5 | Serial Number | `andmon-mvp` |

