import Foundation

/// Runs command-line tools (system_profiler, shortcuts) on a background queue, like AppleScriptRunner:
/// they can take a few seconds, which would freeze the island on the main thread.
nonisolated enum CommandRunner {
    private static let queue = DispatchQueue(label: "CommandRunner", attributes: .concurrent)

    /// The tool's output, or nil if it couldn't start or failed.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                // Read before waiting: a full pipe would block the tool from exiting.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
