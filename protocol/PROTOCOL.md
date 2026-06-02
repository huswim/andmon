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
{"width":2960,"height":1848,"fps":60,"bitrate":12000000,"dataRateLimit":12000000,"codec":"video/hevc"}
```

The host sends an initial `PING` and waits for the matching `PONG` before
starting capture. Codec parameter sets are sent as `CODEC_CONFIG` before the first
`VIDEO`, after reconnect, and whenever VideoToolbox produces new values.
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

## AOA Identification

The host uses AOA request `51` to query protocol support, request `52` to send
identification strings, and request `53` to enter accessory mode.

```text
manufacturer = "Andmon"
model        = "Galaxy Tab S8 Ultra Submonitor"
description  = "Wired extended desktop receiver"
version      = "1.0"
uri          = "https://localhost/andmon"
serial       = "andmon-mvp"
```
