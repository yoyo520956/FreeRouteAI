import SwiftUI
import SwiftData

/// 请求日志：本地历史记录、筛选与检索
struct LogsView: View {
    @Environment(AppState.self) private var app

    private enum LogFilter: String, CaseIterable, Identifiable {
        case all, success, failed, switched
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "全部"
            case .success: return "成功"
            case .failed: return "失败"
            case .switched: return "已切换"
            }
        }
    }

    @State private var filter: LogFilter = .all
    @State private var search = ""
    @State private var expanded = Set<UUID>()
    @State private var showPruneConfirm = false
    @State private var pruneMessage: String?

    private var filtered: [DBRequestLog] {
        var list = app.recentLogs
        switch filter {
        case .all: break
        case .success: list = list.filter { $0.ok }
        case .failed: list = list.filter { !$0.ok }
        case .switched: list = list.filter { $0.switched }
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.modelID.localizedCaseInsensitiveContains(q)
                    || $0.providerName.localizedCaseInsensitiveContains(q)
            }
        }
        return list
    }

    var body: some View {
            ZStack {
                FRBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        statsBar
                        filterChips
                        if filtered.isEmpty {
                            FREmptyState(icon: "list.bullet.rectangle",
                                         title: search.isEmpty && filter == .all ? "暂无请求日志" : "没有匹配的日志",
                                         detail: search.isEmpty && filter == .all
                                            ? "完成一次请求后，记录会出现在这里"
                                            : "试试调整筛选条件或搜索词")
                                .padding(.vertical, 10)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(filtered) { log in
                                    logRow(log)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("请求日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPruneConfirm = true
                    } label: {
                        Label("按保留天数清理", systemImage: "trash")
                    }
                    .disabled(app.recentLogs.isEmpty)
                    .accessibilityLabel("清理过期日志")
                }
            }
            .searchable(text: $search, prompt: "搜索模型 / 服务商")
            .task {
                app.refreshLogs()
                app.statistics.reload()
            }
            .refreshable {
                app.refreshLogs()
                app.statistics.reload()
            }
            .confirmationDialog("清理请求日志", isPresented: $showPruneConfirm, titleVisibility: .visible) {
                Button("清理 \(app.settings.logRetentionDays) 天前的日志", role: .destructive) {
                    pruneLogs()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除 \(app.settings.logRetentionDays) 天前的日志，删除后不可恢复。")
            }
            .alert("清理完成", isPresented: Binding(get: { pruneMessage != nil }, set: { if !$0 { pruneMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(pruneMessage ?? "")
            }
    }

    // MARK: - 顶部统计条

    private var statsBar: some View {
        HStack(spacing: 8) {
            FRMetric("今日请求", value: "\(app.statistics.todayRequests)",
                     icon: "number", tint: FRDesign.accent)
            FRMetric("成功率", value: FRFormat.percent(app.statistics.todaySuccessRate),
                     icon: "checkmark.circle", tint: FRDesign.ok)
            FRMetric("Token", value: FRFormat.compact(app.statistics.todayTokens),
                     icon: "tokens", tint: FRDesign.accentCyan)
        }
    }

    // MARK: - 筛选 chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LogFilter.allCases) { f in
                    Button {
                        withAnimation(.snappy) { filter = f }
                    } label: {
                        Text(f.label)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(
                                filter == f ? FRDesign.accent.opacity(0.22) : Color(.secondarySystemGroupedBackground)))
                            .foregroundStyle(filter == f ? FRDesign.accent : Color.primary)
                            .overlay(
                                Capsule().strokeBorder(
                                    filter == f ? FRDesign.accent.opacity(0.45) : Color.clear,
                                    lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 单条日志

    private func logRow(_ log: DBRequestLog) -> some View {
        let isExpanded = expanded.contains(log.id)
        return FRCard {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.snappy) {
                        if isExpanded { expanded.remove(log.id) } else { expanded.insert(log.id) }
                    }
                } label: {
                    headerRow(log, expanded: isExpanded)
                }
                .buttonStyle(.plain)
                if isExpanded {
                    Divider().opacity(0.4)
                    detailRows(log)
                }
            }
        }
    }

    private func headerRow(_ log: DBRequestLog, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(FRFormat.time(log.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                statusBadge(log)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            HStack(spacing: 6) {
                Text(log.modelID)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(log.providerName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            HStack(spacing: 8) {
                Text(FRFormat.ms(log.durationMs))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                if log.totalTokens > 0 {
                    Text("\(FRFormat.compact(log.totalTokens)) tok")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if log.switched {
                    FRBadge("已切换", color: FRDesign.warn, icon: "arrow.triangle.branch")
                }
                Spacer()
                if !log.ok, let note = log.errorNote, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(FRDesign.err)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ log: DBRequestLog) -> some View {
        if log.ok {
            FRBadge("\(log.httpStatus)", color: FRDesign.ok, icon: "checkmark")
        } else if log.httpStatus == 0 {
            FRBadge("网络", color: FRDesign.err, icon: "wifi.exclamationmark")
        } else {
            FRBadge("\(log.httpStatus)", color: FRDesign.err, icon: "xmark")
        }
    }

    private func detailRows(_ log: DBRequestLog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Token 明细")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                tokenCell("提示", log.promptTokens)
                tokenCell("补全", log.completionTokens)
                tokenCell("总计", log.totalTokens)
            }
            if let note = log.errorNote, !note.isEmpty {
                Text("错误详情：\(note)")
                    .font(.system(size: 11))
                    .foregroundStyle(FRDesign.err)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("请求时间：\(FRFormat.dateTime(log.timestamp))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func tokenCell(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text("\(value)").font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 清理（数据库操作放私有方法，body 内不做 throws 调用）

    private func pruneLogs() {
        let before = app.recentLogs.count
        do {
            try app.store.pruneLogs(olderThan: max(1, app.settings.logRetentionDays))
            try app.store.context.save()
            app.refreshLogs()
            let after = app.recentLogs.count
            pruneMessage = "已清理 \(max(0, before - after)) 条日志（清理前 \(before) 条，清理后 \(after) 条）。"
        } catch {
            pruneMessage = "清理失败：\(error.localizedDescription)"
        }
    }
}
