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
                // 数字列右对齐，方便上下比较
                Table(sessions) {
                    TableColumn("时间") { session in
                        Text(session.date.formatted(date: .abbreviated, time: .shortened))
                    }
                    .width(min: 140, ideal: 180)
                    TableColumn("实际释放") { session in
                        Text(session.measuredFreedBytes.map { max($0, 0).bytes } ?? "—").monospacedDigit()
                    }
                    .alignment(.trailing)
                    TableColumn("直接删除") { session in
                        Text(session.deletedBytes.bytes).monospacedDigit()
                    }
                    .alignment(.trailing)
                    TableColumn("移到废纸篓") { session in
                        Text(session.trashedBytes.bytes).monospacedDigit()
                    }
                    .alignment(.trailing)
                    TableColumn("项目") { session in
                        if session.failureCount > 0 {
                            Text("\(session.cleanedItems)（\(session.failureCount) 项失败）")
                                .foregroundStyle(.orange)
                        } else {
                            Text("\(session.cleanedItems)")
                        }
                    }
                    .alignment(.trailing)
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
