import Foundation
import ApplicationServices

print("=== Spike S2: Direct AX Placement Benchmark ===")
let trusted = AXIsProcessTrusted()
print("Accessibility permission trusted: \(trusted)")
if !trusted {
    print("Please grant Accessibility permission in System Settings -> Privacy & Security -> Accessibility.")
}
print("Ready for AX frame placement latency measurements.")
