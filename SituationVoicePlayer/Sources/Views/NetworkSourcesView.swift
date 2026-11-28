import SwiftUI
import ResourceAccessCore

struct NetworkSourcesView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject private var network = NetworkLibraryService.shared
    @State private var editing: NetworkLibrarySource?
    @State private var showEditor = false
    @State private var deactivating: NetworkLibrarySource?
    @State private var message: String?

    var body: some View {
        AppList {
            if !network.configurationIssues.isEmpty {
                Section {
                    ForEach(network.configurationIssues.indices, id: \.self) { index in
                        Text(network.configurationIssues[index]).foregroundStyle(.orange)
                    }
                } header: { Text("这些来源的配置暂时无法读取") } footer: {
                    Text("已保留原始配置。其他可用来源和本地作品不受影响，请先保全备份后再排查。")
                }
            }
            Section {
                Button { editing = nil; showEditor = true } label: {
                    Label("添加网络来源", systemImage: "plus")
                }.accessibilityIdentifier("networkAddSource")
            } footer: {
                Text("连接 NAS、电脑共享目录或网络音频后，手动选择作品导入个人音声或社团作品。只有选中的文件会加入媒体库。")
            }
            Section {
                ForEach(network.sources) { source in
                    HStack {
                        if source.enabled {
                            NavigationLink {
                                NetworkImportView(source: source, store: store)
                            } label: { sourceLabel(source) }
                        } else {
                            sourceLabel(source).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button { editing = source; showEditor = true } label: {
                            Image(systemName: "pencil")
                        }.buttonStyle(.borderless)
                            .accessibilityLabel(L10n.text("编辑来源"))
                            .accessibilityIdentifier("networkEdit-\(source.id)")
                    }
                    .contextMenu {
                        Button("编辑或重新绑定", systemImage: "pencil") { editing = source; showEditor = true }
                        if source.enabled {
                            Button("停用并清除凭据", systemImage: "network.slash", role: .destructive) { deactivating = source }
                        }
                    }
                }
                if network.sources.isEmpty { Text("还没有网络来源").foregroundStyle(AppTheme.secondaryText) }
            } header: { Text("已保存的来源") } footer: {
                Text("来源离线时仍可浏览已导入的作品资料和缓存封面。停用来源会清除登录凭据并保留作品，编辑后可重新连接。")
            }
        }
        .appPageBackground().appNavigationColors().navigationTitle(L10n.text("网络来源"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditor) {
            NetworkSourcesEditor(source: editing, store: store)
        }
        .alert("停用网络来源？", isPresented: Binding(get: { deactivating != nil }, set: { if !$0 { deactivating = nil } })) {
            Button("取消", role: .cancel) { deactivating = nil }
            Button("停用并清除凭据", role: .destructive) {
                guard let source = deactivating else { return }
                do { try network.deactivate(source); store.reload() }
                catch { message = NetworkLibraryService.message(for: error) }
                deactivating = nil
            }
        } message: {
            Text("保留已导入的作品、字幕、收听记录和封面。重新填写凭据并连接后可继续访问原文件。")
        }
        .alert("无法完成操作", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .task {
            guard let repository = store.repository else { return }
            do { try network.attach(repository: repository) }
            catch { message = NetworkLibraryService.message(for: error) }
        }
    }

    private func sourceLabel(_ source: NetworkLibrarySource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.name)
            Text(source.enabled ? NetworkLibraryKind(source.connection.kind).rawValue
                 : L10n.text("已停用 · 作品保留"))
                .font(.caption).foregroundStyle(AppTheme.secondaryText)
        }
    }
}

private struct NetworkSourcesEditor: View {
    let source: NetworkLibrarySource?
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: NetworkLibraryKind
    @State private var address: String
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var allowsHTTP: Bool
    @State private var requiresEncryption: Bool
    @State private var busy = false
    @State private var message: String?
    @State private var confirmRebind = false
    @State private var saveTask: Task<Void, Never>?
    @State private var loadedCredential = false

    init(source: NetworkLibrarySource?, store: LibraryStore) {
        self.source = source; self.store = store
        _name = State(initialValue: source?.name ?? "")
        _kind = State(initialValue: source.map { NetworkLibraryKind($0.connection.kind) } ?? .smb)
        _address = State(initialValue: source?.address ?? "")
        _allowsHTTP = State(initialValue: source?.connection.allowsInsecureHTTP ?? false)
        _requiresEncryption = State(initialValue: source?.requiresSMBEncryption ?? false)
    }

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    TextField("来源名称", text: $name).accessibilityIdentifier("networkSourceName")
                    Picker("协议", selection: $kind) {
                        ForEach(NetworkLibraryKind.allCases) { Text($0.rawValue).tag($0) }
                    }.accessibilityIdentifier("networkSourceKind")
                    TextField(kind.placeholder, text: $address, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).accessibilityIdentifier("networkSourceAddress")
                } header: { Text("连接位置") } footer: {
                    Text(L10n.key(kind == .http ? "HTTP 请填写一个音频文件的直接地址，不支持网页列表。" : "只浏览你指定的共享目录，不扫描整个服务器。"))
                }
                Section {
                    TextField("用户名（可选）", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("networkSourceUsername")
                    SecureField("密码", text: $password).accessibilityIdentifier("networkSourcePassword")
                    if kind == .smb {
                        TextField("域（可选）", text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: { Text("登录凭据") } footer: {
                    Text("用户名和密码保存在本机钥匙串中，不写入作品资料或备份。留空用户名使用服务器允许的匿名访问。")
                }
                Section {
                    if kind == .smb { Toggle("要求 SMB 连接加密", isOn: $requiresEncryption) }
                    else { Toggle("允许此来源使用 HTTP", isOn: $allowsHTTP).accessibilityIdentifier("networkAllowHTTP") }
                } footer: {
                    Text(L10n.key(kind == .smb ? "服务器不支持加密时连接会失败，不会自动降低要求。" : "HTTPS 使用系统证书验证。HTTP 不加密，仅在你信任的网络中启用。"))
                }
                if source != nil {
                    Section {
                        Text("修改连接地址会重新绑定现有来源，保留作品与音轨编号。新位置应包含相同的原文件；不会自动添加目录内的其他作品。")
                    }
                }
                if busy { Section { ProgressView("正在连接并核对文件…") } }
            }
            .disabled(busy)
            .appPageBackground().appNavigationColors().navigationTitle(L10n.key(source == nil ? "添加网络来源" : "编辑网络来源"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { saveTask?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接并保存") {
                        if let source, source.address != address.trimmingCharacters(in: .whitespacesAndNewlines)
                            || NetworkLibraryKind(source.connection.kind) != kind { confirmRebind = true }
                        else { save(confirmed: false) }
                    }.disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.isEmpty)
                        .accessibilityIdentifier("networkSaveSource")
                }
            }
            .alert("确认重新绑定来源？", isPresented: $confirmRebind) {
                Button("取消", role: .cancel) {}
                Button("核对并重新绑定") { save(confirmed: true) }
            } message: {
                Text("请确认新位置存放同一批原文件。会检查已导入文件是否存在及已知的大小或内容差异；大小相同不能证明内容完全一致。原作品资料和播放记录保留。")
            }
            .alert("连接未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("确定", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
            .task {
                guard !loadedCredential else { return }
                loadedCredential = true
                guard let source else { return }
                do {
                    if let stored = try NetworkLibraryService.shared.storedCredential(for: source),
                       case let .usernamePassword(user, secret, savedDomain) = stored {
                        username = user; password = secret; domain = savedDomain ?? ""
                    }
                } catch { message = NetworkLibraryService.message(for: error) }
            }
            .onDisappear { saveTask?.cancel() }
        }
    }

    private func save(confirmed: Bool) {
        busy = true
        saveTask = Task {
            do {
                try await NetworkLibraryService.shared.save(existing: source, name: name, kind: kind,
                    address: address, username: username, password: password, domain: domain,
                    allowsHTTP: allowsHTTP, requiresEncryption: requiresEncryption, confirmRebind: confirmed)
                store.reload(); dismiss()
            } catch { if !Task.isCancelled { message = NetworkLibraryService.message(for: error) } }
            busy = false
        }
    }
}
