import CleanCore
import Foundation
import Observation

/// 定时采集设备状态。只在有页面显示时运行（start/stop 成对调用）。
@MainActor
@Observable
final class SystemMonitor {
    static let historyLength = 60
    static let interval: Duration = .seconds(2)

    let machine = MachineInfo.current()
    private(set) var snapshot: SystemSnapshot?
    /// 最近 2 分钟的 CPU 占用（0...1）
    private(set) var cpuHistory: [Double] = []
    /// 最近 2 分钟的下载速度（字节/秒）
    private(set) var downloadHistory: [Double] = []

    @ObservationIgnored private let sampler = SystemSampler()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var users = 0

    func start() {
        users += 1
        guard task == nil else { return }
        task = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let sampler = self?.sampler else { return }
                let snapshot = await sampler.sample()
                guard let self, !Task.isCancelled else { return }
                self.record(snapshot)
                // CPU 和网速需要两次采样才能算出来，第一次后很快再采一次
                try? await Task.sleep(for: first ? .milliseconds(600) : Self.interval)
                first = false
            }
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        task?.cancel()
        task = nil
    }

    private func record(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        if let cpu = snapshot.cpu { Self.append(cpu.total, to: &cpuHistory) }
        if let network = snapshot.network { Self.append(network.download, to: &downloadHistory) }
    }

    private static func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }
}
