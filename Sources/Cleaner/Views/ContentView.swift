import CleanCore
import SwiftUI

enum Destination: Hashable {
    case overview
    case category(CleanCategory)
    case history
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var destination: Destination? = .overview

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $destination) {
                Label("概览", systemImage: "internaldrive")
                    .tag(Destination.overview)

                Section("分类") {
                    ForEach(CleanCategory.allCases) { category in
                        SidebarCategoryRow(category: category)
                            .tag(Destination.category(category))
                    }
                }

                Section {
                    Label("清理记录", systemImage: "clock.arrow.circlepath")
                        .tag(Destination.history)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch destination ?? .overview {
                case .overview:
                    OverviewView(destination: $destination)
                case .category(let category):
                    CategoryView(category: category)
                case .history:
                    HistoryView()
                }
            }
            .frame(minWidth: 560)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.phase == .scanning {
                    Button("停止", systemImage: "stop.circle") { model.cancelScan() }
                } else {
                    Button(model.lastScanDate == nil ? "扫描" : "重新扫描", systemImage: "arrow.clockwise") {
                        model.startScan()
                    }
                    .disabled(model.phase == .cleaning)
                }
            }
        }
        // 清理进行中和清理结果用同一个 sheet，避免两个 sheet 交替时丢失弹窗
        .sheet(isPresented: Binding(
            get: { model.phase == .cleaning || model.lastReport != nil },
            set: { if !$0 { model.lastReport = nil } }
        )) {
            if let report = model.lastReport {
                CleanResultView(report: report.value)
            } else {
                CleaningProgressView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
            model.refreshDisk()
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugNavigate)) { note in
            if let target = note.object as? Destination { destination = target }
        }
        .task { await DebugSnapshot.run(model: model) }
    }
}

struct SidebarCategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: CleanCategory

    var body: some View {
        HStack {
            Label(category.title, systemImage: category.symbol)
            Spacer()
            if model.lastScanDate != nil {
                let size = model.totalSize(in: category)
                Text(size > 0 ? size.bytes : "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
