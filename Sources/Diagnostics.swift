import Foundation
import Darwin

enum Diagnostics {
    static let url = URL(fileURLWithPath: "/tmp/PanelOff-\(getuid()).log")

    static func record(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) pid=\(getpid()) \(message)\n"
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN) }
        line.utf8CString.withUnsafeBytes { bytes in
            _ = write(descriptor, bytes.baseAddress, bytes.count - 1)
        }
    }
}
