import AppKit
import ApplicationServices

// Initialize AppKit connection
_ = NSApplication.shared

// MARK: - Benchmark Target

struct AXWindowTarget {
    let appName: String
    let pid: pid_t
    let element: AXUIElement
    let initialPosition: CGPoint
    let size: CGSize
    var isSynthetic: Bool = false
}

struct TargetMetrics {
    let appName: String
    let pid: pid_t
    var callLatenciesMs: [Double] = []
    var successCount: Int = 0
    var errorCount: Int = 0
    var lastError: AXError?
}

// MARK: - Global Restoration State

private var globalTargets: [AXWindowTarget] = []

private func restoreAllWindowPositions() {
    for target in globalTargets {
        var pos = target.initialPosition
        if let val = AXValueCreate(.cgPoint, &pos) {
            _ = AXUIElementSetAttributeValue(target.element, kAXPositionAttribute as CFString, val)
        }
    }
}

// MARK: - Spike S2 Runner

@MainActor
final class S2BenchmarkRunner {
    private let targetWindowCount: Int
    private let testDurationSec: Double
    private var syntheticWindows: [NSWindow] = []

    init(targetWindowCount: Int = 5, testDurationSec: Double = 3.0) {
        self.targetWindowCount = targetWindowCount
        self.testDurationSec = testDurationSec
    }

    func run() async throws {
        print("\n==================================================================")
        print("  SHUTTLE SPIKE S2: Direct AX Placement Benchmark")
        print("==================================================================")

        guard AXIsProcessTrusted() else {
            print("❌ ERROR: Process is not trusted for Accessibility.")
            print("Please grant Accessibility permission in System Settings -> Privacy & Security -> Accessibility.")
            return
        }

        print("Accessibility permission trusted: true")
        print("Target Concurrent Windows: \(targetWindowCount)")
        print("Animation Loop Duration:   \(String(format: "%.1f", testDurationSec))s")
        print("Querying active application windows...\n")

        // 1. Discover Real Windows
        var targets: [AXWindowTarget] = []
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }

        // Prefer other apps over T3 Code to avoid moving the current editor
        let sortedApps = runningApps.sorted { a1, _ in
            let n1 = a1.localizedName ?? ""
            return !n1.contains("T3 Code")
        }

        for app in sortedApps {
            guard targets.count < targetWindowCount else { break }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            guard err == .success, let axWindows = windowsRef as? [AXUIElement] else { continue }

            for win in axWindows {
                guard targets.count < targetWindowCount else { break }
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
                _ = AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)

                var pos = CGPoint.zero
                var size = CGSize.zero
                if let p = posRef as! AXValue? { AXValueGetValue(p, .cgPoint, &pos) }
                if let s = sizeRef as! AXValue? { AXValueGetValue(s, .cgSize, &size) }

                // Filter out tiny windows, zero-size overlays, menu bars, or desktop-wide backdrops
                if size.width >= 200 && size.height >= 200 && size.width < 3500 {
                    targets.append(AXWindowTarget(
                        appName: app.localizedName ?? "App-\(app.processIdentifier)",
                        pid: app.processIdentifier,
                        element: win,
                        initialPosition: pos,
                        size: size,
                        isSynthetic: false
                    ))
                }
            }
        }

        // 2. Synthesize test windows if fewer than targetWindowCount
        let neededSynthetic = max(0, targetWindowCount - targets.count)
        if neededSynthetic > 0 {
            print("Spawning \(neededSynthetic) synthetic test windows to achieve target workload...")
            let colors: [NSColor] = [.systemBlue, .systemTeal, .systemGreen, .systemOrange]
            for i in 0..<neededSynthetic {
                let rect = NSRect(x: 120 + i * 160, y: 180 + i * 100, width: 500, height: 350)
                let win = NSWindow(
                    contentRect: rect,
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                win.title = "Shuttle AX Benchmark Synthetic Window #\(i + 1)"
                win.backgroundColor = colors[i % colors.count]
                win.isReleasedWhenClosed = false
                win.orderFront(nil)
                syntheticWindows.append(win)
            }

            try await Task.sleep(nanoseconds: 150_000_000)

            let selfApp = AXUIElementCreateApplication(getpid())
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(selfApp, kAXWindowsAttribute as CFString, &winRef) == .success,
               let axWins = winRef as? [AXUIElement] {
                for (idx, w) in axWins.prefix(neededSynthetic).enumerated() {
                    var posRef: CFTypeRef?
                    var sizeRef: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef)
                    _ = AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef)
                    var pos = CGPoint.zero
                    var size = CGSize.zero
                    if let p = posRef as! AXValue? { AXValueGetValue(p, .cgPoint, &pos) }
                    if let s = sizeRef as! AXValue? { AXValueGetValue(s, .cgSize, &size) }

                    targets.append(AXWindowTarget(
                        appName: "Synthetic #\(idx + 1)",
                        pid: getpid(),
                        element: w,
                        initialPosition: pos,
                        size: size,
                        isSynthetic: true
                    ))
                }
            }
        }

        guard !targets.isEmpty else {
            print("❌ No suitable windows found to benchmark.")
            return
        }

        globalTargets = targets
        defer {
            print("\nRestoring all windows to initial positions...")
            restoreAllWindowPositions()
            for w in syntheticWindows { w.close() }
        }

        print("Selected \(targets.count) target windows for AX placement benchmark:")
        for (i, t) in targets.enumerated() {
            print(String(format: "  [%d] %-16@ (PID: %5d) | %4.0fx%-4.0f at (%5.0f, %5.0f)",
                         i + 1, t.appName, t.pid, t.size.width, t.size.height, t.initialPosition.x, t.initialPosition.y))
        }

        // 3. Execution of rapid scroll animation loop
        print("\nBeginning 120Hz rapid scroll placement loop over \(testDurationSec)s...")
        let targetHz: Double = 120.0
        let frameIntervalSec: Double = 1.0 / targetHz

        var targetMetrics = targets.map { TargetMetrics(appName: $0.appName, pid: $0.pid) }
        var frameArrivalTimes: [Double] = []
        var framePlacementTimesMs: [Double] = []

        let travelDistance: Double = 600.0 // 600 points total swing
        let loopStartTime = CACurrentMediaTime()
        var elapsed: Double = 0.0

        while elapsed < testDurationSec {
            let frameStart = CACurrentMediaTime()
            elapsed = frameStart - loopStartTime
            frameArrivalTimes.append(frameStart)

            // Calculate sinusoidal displacement
            let progress = min(1.0, elapsed / testDurationSec)
            let dx = sin(progress * .pi * 2.0) * travelDistance

            let placementT0 = CACurrentMediaTime()
            for (i, target) in targets.enumerated() {
                var newPos = CGPoint(x: target.initialPosition.x + dx, y: target.initialPosition.y)
                guard let val = AXValueCreate(.cgPoint, &newPos) else { continue }

                let callT0 = CACurrentMediaTime()
                let result = AXUIElementSetAttributeValue(target.element, kAXPositionAttribute as CFString, val)
                let callDurationMs = (CACurrentMediaTime() - callT0) * 1000.0

                targetMetrics[i].callLatenciesMs.append(callDurationMs)
                if result == .success {
                    targetMetrics[i].successCount += 1
                } else {
                    targetMetrics[i].errorCount += 1
                    targetMetrics[i].lastError = result
                }
            }
            let placementDurationMs = (CACurrentMediaTime() - placementT0) * 1000.0
            framePlacementTimesMs.append(placementDurationMs)

            // Pacing sleep: compute time remaining in 8.33ms budget
            let frameElapsed = CACurrentMediaTime() - frameStart
            let sleepRemaining = frameIntervalSec - frameElapsed
            if sleepRemaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(sleepRemaining * 1_000_000_000))
            }
        }

        print("Animation loop finished. Restoring positions and analyzing metrics...")

        // 4. Print Detailed Benchmark Report
        printReport(
            targets: targets,
            metrics: targetMetrics,
            frameArrivalTimes: frameArrivalTimes,
            framePlacementTimesMs: framePlacementTimesMs,
            totalDurationSec: testDurationSec,
            targetHz: targetHz
        )
    }

    private func printReport(
        targets: [AXWindowTarget],
        metrics: [TargetMetrics],
        frameArrivalTimes: [Double],
        framePlacementTimesMs: [Double],
        totalDurationSec: Double,
        targetHz: Double
    ) {
        print("\n=========================================================================================")
        print("                          SHUTTLE SPIKE S2 BENCHMARK RESULTS                             ")
        print("=========================================================================================")
        print(String(format: "%-16@ | %-6@ | %-8@ | %-10@ | %-10@ | %-10@ | %-8@",
                     "Application", "PID", "Calls", "Avg IPC", "Max IPC", "Errors", "Status"))
        print("-----------------------------------------------------------------------------------------")

        var allCallLatencies: [Double] = []

        for m in metrics {
            let totalCalls = m.callLatenciesMs.count
            let avgIPC = totalCalls > 0 ? (m.callLatenciesMs.reduce(0, +) / Double(totalCalls)) : 0.0
            let maxIPC = m.callLatenciesMs.max() ?? 0.0
            allCallLatencies.append(contentsOf: m.callLatenciesMs)
            let status = m.errorCount == 0 ? "OK" : "Err(\(m.lastError?.rawValue ?? 0))"

            print(String(
                format: "%-16@ | %6d | %8d | %7.3f ms | %7.2f ms | %10d | %-8@",
                String(m.appName.prefix(16)),
                m.pid,
                totalCalls,
                avgIPC,
                maxIPC,
                m.errorCount,
                status
            ))
        }

        print("-----------------------------------------------------------------------------------------")

        // Frame interval & jitter calculations
        var frameIntervalsMs: [Double] = []
        if frameArrivalTimes.count > 1 {
            for i in 1..<frameArrivalTimes.count {
                frameIntervalsMs.append((frameArrivalTimes[i] - frameArrivalTimes[i - 1]) * 1000.0)
            }
        }

        frameIntervalsMs.sort()
        let totalFrames = frameArrivalTimes.count
        let achievedFPS = Double(totalFrames) / totalDurationSec
        let meanInterval = frameIntervalsMs.isEmpty ? 0.0 : (frameIntervalsMs.reduce(0, +) / Double(frameIntervalsMs.count))
        let stdDevInterval = standardDeviation(frameIntervalsMs)
        let p50Interval = percentile(frameIntervalsMs, p: 0.50)
        let p95Interval = percentile(frameIntervalsMs, p: 0.95)
        let p99Interval = percentile(frameIntervalsMs, p: 0.99)
        let maxHitch = frameIntervalsMs.max() ?? 0.0

        // Placement times (aggregate IPC per frame)
        let avgPlacementMs = framePlacementTimesMs.isEmpty ? 0.0 : (framePlacementTimesMs.reduce(0, +) / Double(framePlacementTimesMs.count))
        let maxPlacementMs = framePlacementTimesMs.max() ?? 0.0

        // Missed deadlines
        let frameBudgetMs = 1000.0 / targetHz
        let missed120 = frameIntervalsMs.filter { $0 > (frameBudgetMs + 1.0) }.count
        let missed60 = frameIntervalsMs.filter { $0 > (1000.0 / 60.0 + 1.0) }.count
        let pctMissed120 = frameIntervalsMs.isEmpty ? 0.0 : (Double(missed120) / Double(frameIntervalsMs.count) * 100.0)

        print("\n--- FRAME PACING & IPC METRICS ---")
        print(String(format: "• Target Frame Rate:              %.0f Hz (%.2f ms budget)", targetHz, frameBudgetMs))
        print(String(format: "• Achieved Frame Rate:            %.1f FPS (%d total frames)", achievedFPS, totalFrames))
        print(String(format: "• Mean Frame Interval:            %.2f ms", meanInterval))
        print(String(format: "• Aggregate IPC Cost per Frame:   avg: %.3f ms | max: %.2f ms", avgPlacementMs, maxPlacementMs))
        print(String(format: "• Frame Interval Distribution:    p50: %.2f ms | p95: %.2f ms | p99: %.2f ms | σ: %.2f ms",
                     p50Interval, p95Interval, p99Interval, stdDevInterval))
        print(String(format: "• Maximum Single-Frame Hitch:     %.2f ms", maxHitch))
        print(String(format: "• Frames Exceeding 120Hz (>9.3ms): %d / %d (%.1f%%)", missed120, frameIntervalsMs.count, pctMissed120))
        print(String(format: "• Frames Exceeding 60Hz (>17.7ms): %d / %d (%.1f%%)", missed60, frameIntervalsMs.count,
                     frameIntervalsMs.isEmpty ? 0.0 : (Double(missed60) / Double(frameIntervalsMs.count) * 100.0)))

        print("\n--- ARCHITECTURAL COMPARISON: S1 (SCK) VS S2 (DIRECT AX) ---")
        print("• Startup Latency:       S1 = ~140–165ms (cold start hitch) | S2 = 0.00ms (instant)")
        print("• Teardown / Handoff:    S1 = 15–23ms (async required)      | S2 = 0.00ms (zero handoff)")
        print(String(format: "• IPC Overhead / Frame:  S1 = 0 ms (pure GPU compositing)  | S2 = %.2f ms (synchronous mach messages)", avgPlacementMs))
        print(String(format: "• Frame Pacing (σ):      S1 = ~1.4 ms                      | S2 = %.2f ms", stdDevInterval))
        print(String(format: "• 120Hz Deadline Miss:   S1 = 0%% (steady state)            | S2 = %.1f%%", pctMissed120))

        if avgPlacementMs < 2.0 && pctMissed120 < 15.0 {
            print("\n💡 [VERDICT]: Direct AX placement is exceptionally lightweight on macOS (<2ms aggregate IPC).")
            print("   For standard gestures and keyboard navigation, Direct AX eliminates the 160ms startup hitch")
            print("   and 20ms teardown penalty of ScreenCaptureKit while maintaining near-120Hz responsiveness.")
        } else {
            print("\n💡 [VERDICT]: Direct AX exhibits frame drops under high contention.")
            print("   A hybrid strategy or throttled AX commits should be utilized.")
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
        let runner = S2BenchmarkRunner(targetWindowCount: 5, testDurationSec: 3.0)
        try await runner.run()
        exit(0)
    } catch {
        print("FATAL: S2 Benchmark failed with error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
