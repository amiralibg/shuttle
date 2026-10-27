# Shuttle Spikes

Before building the full scroller daemon, these self-contained spikes benchmark and validate macOS interaction models:

## S1: ScreenCaptureKit Live Proxy Stream (`s1_screencapturekit_stream.swift`)
Tests streaming visible window frames using macOS 14+ `ScreenCaptureKit` into an overlay window during drag/scroll gestures.
- **Metric**: Frame latency, CPU/GPU utilization with 4–6 windows streaming concurrently.
- **Goal**: Verify if live SCK streaming produces 120Hz tear-free motion without AX frame thrashing.

## S2: Direct AX Placement Benchmark (`s2_ax_placement_jank.swift`)
Tests moving real macOS windows at display refresh rate using Accessibility API (`kAXPositionAttribute`).
- **Metric**: Frame-time distribution, missed display frames, AX server IPC saturation.
- **Goal**: Determine when direct AX is smooth enough and where it begins to stutter.

## S3: Trackpad Gesture Recognizer (`s3_trackpad_gesture.swift`)
Captures trackpad input via `CGEventTap`:
- Modifier + two-finger scroll with momentum phases (`kCGScrollWheelEventScrollPhaseBegan`, `Changed`, `Ended`).
- MultitouchSupport private framework listener for 3-finger horizontal gestures.

## S4: Mouse Wheel & Drag Physics (`s4_mouse_wheel_drag.swift`)
Validates modifier + mouse wheel and modifier + click-drag with spring snapping to column centers.

## Building & Running Spikes
```bash
./spikes/build.sh s1
./spikes/build.sh s2
./spikes/build.sh s3
./spikes/build.sh s4
```
