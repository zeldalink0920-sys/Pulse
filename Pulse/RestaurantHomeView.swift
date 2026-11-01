import SwiftUI
import Charts

enum PrinterOverallState: String {
    case online = "在线", offline = "离线", unknown = "待确认", notConfigured = "未配置"
    var color: Color {
        switch self { case .online: return Color(red: 0.34, green: 0.48, blue: 0.39)
        case .offline: return Color(red: 0.70, green: 0.38, blue: 0.32)
        default: return .secondary }
    }
}
struct RestaurantStatus: Decodable {
    struct Tables: Decodable { let openCount: Int?; enum CodingKeys: String, CodingKey { case openCount = "open_count" } }
    struct Diners: Decodable {
        let currentGuests: Int?
        let todayGuests: Int?
        enum CodingKeys: String, CodingKey { case currentGuests = "current_guests", todayGuests = "today_guests" }
    }
    struct Printers: Decodable {
        struct Item: Decodable { let state: String? }
        let agentOnline: Bool?
        let offlineCount: Int?
        let unknownCount: Int?
        let hasOffline: Bool?
        let items: [Item]?
        enum CodingKeys: String, CodingKey {
            case agentOnline = "agent_online", offlineCount = "offline_count", unknownCount = "unknown_count", hasOffline = "has_offline", items
        }
        var overall: PrinterOverallState {
            if (offlineCount ?? 0) > 0 || hasOffline == true || agentOnline == false { return .offline }
            if let items, items.allSatisfy({ $0.state == "disabled" }) { return .notConfigured }
            guard agentOnline == true, let offlineCount, let unknownCount, hasOffline != nil else { return .unknown }
            if unknownCount > 0 { return .unknown }
            return offlineCount == 0 && hasOffline == false ? .online : .unknown
        }
    }
    let ok: Bool?
    let restaurant: String?
    let updatedAt: Double?
    let date: String?
    let timezone: String?
    let tables: Tables?
    let diners: Diners?
    let printers: Printers?
    enum CodingKeys: String, CodingKey { case ok, restaurant, updatedAt = "updated_at", date, timezone, tables, diners, printers }
    static func decode(_ data: Data) throws -> RestaurantStatus {
        let result = try JSONDecoder().decode(RestaurantStatus.self, from: data)
        guard result.ok != false, result.tables != nil, result.diners != nil else { throw RestaurantAPIError.response }
        return result
    }
}
struct RestaurantGuestDay: Codable, Identifiable {
    let date: String
    let guests: Int?
    var missing: Int? = nil
    var openedRounds: Int? = nil
    enum CodingKeys: String, CodingKey {
        case date, guests, missing = "rounds_without_guests", openedRounds = "opened_rounds"
    }
    var id: String { date }
    var shortDate: String { String(date.suffix(5)).replacingOccurrences(of: "-", with: "/") }
}
struct RestaurantGuestHistory: Decodable {
    let ok: Bool
    let items: [RestaurantGuestDay]
    let timezone: String
    let startDate: String
    let endDate: String
    enum CodingKeys: String, CodingKey {
        case ok, items, timezone, startDate = "start_date", endDate = "end_date"
    }
    func week(ending day: String) throws -> [RestaurantGuestDay] {
        let dates = RestaurantWeek.dates(ending: day)
        guard let first = dates.first, ok, startDate == first, endDate == day,
              TimeZone(identifier: timezone) != nil,
              Set(items.map(\.date)).count == items.count,
              items.allSatisfy({ dates.contains($0.date) && ($0.guests == nil || $0.guests! >= 0) && ($0.missing ?? 0) >= 0 && ($0.openedRounds ?? 0) >= 0 }) else {
            throw RestaurantAPIError.response
        }
        return RestaurantWeek.filled(items, ending: day)
    }
}

struct RestaurantHistoryCache: Codable {
    let days: [RestaurantGuestDay]
    let timezone: String
    let savedAt: Date
}
enum RestaurantWeek {
    static func historyQuery(ending day: String) throws -> [URLQueryItem] {
        guard let first = dates(ending: day).first else { throw RestaurantAPIError.response }
        return [URLQueryItem(name: "start_date", value: first), URLQueryItem(name: "end_date", value: day)]
    }
    static func dates(ending day: String) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let end = formatter.date(from: day), formatter.string(from: end) == day else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return (-6...0).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: end).map { formatter.string(from: $0) }
        }
    }
    static func filled(_ records: [RestaurantGuestDay], ending day: String) -> [RestaurantGuestDay] {
        let valid = records.filter { ($0.guests ?? 0) >= 0 }
        let indexed = Dictionary(valid.map { ($0.date, $0) }, uniquingKeysWith: { _, latest in latest })
        return dates(ending: day).map { indexed[$0] ?? RestaurantGuestDay(date: $0, guests: nil) }
    }
}

@MainActor
final class RestaurantMonitor: ObservableObject {
    @Published var status: RestaurantStatus?
    @Published var history: [RestaurantGuestDay] = []
    @Published var error: String?
    @Published var historyNote = "等待读取近 7 天人数"
    @Published var historyError: String?
    @Published var loading = false
    @Published var lastRefresh: Date?
    @Published var isServerHistory = false
    private var fingerprint: String?
    private var observations: [RestaurantGuestDay] = []
    private var cacheKey = ""
    private var serverCache: RestaurantHistoryCache?

    var todayOpenedCount: Int? {
        guard let day = status?.date else { return nil }
        return history.first { $0.date == day }?.openedRounds
    }
    func refresh(_ connection: RestaurantConnection) async {
        let identity = connection.id.uuidString + "|" + connection.baseURL
        if fingerprint != identity {
            fingerprint = identity
            status = nil; history = []; error = nil; historyError = nil; lastRefresh = nil; isServerHistory = false
            cacheKey = "restaurant.observed.v1." + identity
            observations = UserDefaults.standard.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode([RestaurantGuestDay].self, from: $0) } ?? []
            serverCache = UserDefaults.standard.data(forKey: cacheKey + ".server").flatMap { try? JSONDecoder().decode(RestaurantHistoryCache.self, from: $0) }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-restaurants") {
            let fixture = Data(#"{"ok":true,"date":"2026-10-16","timezone":"Europe/Madrid","tables":{"open_count":6},"diners":{"current_guests":18,"today_guests":73},"printers":{"agent_online":true,"offline_count":0,"unknown_count":0,"has_offline":false,"items":[{"state":"online"}]}}"#.utf8)
            status = try? RestaurantStatus.decode(fixture)
            history = RestaurantWeek.dates(ending: "2026-10-16").enumerated().map { RestaurantGuestDay(date: $0.element, guests: 40 + $0.offset * 5, openedRounds: 10 + $0.offset) }
            historyNote = "自动化测试数据"
            isServerHistory = true; lastRefresh = Date()
            return
        }
        #endif
        guard !loading else { return }
        loading = true
        defer { loading = false }
        guard let key = RestaurantKeychain.read(connection.id) else {
            error = "请在设置中填写这家餐馆的 API 密钥"; return
        }
        do {
            let payload = try await RestaurantAPI.request(connection, key: key, path: "status")
            let snapshot = try RestaurantStatus.decode(payload)
            try Task.checkCancellation()
            status = snapshot; error = nil; lastRefresh = Date()
            guard let day = snapshot.date, !RestaurantWeek.dates(ending: day).isEmpty else {
                history = []; historyNote = "服务器未提供有效日期，暂不能绘制历史人数"; return
            }
            if let count = snapshot.diners?.todayGuests, count >= 0 {
                observations.removeAll { $0.date == day }
                observations.append(RestaurantGuestDay(date: day, guests: count))
                observations = Array(observations.sorted { $0.date < $1.date }.suffix(14))
                if let data = try? JSONEncoder().encode(observations) { UserDefaults.standard.set(data, forKey: cacheKey) }
            }
            if !isServerHistory { showSavedHistory(ending: day) }
                do {
                    let query = try RestaurantWeek.historyQuery(ending: day)
                    let data = try await RestaurantAPI.request(connection, key: key, path: "history", query: query)
                    let result = try JSONDecoder().decode(RestaurantGuestHistory.self, from: data)
                    let week = try result.week(ending: day)
                    try Task.checkCancellation()
                    history = week
                    isServerHistory = true
                    historyError = nil
                    let cache = RestaurantHistoryCache(days: week, timezone: result.timezone, savedAt: Date())
                    serverCache = cache
                    if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: cacheKey + ".server") }
                    historyNote = "每日用餐总人数 · 按餐馆时区 \(result.timezone) 统计，今日持续更新"
                } catch {
                    guard !Task.isCancelled else { return }
                    isServerHistory = false
                    historyError = "今日开台更新失败：\(error.localizedDescription)"
                    showSavedHistory(ending: day)
                    historyNote = "历史人数更新失败：\(error.localizedDescription)。" + historyNote
                }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
    private func showSavedHistory(ending day: String) {
        if let cache = serverCache {
            history = RestaurantWeek.filled(cache.days, ending: day)
            historyNote = "显示上次保存的历史人数（\(cache.savedAt.formatted(date: .abbreviated, time: .shortened))，时区 \(cache.timezone)）。空白日期表示暂无记录。"
        } else {
            history = RestaurantWeek.filled(observations, ending: day)
            historyNote = "仅显示本机实际读取过的当日累计人数，未读取过的日期显示暂无记录，并非 0 人。"
        }
    }
}

struct RestaurantCarousel: View {
    @EnvironmentObject private var connections: RestaurantConnections
    let refreshToken: UUID
    @State private var selected = 0
    @State private var configure = false
    private var restaurants: [RestaurantConnection] { connections.items.filter(\.showOnHome) }
    private var pageCount: Int { max(3, restaurants.count) }
    var body: some View {
        VStack(spacing: 16) {
            TabView(selection: $selected) {
                ForEach(0..<pageCount, id: \.self) { index in
                    if index < restaurants.count {
                        RestaurantHomePage(connection: restaurants[index], refreshToken: refreshToken)
                            .padding(.horizontal, 3).tag(index)
                    } else {
                        Button { configure = true } label: {
                            VStack(alignment: .leading, spacing: 22) {
                                Text("餐馆 \(index + 1)").font(.system(size: 14, weight: .medium)).tracking(2)
                                Spacer()
                                Image(systemName: "plus.circle").font(.system(size: 32, weight: .ultraLight))
                                Text("添加餐馆卡片").font(.system(size: 22, design: .serif))
                                Text("在设置中填写这家餐馆的 API").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                                .background(Color(white: 0.84)).clipShape(RoundedRectangle(cornerRadius: 28))
                                .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.8), lineWidth: 1))
                        }.buttonStyle(.plain).padding(.horizontal, 3).padding(.vertical, 6).tag(index)
                            .accessibilityIdentifier("restaurant.placeholder.\(index)")
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never)).frame(height: 290)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Button { withAnimation { selected = index } } label: {
                            VStack(spacing: 7) {
                                Capsule().fill(selected == index ? Color.black.opacity(0.6) : Color.black.opacity(0.15))
                                    .frame(width: selected == index ? 18 : 6, height: 4)
                                Text(index < restaurants.count ? restaurants[index].name : "餐馆 \(index + 1)")
                                    .font(.system(size: 10)).lineLimit(1).frame(maxWidth: 90)
                            }.foregroundStyle(selected == index ? .primary : .secondary).padding(.vertical, 7)
                        }.buttonStyle(.plain).accessibilityIdentifier("restaurant.page.\(index)")
                    }
                }.frame(minWidth: 280)
            }
            Text("左右滑动切换餐馆 · 点击卡片查看近 7 天人数").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .onChange(of: restaurants.map(\.id)) { _, _ in selected = 0 }
        .sheet(isPresented: $configure) { AppSettingsView().environmentObject(connections) }
        .accessibilityIdentifier("restaurant.carousel")
    }
}

struct RestaurantHomePage: View {
    @EnvironmentObject private var connections: RestaurantConnections
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var monitor = RestaurantMonitor()
    @State private var detail = false
    let connection: RestaurantConnection
    let refreshToken: UUID
    var body: some View {
        Button { detail = true } label: {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(connection.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Spacer()
                    if monitor.loading { ProgressView().controlSize(.mini) }
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11))
                }
                HStack(alignment: .top, spacing: 24) {
                    metric("今日开台", value: monitor.todayOpenedCount.map(String.init) ?? "—")
                    metric("当前开台", value: monitor.status?.tables?.openCount.map(String.init) ?? "—")
                }
                Spacer(minLength: 0)
                if let error = monitor.error ?? monitor.historyError {
                    Text(error).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                } else if let date = monitor.lastRefresh {
                    HStack { Text(date, style: .time); Text("更新 · 近 7 天人数"); Spacer(); Image(systemName: "chevron.right") }
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("正在读取餐馆数据…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(LinearGradient(colors: [Color(white: 0.82), Color(white: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.8), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.10), radius: 6, y: 4).padding(.vertical, 6)
        }.buttonStyle(.plain).accessibilityIdentifier("restaurant.home.\(connection.id)")
            .sheet(isPresented: $detail) { RestaurantHistorySheet(connection: connection, monitor: monitor) }
            .task(id: "\(connections.revision)|\(refreshToken)|\(scenePhase == .active)") {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await monitor.refresh(connection)
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline).foregroundStyle(.primary)
            Text(value).font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title).accessibilityValue(value == "—" ? "暂无数据" : value)
    }
}

struct RestaurantHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let connection: RestaurantConnection
    @ObservedObject var monitor: RestaurantMonitor
    private var total: Int { monitor.history.compactMap(\.guests).reduce(0, +) }
    private var knownDays: Int { monitor.history.filter { $0.guests != nil }.count }
    private var segments: [Int] {
        var segment = 0
        return monitor.history.map { day in if day.guests == nil { segment += 1 }; return segment }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("近 7 天用餐人数").font(.system(size: 29, design: .serif))
                    if let first = monitor.history.first, let last = monitor.history.last {
                        Text("\(first.date) — \(last.date)").font(.subheadline).foregroundStyle(.secondary)
                    } else { Text("等待服务器返回日期和人数").font(.subheadline).foregroundStyle(.secondary) }
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(knownDays == 0 ? "—" : String(total)).font(.system(size: 56, design: .serif))
                        Text("人 · \(knownDays) 天有记录").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("每日累计用餐人数，包含已经结束用餐的客人。").font(.caption).foregroundStyle(.secondary)
                    Chart(Array(monitor.history.enumerated()), id: \.element.date) { index, day in
                        if let count = day.guests {
                            LineMark(x: .value("日期", day.shortDate), y: .value("人数", count), series: .value("连续记录", segments[index]))
                                .foregroundStyle(Color(red: 0.40, green: 0.52, blue: 0.45)).lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(x: .value("日期", day.shortDate), y: .value("人数", count))
                                .foregroundStyle(Color(red: 0.40, green: 0.52, blue: 0.45)).symbolSize(35)
                                .annotation(position: .top) { Text("\(count)").font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                    }
                    .chartXScale(domain: monitor.history.map(\.shortDate))
                    .chartYScale(domain: 0...max(10, (monitor.history.compactMap(\.guests).max() ?? 0) + 5))
                    .chartXAxis { AxisMarks(values: monitor.history.map(\.shortDate)) }
                    .frame(height: 230).padding(.vertical, 10)
                    .overlay { if knownDays == 0 { Text("暂无可读取的历史人数").font(.footnote).foregroundStyle(.secondary) } }
                    .accessibilityIdentifier("restaurant.history.chart")
                    VStack(spacing: 0) {
                        ForEach(monitor.history) { day in
                            HStack {
                                Text(day.date).font(.system(size: 15, design: .serif))
                                Spacer()
                                Text(day.guests.map { "\($0) 人" } ?? "暂无记录").font(.system(size: 15))
                            }.padding(.vertical, 12)
                            if day.missing ?? 0 > 0 { Text("另有 \(day.missing ?? 0) 桌未登记人数").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing) }
                            if day.id != monitor.history.last?.id { Divider().opacity(0.35) }
                        }
                    }.padding(.horizontal, 18).background(.white.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 24))
                    Text(monitor.historyNote).font(.caption).foregroundStyle(.secondary)
                    if let error = monitor.error { Text("当前数据更新失败：\(error)").font(.caption).foregroundStyle(.secondary) }
                    Button("刷新餐馆数据") { Task { await monitor.refresh(connection) } }.disabled(monitor.loading)
                }.padding(24)
            }
            .background(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.89)], startPoint: .top, endPoint: .bottom))
            .navigationTitle(connection.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDragIndicator(.visible)
    }
}
