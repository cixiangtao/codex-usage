import Darwin
import Foundation

enum CodexProcessLifetimeError: Error, Equatable {
    case cancelled
    case timedOut
}

final class CodexProcessLifetimeController: @unchecked Sendable {
    private let lock = NSLock()
    private let pollInterval: TimeInterval
    private let terminationGracePeriod: TimeInterval
    private var activeProcess: Process?
    private var cancellationRequested = false

    init(
        pollInterval: TimeInterval = 0.1,
        terminationGracePeriod: TimeInterval = 0.5
    ) {
        self.pollInterval = max(0.01, pollInterval)
        self.terminationGracePeriod = max(0.05, terminationGracePeriod)
    }

    var isCancellationRequested: Bool {
        withLock { cancellationRequested }
    }

    func reset() {
        withLock {
            cancellationRequested = false
            if activeProcess?.isRunning != true {
                activeProcess = nil
            }
        }
    }

    @discardableResult
    func register(_ process: Process) -> Bool {
        let accepted = withLock {
            guard !cancellationRequested else { return false }
            activeProcess = process
            return true
        }

        if !accepted {
            terminate(process)
        }

        return accepted
    }

    func waitForExit(of process: Process, timeout: TimeInterval) throws {
        defer { clear(process) }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while process.isRunning {
            if isCancellationRequested {
                terminate(process)
                throw CodexProcessLifetimeError.cancelled
            }

            if Date() >= deadline {
                terminate(process)
                throw CodexProcessLifetimeError.timedOut
            }

            Thread.sleep(forTimeInterval: min(pollInterval, max(0.01, deadline.timeIntervalSinceNow)))
        }

        process.waitUntilExit()
        if isCancellationRequested {
            throw CodexProcessLifetimeError.cancelled
        }
    }

    func cancelAndTerminate() {
        let process = withLock {
            cancellationRequested = true
            return activeProcess
        }

        if let process {
            terminate(process)
        }
    }

    func clear(_ process: Process) {
        withLock {
            if activeProcess === process {
                activeProcess = nil
            }
        }
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }

        process.terminate()
        let gracefulDeadline = Date().addingTimeInterval(terminationGracePeriod)
        waitUntilStopped(process, deadline: gracefulDeadline)

        guard process.isRunning else { return }

        kill(process.processIdentifier, SIGKILL)
        let forcedDeadline = Date().addingTimeInterval(terminationGracePeriod)
        waitUntilStopped(process, deadline: forcedDeadline)
    }

    private func waitUntilStopped(_ process: Process, deadline: Date) {
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
