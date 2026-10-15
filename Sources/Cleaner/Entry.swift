import Foundation

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--metrics") {
            Task {
                await HeadlessMetrics.run()
                exit(0)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--scan") {
            // 无界面模式：扫描并打印结果，不删除任何文件
            Task { @MainActor in
                await HeadlessScan.run()
                exit(0)
            }
            dispatchMain()
        }
        MainActor.assumeIsolated { CleanerApp.main() }
    }
}
