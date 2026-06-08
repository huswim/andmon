# Architecture and Optimization

This document provides a high-level overview of the Andmon system architecture and the specific optimizations implemented to achieve low-latency, high-quality wired display streaming.

---

## 1. System Architecture

Andmon follows a classic Host-Receiver model, utilizing the Android Open Accessory (AOA) protocol for communication.

### 1.1 macOS Host Flow
1.  **USB Discovery**: Monitors for Android devices.
2.  **AOA Handshake**: Performs the AOA mode switch (Requests 51, 52, 53) to turn the tablet into a USB Accessory.
3.  **Virtual Display**: Creates a virtual monitor in macOS using `VirtualDisplayBridge`.
4.  **Capture**: Uses **ScreenCaptureKit** (`SCStream`) to capture frames from the virtual display at 60 FPS.
5.  **Encode**: Feeds captured frames into **VideoToolbox** (`VTCompressionSession`) for hardware-accelerated **HEVC (H.265)** encoding.
6.  **Transport**: Wraps encoded Annex B access units in the **Andmon Wire Protocol** and sends them via USB bulk OUT.

### 1.2 Android Receiver Flow
1.  **USB Accessory**: OS detects the accessory mode and launches the Andmon Receiver app.
2.  **Protocol Parsing**: Reconstructs complete frames from the USB bulk IN stream using a stateful `FrameParser`.
3.  **Decode**: Feeds H.265 bitstream into **MediaCodec** for hardware-accelerated decoding.
4.  **Render**: Decoded frames are rendered directly to a `SurfaceView` for display.

---

## 2. Performance Optimizations

Low latency (sub-50ms) is the primary goal of Andmon. Several optimizations are applied across the stack.

### 2.1 Video Pipeline (Latency & Quality)

*   **HEVC / H.265**: Used by default for its superior compression efficiency compared to H.264, allowing for high-quality video at lower USB bitrates.
*   **No B-Frames**: `kVTCompressionPropertyKey_AllowFrameReordering` is set to false. This eliminates the look-ahead delay required for bidirectional predictive frames.
*   **Low Latency Rate Control**: Enabled on the macOS encoder (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`) to prevent large bitrate spikes that could saturate the USB bus and cause jitter.
*   **Vendor-Specific Decoder Hints**: On Android, we search for `.low_latency` hardware decoders and apply vendor-specific keys (e.g., `vendor.qti-ext-dec-low-latency.enable`) to minimize buffering inside the hardware decoder.
*   **Real-time Thread Priorities**: Android read and decode threads are set to `THREAD_PRIORITY_URGENT_DISPLAY` and `THREAD_PRIORITY_VIDEO` to minimize scheduling jitter.

### 2.2 USB Transport Efficiency

*   **LibUSB Integration**: The macOS host uses `libusb` for direct, low-overhead bulk transfers, bypassing standard OS-level USB drivers.
*   **Selective Frame Dropping**: If the USB transport queue is backed up (e.g., due to temporary bus contention), the host will drop pending P-frames and wait for the next IDR frame or a keyframe request. This prevents "latency buildup" where the receiver falls behind the real-time stream.
*   **Large MTU**: The protocol handles splitting/merging at the USB level, allowing for large payloads (up to 8MiB) while keeping the header overhead minimal (24 bytes).

### 2.3 Reliability and Recovery

*   **Keyframe on Demand**: If the Android receiver detects a decode error or significant packet loss, it sends a `KEYFRAME_REQUEST`. The macOS host immediately forces an IDR frame to restore a clean stream.
*   **Drift Prevention**: The Android decoder monitors the time between "queued to decoder" and "ready to render". If a frame is delayed by more than 100ms, it is discarded to keep the display current.
*   **Heartbeat (Ping/Pong)**: A 2-second heartbeat ensures that if the cable is pulled or the app crashes, the host can immediately deactivate the virtual display and stop the encoder, saving CPU/battery.

### 2.4 Resource Management

*   **Zero-Copy Memory**: On macOS, we use `CMBlockBufferGetDataPointer` to access encoder output memory directly whenever possible, avoiding expensive `memcpy` operations before sending.
*   **ByteBuffer Reuse**: The Android `FrameParser` and `HevcSurfaceDecoder` use pre-allocated buffers to minimize Garbage Collection (GC) pressure during high-bandwidth streaming.
