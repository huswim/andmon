# Android Open Accessory (AOA) Protocol - Andmon Implementation

This document describes the implementation of the Android Open Accessory (AOA) protocol used by Andmon to establish a high-speed, low-latency communication channel between a macOS host and an Android receiver.

## 1. AOA Identification & Handshake

To initiate communication, the macOS host identifies a connected Android device and performs a handshake to switch it into Accessory Mode.

### 1.1 USB Control Transfers

The host uses standard AOA control requests (standard USB requests with vendor-specific values):

1.  **Get Protocol (Request 51)**: Query if the device supports the Android Accessory Protocol.
    *   `bmRequestType`: `0xC0` (Device-to-Host, Vendor, Device)
    *   `bRequest`: `51`
    *   `wValue`: `0`
    *   `wIndex`: `0`
    *   `wLength`: `2`
    *   Returns the protocol version (must be >= 1).

2.  **Send Identification (Request 52)**: Send identification strings to the device.
    *   `bmRequestType`: `0x40` (Host-to-Device, Vendor, Device)
    *   `bRequest`: `52`
    *   `wValue`: `0`
    *   `wIndex`: String index (0 to 5)
    *   `wLength`: String length + 1 (null-terminated)
    *   `data`: The identification string.

3.  **Start Accessory (Request 53)**: Request the device to restart in accessory mode.
    *   `bmRequestType`: `0x40` (Host-to-Device, Vendor, Device)
    *   `bRequest`: `53`
    *   `wValue`: `0`
    *   `wIndex`: `0`
    *   `wLength`: `0`

### 1.2 Identification Strings

Andmon uses the following identification strings (defined in `LibUSBBridge.m` and `PROTOCOL.md`):

| Index | Field | Value |
| :--- | :--- | :--- |
| 0 | Manufacturer | `Andmon` |
| 1 | Model | `Galaxy Tab S8 Ultra Submonitor` |
| 2 | Description | `Wired extended desktop receiver` |
| 3 | Version | `1.0` |
| 4 | URI | `https://localhost/andmon` |
| 5 | Serial Number | `andmon-mvp` |

---

## 2. Wire Protocol

Once the device is in Accessory Mode, communication happens over bulk IN and OUT endpoints. All messages follow a 24-byte big-endian header followed by an optional payload.

### 2.1 Message Header (24 bytes)

| Offset | Size | Field | Description |
| :--- | :--- | :--- | :--- |
| 0 | 4 | `magic` | ASCII "ANDM" (`0x41 0x4E 0x44 0x4D`) |
| 4 | 1 | `version` | Protocol version (currently `1`) |
| 5 | 1 | `type` | Message type (see below) |
| 6 | 2 | `flags` | Bit 0: IDR frame (for `VIDEO` messages) |
| 8 | 4 | `payloadLength` | Length of the following payload in bytes (Max 8 MiB) |
| 12 | 4 | `sequence` | Incremental sequence number |
| 16 | 8 | `ptsMicros` | Presentation timestamp in microseconds |

### 2.2 Message Types

| Type | Value | Direction | Description |
| :--- | :---: | :--- | :--- |
| `HELLO` | 1 | Android -> Mac | Panel dimensions and decoder capabilities (JSON) |
| `CONFIG` | 2 | Mac -> Android | Stream configuration (JSON) |
| `CODEC_CONFIG` | 3 | Mac -> Android | Annex B parameter sets (SPS/PPS) |
| `VIDEO` | 4 | Mac -> Android | Video access unit (Annex B) |
| `PING` | 5 | Either | Heartbeat or connectivity check |
| `PONG` | 6 | Either | Response to `PING` |
| `STOP` | 7 | Either | Graceful termination notice |
| `ERROR` | 8 | Either | Error reporting (JSON) |
| `KEYFRAME_REQUEST`| 9 | Android -> Mac | Request for an immediate IDR frame |

---

## 3. Session Management

### 3.1 Establishment
1.  **Handshake**: Host switches Android to Accessory Mode.
2.  **Greeting**: Android opens accessory streams and sends a `HELLO` message containing its screen properties.
3.  **Negotiation**: Host validates dimensions and sends `CONFIG`.
4.  **Verification**: Host sends `PING`, waits for `PONG`.
5.  **Streaming**: Host sends `CODEC_CONFIG` followed by `VIDEO` frames.

### 3.2 Reliability
*   **Heartbeat**: Host sends `PING` every 2 seconds. If no `PONG` within 3 seconds, the session is considered lost.
*   **Re-sync**: If the Android app returns from the background, it sends a new `HELLO`. The host restarts the encoder to provide fresh parameter sets.
*   **Keyframe Recovery**: If the Android decoder stalls, it sends `KEYFRAME_REQUEST` to prompt an immediate IDR frame.
