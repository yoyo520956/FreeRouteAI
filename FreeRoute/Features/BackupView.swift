import SwiftUI
import UniformTypeIdentifiers

/// 备份 / 恢复：导出 JSON（可选 AES-GCM 加密），从文件导入
struct BackupView: View {
    @Environment(AppState.self) private var app

    @State private var includeKeys = false
    @State private var exportPassphrase = ""
    @State private var importPassphrase = ""
    @State private var exportFileURL: URL?
    @State private var exportError: String?
    @State private var showImporter = false
    @State private var importReport: BackupService.ImportReport?
    @State private var importError: String?

    var body: some View {
        ZStack {
            FRBackground()
            ScrollView {
                VStack(spacing: 12) {
                    exportCard
                    importCard
                    noteCard
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("备份 / 恢复")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json, .data, .plainText]) { (result: Result<URL, Error>) in
            switch result {
            case .success(let url):
                importFile(url)
            case .failure(let e):
                importError = e.localizedDescription
            }
        }
        .alert("导出失败", isPresented: Binding(get: { exportError != nil },
                                               set: { if !$0 { exportError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .alert("导入失败", isPresented: Binding(get: { importError != nil },
                                               set: { if !$0 { importError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert("导入完成", isPresented: Binding(get: { importReport != nil },
                                               set: { if !$0 { importReport = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            if let r = importReport {
                Text("服务商 \(r.providers) 个 · 模型 \(r.models) 个 · 日志 \(r.logs) 条\n\(r.message)")
            }
        }
    }

    // MARK: - 导出

    private var exportCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("导出备份", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FRDesign.accent)
                Toggle(isOn: $includeKeys) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("包含密钥标记")
                        Text("默认关闭：导出不含明文密钥")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                SecureField("导出口令（可选，用于加密）", text: $exportPassphrase)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    exportBackup()
                } label: {
                    Label("导出备份", systemImage: "arrow.up.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(FRDesign.accent)
                .disabled(app.providers.isEmpty && app.models.isEmpty && app.recentLogs.isEmpty)
                if let url = exportFileURL {
                    Divider().opacity(0.4)
                    Text("备份已生成，点「分享备份文件」保存或发送。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    ShareLink(item: url) {
                        Label("分享备份文件", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func exportBackup() {
        do {
            let service = BackupService()
            let keychain = app.keychain
            var data = try service.makeSnapshot(
                providers: app.providers,
                models: app.models,
                logs: app.recentLogs,
                settings: app.settings,
                includeKeys: includeKeys,
                keyReader: { keychain.get($0) }
            )
            if !exportPassphrase.isEmpty {
                data = try service.encrypt(data, passphrase: exportPassphrase)
            }
            let name = "FreeRoute-\(Self.fileStamp()).frb"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            exportFileURL = url
        } catch {
            exportFileURL = nil
            exportError = error.localizedDescription
        }
    }

    // MARK: - 导入

    private var importCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("导入备份", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FRDesign.accentCyan)
                SecureField("导入口令（若备份已加密）", text: $importPassphrase)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    showImporter = true
                } label: {
                    Label("选择备份文件", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(FRDesign.accentCyan)
                Text("支持 .json / .data / .txt；加密文件需输入正确口令。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func importFile(_ url: URL) {
        do {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let service = BackupService()
            let payload: Data
            if service.isEncrypted(data) {
                guard !importPassphrase.isEmpty else {
                    importError = "该备份已加密，请输入口令后再导入。"
                    return
                }
                payload = try service.decrypt(data, passphrase: importPassphrase)
            } else {
                payload = data
            }
            let report = try service.restore(payload, into: app)
            importReport = report
            app.providers = (try? app.store.fetchProviders()) ?? []
            app.models = (try? app.store.fetchModels()) ?? []
            app.refreshLogs()
            app.statistics.reload()
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: - 说明

    private var noteCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("说明", systemImage: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("• 备份包含配置、模型与请求日志。")
                Text("• 密钥本体仍在钥匙串，永不写入备份文件。")
                Text("• 若填写导出口令，文件将用 AES-GCM 加密。")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
