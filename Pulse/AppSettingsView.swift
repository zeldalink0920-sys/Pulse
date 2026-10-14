import SwiftUI
import Security

struct RestaurantConnection: Codable, Identifiable {
    var id: UUID
    var name: String
    var baseURL: String
}

enum RestaurantAPIError: LocalizedError {
    case address, key, redirect, response, unauthorized, forbidden, http(Int), credential(Int32), json, tooLarge
    var errorDescription: String? {
        switch self {
        case .address: return "请填写有效的 HTTPS 餐馆地址，不要包含账号、查询参数或片段。"
        case .key: return "请填写这家餐馆的 API 密钥。"
        case .credential(let code): return "密钥无法保存到系统钥匙串（\(code)），请检查安装签名后重试。"
        case .redirect: return "接口发生重定向，请确认并填写最终的 HTTPS 地址。"
        case .response: return "服务器没有返回有效响应。"
        case .unauthorized: return "密钥无效或已过期（401），请在餐馆后台重新生成。"
        case .forbidden: return "此密钥没有访问权限（403），请检查餐馆后台设置。"
        case .http(let code): return "请求失败（HTTP \(code)）。"
        case .json: return "接口没有返回有效的 JSON 数据，请检查地址。"
        case .tooLarge: return "返回数据过大，请缩小查询范围。"
        }
    }
}

enum RestaurantAddress {
    static func normalized(_ text: String) throws -> URL {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: input),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw RestaurantAPIError.address
        }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        for endpoint in RestaurantEndpoint.allCases {
            let suffix = "/api/v1/" + endpoint.rawValue
            if path.hasSuffix(suffix) { path = String(path.dropLast(suffix.count)); break }
        }
        if path.hasSuffix("/api/v1") { path = String(path.dropLast(7)) }
        parts.path = path
        guard let url = parts.url else { throw RestaurantAPIError.address }
        return url
    }
}

enum RestaurantEndpoint: String, CaseIterable, Identifiable {
    case status, tables, diners, printers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: return "全部统计"
        case .tables: return "开台数量"
        case .diners: return "用餐人数"
        case .printers: return "打印机"
        }
    }
}

enum RestaurantKeychain {
    private static let service = "com.pulse.personal.restaurant-api"
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    static func read(_ id: UUID) -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String, id: UUID) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw RestaurantAPIError.credential(added) }
        } else if status != errSecSuccess { throw RestaurantAPIError.credential(status) }
    }
    static func delete(_ id: UUID) { SecItemDelete(query(id) as CFDictionary) }
}

@MainActor
final class RestaurantConnections: ObservableObject {
    @Published private(set) var items: [RestaurantConnection]
    private let defaultsKey = "restaurant.connections.v1"
    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([RestaurantConnection].self, from: data) {
            items = decoded
        } else { items = [] }
    }
    func save(_ item: RestaurantConnection, key: String) throws {
        try RestaurantKeychain.save(key, id: item.id)
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
        persist()
    }
    func delete(_ item: RestaurantConnection) {
        RestaurantKeychain.delete(item.id)
        items.removeAll { $0.id == item.id }
        persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }
}

private final class RestaurantRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct RestaurantResultRow: Identifiable {
    let id: String
    let label: String
    let value: String
}

enum RestaurantAPI {
    static func fetch(_ connection: RestaurantConnection, key: String,
                      endpoint: RestaurantEndpoint) async throws -> [RestaurantResultRow] {
        let base = try RestaurantAddress.normalized(connection.baseURL)
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else { throw RestaurantAPIError.key }
        let url = base.appendingPathComponent("api").appendingPathComponent("v1").appendingPathComponent(endpoint.rawValue)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: RestaurantRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw RestaurantAPIError.response }
        switch http.statusCode {
        case 200...299: break
        case 300...399: throw RestaurantAPIError.redirect
        case 401: throw RestaurantAPIError.unauthorized
        case 403: throw RestaurantAPIError.forbidden
        default: throw RestaurantAPIError.http(http.statusCode)
        }
        guard data.count <= 2_000_000 else { throw RestaurantAPIError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw RestaurantAPIError.json
        }
        return rows(object, path: "")
    }

    private static let labels = [
        "open_count": "开台数量", "current_guests": "当前用餐人数",
        "today_guests": "今日用餐人数", "offline_count": "离线打印机数量",
        "has_offline": "是否有打印机离线", "revenue": "营业额",
        "today_revenue": "今日营业额", "tables": "桌台", "diners": "用餐人数",
        "printers": "打印机", "status": "状态", "name": "名称",
        "online": "在线", "total": "总计", "data": "数据"
    ]
    private static func rows(_ object: Any, path: String, depth: Int = 0) -> [RestaurantResultRow] {
        guard depth < 12 else { return [RestaurantResultRow(id: path, label: path, value: "内容层级过深")] }
        if let dict = object as? [String: Any], !dict.isEmpty {
            return dict.keys.sorted().flatMap { key -> [RestaurantResultRow] in
                // Never render credential fields even if a server includes them.
                let lower = key.lowercased()
                if ["token", "secret", "password", "authorization", "api_key", "apikey"].contains(where: { lower.contains($0) }) { return [] }
                let title = labels[key] ?? key
                let next = path.isEmpty ? title : path + " · " + title
                return rows(dict[key]!, path: next, depth: depth + 1)
            }
        }
        if let list = object as? [Any], !list.isEmpty {
            return list.prefix(200).enumerated().flatMap { index, item in
                rows(item, path: path + " [\(index + 1)]", depth: depth + 1)
            }
        }
        let value: String
        if object is NSNull { value = "—" }
        else if let number = object as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { value = number.boolValue ? "是" : "否" }
        else if let number = object as? NSNumber { value = number.stringValue }
        else if let string = object as? String { value = string }
        else { value = "暂无数据" }
        return [RestaurantResultRow(id: path, label: path.isEmpty ? "结果" : path, value: value)]
    }
}

struct AppSettingsView: View {
    @StateObject private var connections = RestaurantConnections()
    @State private var adding = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(connections.items) { item in
                        NavigationLink {
                            RestaurantDashboardView(connection: item, connections: connections)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.name).font(.headline)
                                Text(item.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.padding(.vertical, 5)
                        }
                    }
                    Button { adding = true } label: { Label("添加餐馆 API", systemImage: "plus.circle") }
                        .accessibilityIdentifier("restaurant.add")
                } header: { Text("餐馆 API") } footer: {
                    Text("每家餐馆单独保存地址和密钥。密钥在餐馆管理员 → 系统设置 → 对外只读 API 中生成。")
                }
                Section("使用说明") {
                    Text("选择餐馆后可查询全部统计、开台数量、用餐人数和打印机状态。仅发送只读 GET 请求。")
                    Text("填写餐馆根地址；第二家餐馆可填写带 /r/餐馆名称 的地址。也支持粘贴完整的 /api/v1/status 地址。")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("设置")
            .sheet(isPresented: $adding) { RestaurantEditorView(connections: connections, existing: nil) }
        }
    }
}

struct RestaurantEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var connections: RestaurantConnections
    let existing: RestaurantConnection?
    @State private var name: String
    @State private var address: String
    @State private var key = ""
    @State private var error: String?
    init(connections: RestaurantConnections, existing: RestaurantConnection?) {
        self.connections = connections
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _address = State(initialValue: existing?.baseURL ?? "https://order.lydialink.es")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("餐馆信息") {
                    TextField("餐馆名称", text: $name).accessibilityIdentifier("restaurant.name")
                    TextField("HTTPS 地址", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("restaurant.address")
                }
                Section {
                    SecureField(existing == nil ? "API 密钥" : "留空保留原密钥", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("restaurant.key")
                } header: { Text("API 密钥") } footer: {
                    Text("只填写密钥本身，无需添加 Bearer。密钥加密保存在此设备的系统钥匙串中。")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(existing == nil ? "添加餐馆" : "编辑餐馆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("restaurant.save")
                }
            }
        }
    }
    private func save() {
        do {
            let url = try RestaurantAddress.normalized(address)
            let id = existing?.id ?? UUID()
            let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveKey = token.isEmpty ? (existing.flatMap { RestaurantKeychain.read($0.id) } ?? "") : token
            guard !effectiveKey.isEmpty, !effectiveKey.contains("\n"), !effectiveKey.contains("\r") else { throw RestaurantAPIError.key }
            try connections.save(RestaurantConnection(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), baseURL: url.absoluteString), key: effectiveKey)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct RestaurantDashboardView: View {
    let connection: RestaurantConnection
    @ObservedObject var connections: RestaurantConnections
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint: RestaurantEndpoint = .status
    @State private var rows: [RestaurantResultRow] = []
    @State private var message = "点击测试连接，读取这家餐馆的数据。"
    @State private var updated: Date?
    @State private var busy = false
    @State private var editing = false
    @State private var deleting = false
    @State private var requestTask: Task<Void, Never>?
    private var current: RestaurantConnection { connections.items.first { $0.id == connection.id } ?? connection }
    var body: some View {
        List {
            Section {
                Text(current.baseURL).font(.caption).foregroundStyle(.secondary)
                Picker("查询内容", selection: $endpoint) {
                    ForEach(RestaurantEndpoint.allCases) { value in Text(value.title).tag(value) }
                }
                Button { load() } label: {
                    HStack {
                        Text(updated == nil ? "测试连接 / 获取数据" : "刷新数据")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }.disabled(busy).accessibilityIdentifier("restaurant.connect")
                Text(message).font(.footnote).foregroundStyle(.secondary)
                if let updated { Text("更新于 \(updated.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            }
            if !rows.isEmpty {
                Section(endpoint.title) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(row.label).font(.caption).foregroundStyle(.secondary)
                            Text(row.value).font(.title3).textSelection(.enabled)
                        }.padding(.vertical, 3)
                    }
                }
            }
            Section {
                Button("编辑地址与密钥") { editing = true }
                Button("删除餐馆", role: .destructive) { deleting = true }
            }
        }
        .navigationTitle(current.name).navigationBarTitleDisplayMode(.inline)
        .onChange(of: endpoint) { _, _ in clear() }
        .onChange(of: current.baseURL) { _, _ in clear() }
        .sheet(isPresented: $editing, onDismiss: { clear() }) {
            RestaurantEditorView(connections: connections, existing: current)
        }
        .confirmationDialog("删除这家餐馆及其本机保存的密钥？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除餐馆", role: .destructive) { clear(); connections.delete(current); dismiss() }
        }
        .onDisappear { clear() }
    }
    private func clear() {
        requestTask?.cancel()
        requestTask = nil
        busy = false
        rows = []
        updated = nil
        message = "点击测试连接，读取这家餐馆的数据。"
    }
    private func load() {
        let item = current
        let selected = endpoint
        guard let key = RestaurantKeychain.read(item.id) else {
            message = "没有找到密钥，请编辑餐馆并重新填写。"; return
        }
        busy = true
        rows = []
        updated = nil
        message = "正在连接…"
        requestTask = Task { @MainActor in
            defer { if !Task.isCancelled { busy = false } }
            do {
                let result = try await RestaurantAPI.fetch(item, key: key, endpoint: selected)
                guard !Task.isCancelled else { return }
                rows = result
                updated = Date()
                message = "连接成功"
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
        }
    }
}
