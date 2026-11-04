import SwiftUI
import Charts

/// 统计中心：请求量、成功率、Token、延迟、排行与错误分布
struct StatisticsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var stats = app.statistics
            ZStack {
                FRBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        rangeCard($stats)
                        metricsSection
                        dailyRequestsCard
                        successRateCard
                        tokenCard
                        latencyCard
                        modelRankingCard
                        providerRankingCard
                        errorHistogramCard
                        hourlyCard
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("统计中心")
            .navigationBarTitleDisplayMode(.inline)
            .task { app.statistics.reload() }
            .refreshable { app.statistics.reload() }
    }

    // MARK: - 时间范围

    private func rangeCard(_ days: Binding<Int>) -> some View {
        FRCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("时间范围").font(.system(size: 12, weight: .semibold))
                Picker("时间范围", selection: days) {
                    Text("近 7 天").tag(7)
                    Text("近 14 天").tag(14)
                    Text("近 30 天").tag(30)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: - 指标

    private var metricsSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                FRMetric("今日请求", value: "\(app.statistics.todayRequests)",
                         icon: "number", tint: FRDesign.accent)
                FRMetric("成功率", value: FRFormat.percent(app.statistics.todaySuccessRate),
                         icon: "checkmark.circle", tint: FRDesign.ok)
                FRMetric("今日 Token", value: FRFormat.compact(app.statistics.todayTokens),
                         icon: "tokens", tint: FRDesign.accentCyan)
                FRMetric("平均延迟", value: FRFormat.ms(app.statistics.avgLatencyMs),
                         icon: "clock", tint: FRDesign.warn)
            }
            HStack(spacing: 8) {
                FRMetric("P95 延迟", value: FRFormat.ms(app.statistics.p95LatencyMs),
                         icon: "gauge.with.needle", tint: FRDesign.warn)
                FRMetric("故障切换", value: "\(app.statistics.switchCount)",
                         icon: "arrow.triangle.branch", tint: FRDesign.accent)
            }
        }
    }

    // MARK: - 图表卡片

    private func chartCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        FRCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold))
                content()
            }
        }
    }

    private func chartEmpty() -> some View {
        VStack(spacing: 6) {
            Spacer(minLength: 22)
            Image(systemName: "chart.bar").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text("暂无数据").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 22)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
    }

    private var dailyRequestsCard: some View {
        chartCard("每日请求量") {
            if app.statistics.dailySeries.isEmpty {
                chartEmpty()
            } else {
                Chart(app.statistics.dailySeries) { p in
                    BarMark(x: .value("日期", p.day), y: .value("请求量", p.requests))
                        .foregroundStyle(FRDesign.accent.gradient)
                        .cornerRadius(2)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() }
                }
                .frame(height: 150)
            }
        }
    }

    private var successRateCard: some View {
        chartCard("每日成功率") {
            if app.statistics.dailySeries.isEmpty {
                chartEmpty()
            } else {
                Chart(app.statistics.dailySeries) { p in
                    LineMark(x: .value("日期", p.day), y: .value("成功率", p.successRate))
                        .foregroundStyle(FRDesign.ok)
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("日期", p.day), y: .value("成功率", p.successRate))
                        .foregroundStyle(FRDesign.ok)
                        .symbolSize(24)
                }
                .chartYScale(domain: 0.0...1.0)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0.0, 0.5, 1.0]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = value.as(Double.self) {
                                Text("\(Int(d * 100))%").font(.system(size: 8))
                            }
                        }
                    }
                }
                .frame(height: 150)
            }
        }
    }

    private var tokenCard: some View {
        chartCard("每日 Token") {
            if app.statistics.dailySeries.isEmpty {
                chartEmpty()
            } else {
                Chart(app.statistics.dailySeries) { p in
                    AreaMark(x: .value("日期", p.day), y: .value("Token", p.tokens))
                        .foregroundStyle(
                            LinearGradient(colors: [FRDesign.accentCyan.opacity(0.45),
                                                    FRDesign.accentCyan.opacity(0.03)],
                                           startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() }
                }
                .frame(height: 150)
            }
        }
    }

    private var latencyCard: some View {
        chartCard("延迟散点（最近 \(app.statistics.latencySeries.count) 次）") {
            if app.statistics.latencySeries.isEmpty {
                chartEmpty()
            } else {
                Chart(app.statistics.latencySeries) { p in
                    PointMark(x: .value("时间", p.time), y: .value("延迟 ms", p.ms))
                        .foregroundStyle(FRDesign.warn)
                        .symbolSize(12)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() }
                }
                .frame(height: 150)
            }
        }
    }

    private var modelRankingCard: some View {
        let top = Array(app.statistics.modelRanking.prefix(10))
        return chartCard("模型排行 Top 10") {
            if top.isEmpty {
                chartEmpty()
            } else {
                Chart(top) { item in
                    BarMark(x: .value("请求量", item.requests), y: .value("模型", item.name))
                        .foregroundStyle(FRDesign.accent.gradient)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let s = value.as(String.self) {
                                Text(s).font(.system(size: 8)).lineLimit(1)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom) { AxisGridLine(); AxisValueLabel() }
                }
                .frame(height: 170)
            }
        }
    }

    private var providerRankingCard: some View {
        let top = Array(app.statistics.providerRanking.prefix(10))
        return chartCard("服务商排行 Top 10") {
            if top.isEmpty {
                chartEmpty()
            } else {
                Chart(top) { item in
                    BarMark(x: .value("请求量", item.requests), y: .value("服务商", item.name))
                        .foregroundStyle(FRDesign.accentCyan.gradient)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let s = value.as(String.self) {
                                Text(s).font(.system(size: 8)).lineLimit(1)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom) { AxisGridLine(); AxisValueLabel() }
                }
                .frame(height: 170)
            }
        }
    }

    private var errorHistogramCard: some View {
        chartCard("错误分布") {
            if app.statistics.errorHistogram.isEmpty {
                chartEmpty()
            } else {
                Chart(app.statistics.errorHistogram) { b in
                    BarMark(x: .value("状态", "\(b.status)"), y: .value("次数", b.count))
                        .foregroundStyle(FRDesign.err.gradient)
                        .cornerRadius(2)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() }
                }
                .frame(height: 150)
            }
        }
    }

    private var hourlyCard: some View {
        chartCard("今日 24 小时分布") {
            if app.statistics.hourlySeries.allSatisfy({ $0.requests == 0 }) {
                chartEmpty()
            } else {
                Chart(app.statistics.hourlySeries) { p in
                    BarMark(x: .value("小时", p.hour), y: .value("请求量", p.requests))
                        .foregroundStyle(FRDesign.accentCyan.gradient)
                        .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                        AxisValueLabel {
                            if let i = value.as(Int.self) {
                                Text("\(i)时").font(.system(size: 8))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() }
                }
                .frame(height: 150)
            }
        }
    }
}
