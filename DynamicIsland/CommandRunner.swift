import Foundation

/// Runs command-line tools (system_profiler, shortcuts) on a background queue, like AppleScriptRunner:
/// they can take a few seconds, which would freeze the island on the main thread.
nonisolated enum CommandRunner {
    private static let queue = DispatchQueue(label: "CommandRunner", attributes: .concurrent)

    /// The tool's output, or nil if it couldn't start or failed. With a `timeout`, a tool still
    /// running after that many seconds is stopped.
    @discardableResult
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval? = nil) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                // Nothing is typed in, so a tool (or a shell's startup files) can't wait for input.
                process.standardInput = FileHandle.nullDevice
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let watchdog = DispatchWorkItem { [weak process] in
                    if process?.isRunning == true {
                        process?.terminate()
                    }
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                }
                // Read before waiting: a full pipe would block the tool from exiting.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }

    /// Like `run`, with `secret` typed in at the tool's password prompt. Such prompts read from a
    /// terminal with echo off, so the tool gets a pseudo-terminal as its input; the secret stays
    /// out of the arguments, which any process can read (`ps`) and security tools log.
    /// A tool still waiting for input after `timeout` seconds is stopped.
    @discardableResult
    static func run(_ path: String, _ arguments: [String], typing secret: String, timeout: TimeInterval = 45) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                var primary: Int32 = -1
                var secondary: Int32 = -1
                guard openpty(&primary, &secondary, nil, nil, nil) == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let terminal = FileHandle(fileDescriptor: primary, closeOnDealloc: true)
                let input = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)
                // Echo off from the start, so the secret is never echoed back, not even here.
                var settings = termios()
                if tcgetattr(secondary, &settings) == 0 {
                    settings.c_lflag &= ~tcflag_t(ECHO)
                    tcsetattr(secondary, TCSANOW, &settings)
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardInput = input
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                // The tool has its own copy; the line waits in the terminal until it reads it.
                try? input.close()
                terminal.write(Data((secret + "\n").utf8))

                // A tool asking for more than the one line would wait forever.
                let watchdog = DispatchWorkItem { [weak process] in
                    if process?.isRunning == true {
                        process?.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                try? terminal.close()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}

/// Settings kept as variables in the user's zsh config, like `JIRA_API_TOKEN=…` in `~/.zshrc`.
/// They needn't be exported, which keeps them out of the environment of every program started
/// from a terminal. launchd opens the app and reads no zsh config, so a login, interactive zsh is
/// asked for them; it prints each value between markers, so whatever its startup files print is
/// left out, and no value is ever in a command line.
nonisolated enum ShellConfig {
    /// The variables that are set and not empty, by name. The app's own environment (when it was
    /// opened from a terminal) comes first.
    static func values(_ names: [String]) async -> [String: String] {
        var values: [String: String] = [:]
        let environment = ProcessInfo.processInfo.environment
        for name in names {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                values[name] = value
            }
        }
        let missing = names.filter { values[$0] == nil && $0.wholeMatch(of: /[A-Z_][A-Z0-9_]*/) != nil }
        guard !missing.isEmpty else { return values }

        let script = missing.map { "print -rn -- '<\($0)>'\"${\($0)}\"'</\($0)>'" }.joined(separator: "; ")
        guard let data = await CommandRunner.run("/bin/zsh", ["-l", "-i", "-c", script], timeout: 15),
              let output = String(data: data, encoding: .utf8) else { return values }
        for name in missing {
            guard let opening = output.range(of: "<\(name)>"),
                  let closing = output.range(of: "</\(name)>", range: opening.upperBound..<output.endIndex) else { continue }
            let value = output[opening.upperBound..<closing.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                values[name] = value
            }
        }
        return values
    }
}
