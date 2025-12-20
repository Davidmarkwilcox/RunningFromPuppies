// DebugLog.swift
// Debug
// Central debug logging (disabled by default).

import Foundation

enum DebugLog {
    //static var isEnabled: Bool = false
    static var isEnabled: Bool = true
    
    private static let lock = NSLock()
    private static var buffer: [String] = []
    private static let maxBufferLines: Int = 5_000
    
    static func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
    }

    @discardableResult
    static func flushToFile(filename: String = "RFP-DebugLog.txt") -> URL? {
        lock.lock()
        let lines = buffer
        lock.unlock()

        guard !lines.isEmpty else {
            print("[DEBUG] flushToFile(): buffer empty")
            return nil
        }

        let text = lines.joined(separator: "\n") + "\n"

        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let url = docs.appendingPathComponent(filename)

            try text.write(to: url, atomically: true, encoding: .utf8)
            print("[DEBUG] flushToFile(): wrote \(lines.count) line(s) to \(url.path)")
            return url
        } catch {
            print("[DEBUG] flushToFile(): failed: \(error)")
            return nil
        }
    }
    
    static func log(_ message: String) {
        guard isEnabled else { return }

        let line = "[DEBUG] \(message)"
        print(line)

        lock.lock(); defer { lock.unlock() }
        buffer.append(line)

        // Prevent runaway memory usage
        if buffer.count > maxBufferLines {
            buffer.removeFirst(buffer.count - maxBufferLines)
        }
    }
}

// End of DebugLog.swift
