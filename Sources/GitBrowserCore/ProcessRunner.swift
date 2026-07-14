import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var stderrText: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

/// Runs an executable with an explicit URL and argument array. No shell is
/// involved anywhere, so arguments are never concatenated or re-parsed.
public enum ProcessRunner {
    public static func run(executable: URL, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // Never inherit a terminal: gh must not page or prompt.
            process.standardInput = FileHandle.nullDevice

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let state = OutputState()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    state.appendStdout(chunk)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    state.appendStderr(chunk)
                }
            }

            process.terminationHandler = { proc in
                // Drain anything the readability handlers have not seen yet.
                let remainingOut = try? stdoutPipe.fileHandleForReading.readToEnd()
                let remainingErr = try? stderrPipe.fileHandleForReading.readToEnd()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let (out, err) = state.finish(
                    trailingStdout: remainingOut ?? Data(),
                    trailingStderr: remainingErr ?? Data()
                )
                continuation.resume(returning: ProcessResult(
                    status: proc.terminationStatus, stdout: out, stderr: err
                ))
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private final class OutputState: @unchecked Sendable {
        private var stdout = Data()
        private var stderr = Data()
        private let lock = NSLock()

        func appendStdout(_ d: Data) {
            lock.lock(); stdout.append(d); lock.unlock()
        }

        func appendStderr(_ d: Data) {
            lock.lock(); stderr.append(d); lock.unlock()
        }

        func finish(trailingStdout: Data, trailingStderr: Data) -> (Data, Data) {
            lock.lock(); defer { lock.unlock() }
            stdout.append(trailingStdout)
            stderr.append(trailingStderr)
            return (stdout, stderr)
        }
    }
}
