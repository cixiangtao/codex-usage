import Darwin
import Foundation

struct StatusBarAnimationTiming {
    static let minimumInterval: TimeInterval = 0.05

    static func speedMultiplier(forCPUUsage usage: Double) -> Double {
        let boundedUsage = min(max(usage, 0), 1)
        return 0.6 + boundedUsage * 1.2
    }

    static func interval(
        baseDuration: TimeInterval,
        speedMultiplier: Double,
        followsCPU: Bool
    ) -> TimeInterval {
        guard followsCPU else { return baseDuration }
        return max(baseDuration / max(speedMultiplier, 0.1), minimumInterval)
    }
}

@MainActor
final class SystemCPUUsageMonitor {
    private static let samplingInterval: TimeInterval = 3
    private static let smoothingFactor = 0.3

    private var timer: Timer?
    private var samplingTask: Task<Void, Never>?
    private var previousTicks: CPUTicks?
    private var smoothedUsage: Double?
    private var onUpdate: ((Double) -> Void)?

    func start(onUpdate: @escaping (Double) -> Void) {
        self.onUpdate = onUpdate
        guard timer == nil else { return }

        requestSample()

        let timer = Timer(
            timeInterval: Self.samplingInterval,
            target: self,
            selector: #selector(requestSample),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        samplingTask?.cancel()
        samplingTask = nil
        onUpdate = nil
    }

    @objc
    private func requestSample() {
        guard samplingTask == nil else { return }

        samplingTask = Task { [weak self] in
            let currentTicks = await Task.detached(priority: .utility) {
                Self.readTicks()
            }.value
            guard !Task.isCancelled, let self else { return }

            samplingTask = nil
            guard let currentTicks else { return }
            consume(currentTicks)
        }
    }

    private func consume(_ currentTicks: CPUTicks) {
        defer { previousTicks = currentTicks }
        guard let previousTicks else { return }

        let busyDelta = currentTicks.busy.delta(since: previousTicks.busy)
        let totalDelta = currentTicks.total.delta(since: previousTicks.total)
        guard totalDelta > 0 else { return }

        let usage = min(max(Double(busyDelta) / Double(totalDelta), 0), 1)
        let smoothed = smoothedUsage.map {
            $0 + Self.smoothingFactor * (usage - $0)
        } ?? usage
        smoothedUsage = smoothed
        onUpdate?(smoothed)
    }

    nonisolated private static func readTicks() -> CPUTicks? {
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let hostPort = mach_host_self()
        defer {
            mach_port_deallocate(mach_task_self_, hostPort)
        }

        let result = host_processor_info(
            hostPort,
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &cpuInfoCount
        )
        guard result == KERN_SUCCESS, let cpuInfo else { return nil }
        defer {
            let byteCount = MemoryLayout<integer_t>.stride * Int(cpuInfoCount)
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: cpuInfo),
                vm_size_t(byteCount)
            )
        }

        var busy: UInt64 = 0
        var total: UInt64 = 0

        for cpuIndex in 0..<Int(cpuCount) {
            let offset = Int(CPU_STATE_MAX) * cpuIndex
            let user = unsignedTick(cpuInfo[offset + Int(CPU_STATE_USER)])
            let system = unsignedTick(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
            let nice = unsignedTick(cpuInfo[offset + Int(CPU_STATE_NICE)])
            let idle = unsignedTick(cpuInfo[offset + Int(CPU_STATE_IDLE)])

            busy += user + system + nice
            total += user + system + nice + idle
        }

        return CPUTicks(busy: busy, total: total)
    }

    nonisolated private static func unsignedTick(_ value: integer_t) -> UInt64 {
        UInt64(UInt32(bitPattern: value))
    }
}

private struct CPUTicks: Sendable {
    let busy: UInt64
    let total: UInt64
}

private extension UInt64 {
    func delta(since previous: UInt64) -> UInt64 {
        guard self >= previous else { return 0 }
        return self - previous
    }
}
