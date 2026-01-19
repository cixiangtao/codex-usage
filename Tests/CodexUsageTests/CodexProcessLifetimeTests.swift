import Foundation
import Testing
@testable import CodexUsage

@Suite("Codex process lifetime")
struct CodexProcessLifetimeTests {
    @Test("Explicit cancellation terminates the active process")
    func cancelTerminatesRegisteredProcess() throws {
        let controller = CodexProcessLifetimeController(
            pollInterval: 0.01,
            terminationGracePeriod: 0.2
        )
        let process = makeSleepProcess()

        try process.run()
        #expect(controller.register(process))

        controller.cancelAndTerminate()

        #expect(!process.isRunning)
        #expect(controller.isCancellationRequested)
    }

    @Test("A deadline terminates the active process")
    func timeoutTerminatesRegisteredProcess() throws {
        let controller = CodexProcessLifetimeController(
            pollInterval: 0.01,
            terminationGracePeriod: 0.2
        )
        let process = makeSleepProcess()

        try process.run()
        #expect(controller.register(process))

        do {
            try controller.waitForExit(of: process, timeout: 0.05)
            Issue.record("Expected the process wait to time out")
        } catch {
            #expect(error as? CodexProcessLifetimeError == .timedOut)
        }
        #expect(!process.isRunning)
    }

    @Test("Reset allows another process after cancellation")
    func resetAllowsAnotherProcessAfterCancellation() throws {
        let controller = CodexProcessLifetimeController(
            pollInterval: 0.01,
            terminationGracePeriod: 0.2
        )
        controller.cancelAndTerminate()

        let blockedProcess = makeSleepProcess()
        #expect(!controller.register(blockedProcess))

        controller.reset()
        let process = makeSleepProcess()
        try process.run()
        #expect(controller.register(process))

        controller.cancelAndTerminate()
        #expect(!process.isRunning)
    }

    private func makeSleepProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}
