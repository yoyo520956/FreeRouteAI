#!/usr/bin/env python3
"""把剩余「固定像素布局」改成按 size class / 容器自适应。每处都断言命中，防止静默漏改。"""
import io, sys

def patch(path, pairs):
    s = io.open(path, encoding='utf-8').read()
    for name, old, new in pairs:
        n = s.count(old)
        if n != 1:
            sys.exit(f"✗ {path} :: {name} 命中 {n} 处（预期 1）")
        s = s.replace(old, new)
        print(f"  ✓ {name}")
    io.open(path, 'w', encoding='utf-8').write(s)

print("FreeCatalogView")
patch('FreeRoute/Features/FreeCatalogView.swift', [(
    "row() → FRKeyValueRow",
    '''    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(k).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(v).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }''',
    '''    private func row(_ k: String, _ v: String) -> some View {
        FRKeyValueRow(k, v,
                      keyFont: .system(size: 10, weight: .semibold),
                      valueFont: .system(size: 11))
    }''')])

print("SmartRouterView")
patch('FreeRoute/Features/SmartRouterView.swift', [
    ("注入 horizontalSizeClass",
     '''    @Environment(AppState.self) private var app
    @Environment(AppCoordinator.self) private var coordinator''',
     '''    @Environment(AppState.self) private var app
    @Environment(AppCoordinator.self) private var coordinator
    /// 布局只认 size class，不认机型：宽屏（iPad/横屏/Mac 宽窗）多列，窄屏两列
    @Environment(\\.horizontalSizeClass) private var hSize'''),
    ("模式网格列数自适应",
     '''                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(RouterMode.allCases) { m in
                        modeCard(m)
                    }
                }''',
     '''                LazyVGrid(columns: FRLayout.grid(hSize, compact: 2, regular: 4), spacing: 8) {
                    ForEach(RouterMode.allCases) { m in
                        modeCard(m)
                    }
                }'''),
    ("候选排名头部去固定 150pt",
     '''                HStack {
                    Text("候选排名").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Picker("筛选", selection: $showAll) {
                        Text("只看待选").tag(false)
                        Text("全部").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }''',
     '''                // 窄屏/大字号放不下时整体退成上下排（原先写死 150pt 会截断）
                FRAdaptiveHeader(controlWidth: 150) {
                    Text("候选排名").font(.system(size: 13, weight: .semibold))
                } control: {
                    Picker("筛选", selection: $showAll) {
                        Text("只看待选").tag(false)
                        Text("全部").tag(true)
                    }
                    .pickerStyle(.segmented)
                }'''),
])

print("SettingsView")
patch('FreeRoute/Features/SettingsView.swift', [(
    "端口输入框去固定宽",
    '''                TextField("3000", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)''',
    '''                TextField("3000", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    // 给一个可收缩区间而不是死宽 90pt：超大字号下让系统能压缩它
                    .frame(minWidth: 56, maxWidth: 96, alignment: .trailing)''')])

print("GatewayView")
patch('FreeRoute/Features/GatewayView.swift', [(
    "端口输入框去固定宽",
    '''                            .font(.system(size: 13, design: .monospaced))
                            .frame(width: 110)''',
    '''                            .font(.system(size: 13, design: .monospaced))
                            // 可收缩区间替代死宽 110pt，避免窄屏/大字号顶出卡片
                            .frame(minWidth: 72, maxWidth: 118)''')])

print("MonitorView")
patch('FreeRoute/Features/MonitorView.swift', [(
    "悬浮窗去固定 150pt",
    '''        .padding(10)
        .frame(width: 150)''',
    '''        .padding(10)
        // 悬浮监控窗：给可收缩区间，小屏（SE/放大显示）不会顶出屏幕边缘
        .frame(minWidth: 128, maxWidth: 176)''')])

print("全部命中")
