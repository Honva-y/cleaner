import CleanCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [Journal.Session] = []

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView("还没有清理记录", systemImage: "clock", description: Text("每次清理后，这里会记录释放了多少空间。"))
            } else {
                Table(sessions) {
                    TableColumn("时间") { session in
                        Text(session.date.formatted(date: .abbreviated, time: .shortened))
                    }
                    TableColumn("实际释放") { session in
                        Text(session.measuredFreedBytes.map { max($0, 0).bytes } ?? "—").monospacedDigit()
                    }
                    TableColumn("直接删除") { session in
                        Text(session.deletedBytes.bytes).monospacedDigit()
                    }
                    TableColumn("移到废纸篓") { session in
                        Text(session.trashedBytes.bytes).monospacedDigit()
                    }
                    TableColumn("项目") { session in
                        Text(session.failureCount > 0 ? "\(session.cleanedItems)（\(session.failureCount) 项失败）" : "\(session.cleanedItems)")
                    }
                }
            }
        }
        .navigationTitle("清理记录")
        .toolbar {
            ToolbarItem {
                Button("操作日志", systemImage: "doc.text.magnifyingglass") {
                    let log = Journal.shared.logURL
                    if FileManager.default.fileExists(atPath: log.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([log])
                    } else {
                        NSWorkspace.shared.open(log.deletingLastPathComponent().deletingLastPathComponent())
                    }
                }
                .help("在访达中显示每一步删除的详细日志")
            }
        }
        .onAppear { sessions = Journal.shared.history() }
        .onChange(of: model.lastReport?.id) { sessions = Journal.shared.history() }
    }
}
