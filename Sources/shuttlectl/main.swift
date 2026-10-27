import Foundation
import Darwin
import ShuttleCore
import WeftIPC

let user = ProcessInfo.processInfo.environment["USER"] ?? "user"
let socketPath = "/tmp/shuttle-\(user).sock"

let args = CommandLine.arguments.dropFirst()
guard let _ = args.first else {
    print("""
    shuttlectl (v\(ShuttleVersion.full)) - Control client for Shuttle window manager

    USAGE:
      shuttlectl <command>

    HORIZONTAL COLUMN COMMANDS:
      focus-left         Focus column to the left
      focus-right        Focus column to the right
      move-left          Move focused column to the left
      move-right         Move focused column to the right
      preset             Cycle column width preset (1/3 -> 1/2 -> 2/3 -> 1.0)
      maximize           Toggle full viewport width for focused column
      expand             Expand width of focused column (+10%)
      shrink             Shrink width of focused column (-10%)
      center             Snap ribbon to center focused column

    VERTICAL STACK COMMANDS:
      focus-up           Focus window above in current column stack
      focus-down         Focus window below in current column stack
      move-up            Move focused window up in current column stack
      move-down          Move focused window down in current column stack
      split              Split focused window out into its own new column
      consume-left       Consume left column into current column stack
      consume-right      Consume right column into current column stack

    GESTURE & PHYSICS COMMANDS:
      pan <delta>        Pan ribbon by delta points (interactive trackpad / drag)
      fling <vel>        Fling ribbon with initial velocity in pt/s
      snap               Snap ribbon to nearest column

    SPACE (DESKTOP) COMMANDS:
      space focus <N>    Switch to macOS Space N (1..9) via synthetic Dock swipe
      space move <N>     Move focused window to macOS Space N (1..9)

    DAEMON & STATUS:
      status             Query active space, columns, focused window, and scroller status
      stop               Gracefully shut down the running shuttled daemon
    """)
    exit(0)
}

let command = args.joined(separator: " ")

// Connect to Unix domain socket
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
    print("❌ Error creating socket.")
    exit(1)
}
defer { close(fd) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
_ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
    ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dest in
        strncpy(dest, socketPath, maxLen - 1)
    }
}

let connectResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}

guard connectResult == 0 else {
    print("❌ Failed to connect to shuttled at \(socketPath). Is shuttled running?")
    exit(1)
}

// Send command line
let cmdWithNewline = command + "\n"
_ = cmdWithNewline.withCString { ptr in
    write(fd, ptr, strlen(ptr))
}

// Read response
var buffer = [CChar](repeating: 0, count: 4096)
let bytesRead = read(fd, &buffer, buffer.count - 1)
guard bytesRead > 0 else {
    print("❌ No response received from shuttled.")
    exit(1)
}

buffer[bytesRead] = 0
let responseString = String(decoding: buffer[0..<bytesRead].map { UInt8(bitPattern: $0) }, as: UTF8.self)

// Attempt JSON decoding of IPCResponse
if let data = responseString.data(using: .utf8),
   let resp = try? JSONDecoder().decode(IPCResponse.self, from: data) {
    if let out = resp.output {
        print(out)
    } else if let err = resp.error {
        print("❌ Error: \(err)")
    }
} else {
    print(responseString.trimmingCharacters(in: .whitespacesAndNewlines))
}
