import AppKit
import CoreMedia
import CoreVideo
import QuartzCore
import ScreenCaptureKit

// Initialize AppKit / CoreGraphics connection
_ = NSApplication.shared

// MARK: - Benchmark Metrics Container

struct WindowMetrics: Sendable {
    let windowID: CGWindowID
    let appName: String
    let title: String
    let frame: CGRect
    var startupLatencyMs: Double = 0.0
    var frameArrivalTimes: [Double] = []
    var presentationLatenciesMs: [Double] = []
    var totalFrames: Int = 0
    var completeFrames: Int = 0
    var droppedFrames: Int = 0
}

// MARK: - Stream Proxy

final class StreamProxy: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let windowID: CGWindowID
    let appName: String
    let title: String
    let frame: CGRect
    let layer: CALayer

    private(set) var stream: SCStream?
    private let startTime: Double
    private var firstFrameReceived = false
    private let lock = NSLock()

    var startupLatencyMs: Double = 0.0
    var frameArrivalTimes: [Double] = []
    var presentationLatenciesMs: [Double] = []
    var totalFrames: Int = 0
    var completeFrames: Int = 0
    var droppedFrames: Int = 0

    init(windowID: CGWindowID, appName: String, title: String, frame: CGRect) {
        self.windowID = windowID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.startTime = CACurrentMediaTime()

        self.layer = CALayer()
        self.layer.frame = frame
        self.layer.borderColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
        self.layer.borderWidth = 2.0
        self.layer.cornerRadius = 8.0
        self.layer.masksToBounds = true
        self.layer.contentsGravity = .resizeAspectFill
        super.init()
    }

    func attachStream(_ stream: SCStream) {
        self.stream = stream
    }

    // MARK: - SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let now = CACurrentMediaTime()

        // Extract frame status from attachments
        var isComplete = true
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let firstAttachment = attachmentsArray.first,
           let statusRaw = firstAttachment[SCStreamFrameInfo.status.rawValue as CFString] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw) {
            isComplete = (status == .complete)
            if status != .complete {
                lock.lock()
                droppedFrames += 1
                lock.unlock()
            }
        }

        // Measure PTS latency
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var ptsLatencyMs: Double = 0.0
        if pts.isValid && pts.timescale > 0 {
            let ptsSec = pts.seconds
            let delta = now - ptsSec
            if delta > 0 && delta < 10.0 {
                ptsLatencyMs = delta * 1000.0
            }
        }

        lock.lock()
        if !firstFrameReceived {
            firstFrameReceived = true
            startupLatencyMs = (now - startTime) * 1000.0
        }
        totalFrames += 1
        if isComplete { completeFrames += 1 }
        frameArrivalTimes.append(now)
        if ptsLatencyMs > 0 {
            presentationLatenciesMs.append(ptsLatencyMs)
        }
        lock.unlock()

        // Zero-copy layer content update
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.layer.contents = pixelBuffer
                CATransaction.commit()
            }
        }
    }

    func snapshotMetrics() -> WindowMetrics {
        lock.lock()
        defer { lock.unlock() }
        var m = WindowMetrics(
            windowID: windowID,
            appName: appName,
            title: title,
            frame: frame
        )
        m.startupLatencyMs = startupLatencyMs
        m.frameArrivalTimes = frameArrivalTimes
        m.presentationLatenciesMs = presentationLatenciesMs
        m.totalFrames = totalFrames
        m.completeFrames = completeFrames
        m.droppedFrames = droppedFrames
        return m
    }
}

// MARK: - S1 Benchmark Runner

@MainActor
final class S1BenchmarkRunner {
    private var syntheticWindows: [NSWindow] = []
    private var overlayWindow: NSWindow?
    private var proxies: [StreamProxy] = []
    private let targetWindowCount: Int
    private let testDurationSec: Double

    init(targetWindowCount: Int = 5, testDurationSec: Double = 3.0) {
        self.targetWindowCount = targetWindowCount
        self.testDurationSec = testDurationSec
    }

    func run() async throws {
        print("\n==================================================================")
        print("  SHUTTLE SPIKE S1: ScreenCaptureKit Live Proxy Streaming")
        print("==================================================================")
        print("Target Concurrent Windows: \(targetWindowCount)")
        print("Movement Animation Duration: \(String(format: "%.1f", testDurationSec))s")
        print("Querying system on-screen windows...\n")

        // 1. Query real windows
        let initialContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        var candidateWindows = initialContent.windows.filter { win in
            guard let app = win.owningApplication?.applicationName else { return false }
            let systemApps = ["WindowManager", "Wallpaper", "Dock", "Window Server", "SystemUIServer", "Notification Center", "Control Center"]
            return !systemApps.contains(app) && win.frame.width >= 150 && win.frame.height >= 150 && win.windowLayer == 0
        }

        print("Discovered \(candidateWindows.count) eligible real application windows:")
        for w in candidateWindows {
            print("  • [\(w.windowID)] \(w.owningApplication?.applicationName ?? "Unknown"): \"\(w.title ?? "")\" \(Int(w.frame.width))x\(Int(w.frame.height)) at (\(Int(w.frame.origin.x)), \(Int(w.frame.origin.y)))")
        }

        // 2. Synthesize test windows if fewer than targetWindowCount
        let neededSynthetic = max(0, targetWindowCount - candidateWindows.count)
        if neededSynthetic > 0 {
            print("\nSpawning \(neededSynthetic) synthetic test windows to reach target workload of \(targetWindowCount) windows...")
            let colors: [NSColor] = [.systemPurple, .systemTeal, .systemOrange, .systemGreen, .systemPink]
            for i in 0..<neededSynthetic {
                let rect = NSRect(x: 100 + i * 180, y: 150 + i * 120, width: 640, height: 440)
                let win = NSWindow(
                    contentRect: rect,
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                win.title = "Shuttle Target #\(candidateWindows.count + i + 1)"
                win.backgroundColor = colors[i % colors.count]
                win.isReleasedWhenClosed = false

                // Add active content view to simulate application rendering
                let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 440))
                view.wantsLayer = true
                let label = NSTextField(labelWithString: "Shuttle Benchmark Synthetic Target #\(i + 1)\nActive Window Proxy Rendering")
                label.font = NSFont.systemFont(ofSize: 20, weight: .bold)
                label.textColor = .white
                label.frame = NSRect(x: 40, y: 180, width: 560, height: 80)
                view.addSubview(label)
                win.contentView = view

                win.orderFront(nil)
                syntheticWindows.append(win)
            }

            try await Task.sleep(nanoseconds: 200_000_000)

            let updatedContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            for sw in syntheticWindows {
                if let match = updatedContent.windows.first(where: { $0.windowID == sw.windowNumber }) {
                    candidateWindows.append(match)
                }
            }
        }

        let selectedWindows = Array(candidateWindows.prefix(targetWindowCount))
        guard !selectedWindows.isEmpty else {
            print("ERROR: No windows available for streaming.")
            return
        }

        print("\nStreaming \(selectedWindows.count) windows concurrently:")
        for (idx, w) in selectedWindows.enumerated() {
            print("  [\(idx + 1)] ID \(w.windowID) | \(w.owningApplication?.applicationName ?? "Synthetic") | \(Int(w.frame.width))x\(Int(w.frame.height))")
        }

        // 3. Setup Overlay Window
        let mainScreen = NSScreen.main ?? NSScreen.screens[0]
        let overlay = NSWindow(
            contentRect: mainScreen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.level = .floating
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let rootLayer = CALayer()
        rootLayer.frame = NSRect(origin: .zero, size: mainScreen.frame.size)
        overlay.contentView?.wantsLayer = true
        overlay.contentView?.layer = rootLayer
        overlay.orderFront(nil)
        self.overlayWindow = overlay

        // 4. Initialize Stream Proxies & Configure SCStreams
        print("\nConfiguring ScreenCaptureKit streams (120Hz cap, BGRA, queue depth 3)...")

        for win in selectedWindows {
            let proxy = StreamProxy(
                windowID: win.windowID,
                appName: win.owningApplication?.applicationName ?? "Synthetic",
                title: win.title ?? "",
                frame: win.frame
            )
            rootLayer.addSublayer(proxy.layer)

            let filter = SCContentFilter(desktopIndependentWindow: win)
            let config = SCStreamConfiguration()
            config.width = max(100, Int(win.frame.width))
            config.height = max(100, Int(win.frame.height))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120) // 120Hz ProMotion request
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 3
            config.showsCursor = false

            let stream = SCStream(filter: filter, configuration: config, delegate: proxy)
            let queue = DispatchQueue(label: "shuttle.sck.stream.\(win.windowID)", qos: .userInteractive)
            try stream.addStreamOutput(proxy, type: .screen, sampleHandlerQueue: queue)
            proxy.attachStream(stream)
            proxies.append(proxy)
        }

        // 5. Start Captures Concurrently
        print("Starting \(proxies.count) streams in parallel...")
        let startCaptureT0 = CACurrentMediaTime()
        let activeProxies = self.proxies
        try await withThrowingTaskGroup(of: Void.self) { group in
            for proxy in activeProxies {
                guard let stream = proxy.stream else { continue }
                group.addTask {
                    try await stream.startCapture()
                }
            }
            try await group.waitForAll()
        }
        let startCaptureDurationMs = (CACurrentMediaTime() - startCaptureT0) * 1000.0
        print("All streams started capture in \(String(format: "%.2f", startCaptureDurationMs)) ms")

        // 6. Simulate Horizontal Ribbon Movement Animation (120Hz display loop)
        print("\nSimulating rapid ribbon scroll animation over \(testDurationSec)s...")
        let animationStart = CACurrentMediaTime()
        let initialPositions = proxies.map { $0.layer.position }
        let totalTravelPoints: CGFloat = 800.0 // 800pt horizontal flick & rebound

        let frameInterval = 1.0 / 120.0
        var simElapsed: Double = 0.0

        while simElapsed < testDurationSec {
            let now = CACurrentMediaTime()
            simElapsed = now - animationStart
            let progress = min(1.0, simElapsed / testDurationSec)

            // Sinusoidal ribbon motion curve: flick to right then rebound
            let offset = sin(progress * .pi) * totalTravelPoints

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, proxy) in proxies.enumerated() {
                let initPos = initialPositions[i]
                proxy.layer.position = CGPoint(x: initPos.x + offset, y: initPos.y)
            }
            CATransaction.commit()

            try await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
        }

        print("Ribbon movement complete. Commencing teardown handoff to real windows...")

        // 7. Measure Teardown Handoff Latency
        let handoffStart = CACurrentMediaTime()

        // Stop all streams in parallel
        await withTaskGroup(of: Void.self) { group in
            for proxy in activeProxies {
                guard let stream = proxy.stream else { continue }
                group.addTask {
                    do {
                        try await stream.stopCapture()
                    } catch {
                        print("Error stopping stream: \(error)")
                    }
                }
            }
            await group.waitForAll()
        }

        // Hide overlay and flush CATransaction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        overlay.orderOut(nil)

        let handoffEnd = CACurrentMediaTime()
        let teardownLatencyMs = (handoffEnd - handoffStart) * 1000.0
        print("Teardown handoff finished in \(String(format: "%.2f", teardownLatencyMs)) ms")

        // 8. Collect Metrics & Print Report
        printBenchmarkReport(
            proxies: proxies,
            testDuration: testDurationSec,
            startCaptureMs: startCaptureDurationMs,
            teardownMs: teardownLatencyMs
        )

        // 9. Cleanup Synthetic Windows
        for win in syntheticWindows {
            win.close()
        }
    }

    private func printBenchmarkReport(
        proxies: [StreamProxy],
        testDuration: Double,
        startCaptureMs: Double,
        teardownMs: Double
    ) {
        let metricsList = proxies.map { $0.snapshotMetrics() }

        print("\n=========================================================================================")
        print("                          SHUTTLE SPIKE S1 BENCHMARK RESULTS                             ")
        print("=========================================================================================")
        print(String(format: "%-8@ | %-16@ | %-12@ | %-10@ | %-8@ | %-12@ | %-10@",
                     "WinID", "Application", "Resolution", "Startup", "Frames", "FPS", "Mean Jitter"))
        print("-----------------------------------------------------------------------------------------")

        var totalFrames = 0
        var startupLatencies: [Double] = []
        var allJitters: [Double] = []

        for m in metricsList {
            let resStr = "\(Int(m.frame.width))x\(Int(m.frame.height))"
            let fps = Double(m.totalFrames) / testDuration
            totalFrames += m.totalFrames
            if m.startupLatencyMs > 0 { startupLatencies.append(m.startupLatencyMs) }

            // Compute frame time intervals and jitter
            var jitters: [Double] = []
            if m.frameArrivalTimes.count > 1 {
                for i in 1..<m.frameArrivalTimes.count {
                    let dt = (m.frameArrivalTimes[i] - m.frameArrivalTimes[i - 1]) * 1000.0
                    jitters.append(dt)
                    allJitters.append(dt)
                }
            }

            let meanJitter = jitters.isEmpty ? 0.0 : (jitters.reduce(0, +) / Double(jitters.count))
            let appTrimmed = String(m.appName.prefix(15))

            print(String(
                format: "%-8d | %-16@ | %-12@ | %7.1f ms | %8d | %10.1f | %7.2f ms",
                m.windowID,
                appTrimmed,
                resStr,
                m.startupLatencyMs,
                m.totalFrames,
                fps,
                meanJitter
            ))
        }

        print("-----------------------------------------------------------------------------------------")
        let aggregateFPS = Double(totalFrames) / testDuration
        let avgStartup = startupLatencies.isEmpty ? 0.0 : (startupLatencies.reduce(0, +) / Double(startupLatencies.count))
        let minStartup = startupLatencies.min() ?? 0.0
        let maxStartup = startupLatencies.max() ?? 0.0

        // Jitter distribution percentiles
        allJitters.sort()
        let p50 = percentile(allJitters, p: 0.50)
        let p95 = percentile(allJitters, p: 0.95)
        let p99 = percentile(allJitters, p: 0.99)
        let stdDev = standardDeviation(allJitters)

        print("\n--- AGGREGATE PERFORMANCE SUMMARY ---")
        print(String(format: "• Total Windows Streamed:         %d", metricsList.count))
        print(String(format: "• Total Frames Rendered:          %d", totalFrames))
        print(String(format: "• Aggregate Throughput:           %.1f FPS", aggregateFPS))
        print(String(format: "• Parallel startCapture() Time:   %.2f ms", startCaptureMs))
        print(String(format: "• First Frame Startup Latency:    min: %.1f ms | avg: %.1f ms | max: %.1f ms", minStartup, avgStartup, maxStartup))
        print(String(format: "• Inter-frame Interval (Jitter):  p50: %.2f ms | p95: %.2f ms | p99: %.2f ms | σ: %.2f ms", p50, p95, p99, stdDev))
        print(String(format: "• Teardown Handoff Latency:       %.2f ms", teardownMs))

        print("\n--- ARCHITECTURAL FEASIBILITY ANALYSIS FOR SHUTTLE ---")
        let frameBudget120 = 1000.0 / 120.0 // 8.33 ms
        let frameBudget60 = 1000.0 / 60.0   // 16.67 ms

        if avgStartup > frameBudget120 {
            print(String(format: "⚠️  [STARTUP LATENCY]: First frame delivery took avg %.1f ms (> 120Hz budget %.2f ms).", avgStartup, frameBudget120))
            print("   SCK cannot be started on-demand at gesture touchdown without introducing a perceptible initial hitch.")
            print("   -> Mitigation: Streams must either be pre-warmed, or initial gesture frames must use static window snapshots (CGWindowListCreateImage / CGS) before SCK cuts in.")
        } else {
            print("✅ [STARTUP LATENCY]: Immediate frame delivery under 8.33ms budget.")
        }

        if teardownMs <= frameBudget60 {
            print(String(format: "✅ [TEARDOWN HANDOFF]: Teardown completed in %.2f ms (within 60Hz display frame budget of %.1f ms).", teardownMs, frameBudget60))
        } else {
            print(String(format: "⚠️  [TEARDOWN HANDOFF]: Teardown took %.2f ms (> 60Hz budget %.1f ms).", teardownMs, frameBudget60))
            print("   -> Asynchronous background teardown required so real window unhide occurs instantly without waiting for SCStream.stopCapture().")
        }

        if p95 <= 20.0 {
            print(String(format: "✅ [FRAME PACING]: 95%% of frames arrived within %.2f ms, delivering smooth motion.", p95))
        } else {
            print(String(format: "⚠️  [FRAME PACING]: Frame pacing jitter p95 is %.2f ms.", p95))
        }
        print("=========================================================================================\n")
    }

    private func percentile(_ sortedArray: [Double], p: Double) -> Double {
        guard !sortedArray.isEmpty else { return 0.0 }
        let idx = Int(Double(sortedArray.count - 1) * p)
        return sortedArray[idx]
    }

    private func standardDeviation(_ array: [Double]) -> Double {
        guard array.count > 1 else { return 0.0 }
        let mean = array.reduce(0, +) / Double(array.count)
        let sumSquares = array.reduce(0) { $0 + pow($1 - mean, 2) }
        return sqrt(sumSquares / Double(array.count - 1))
    }
}

// MARK: - Entry Point

Task { @MainActor in
    do {
        let runner = S1BenchmarkRunner(targetWindowCount: 5, testDurationSec: 3.0)
        try await runner.run()
        exit(0)
    } catch {
        print("FATAL: Benchmark failed with error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
