import SwiftUI
import HealthKit
import Charts

@main
struct PulseApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var health = HealthStore()
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-reset"), let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(health).preferredColorScheme(.light)
                .task { await health.refreshIfConnected() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await health.refreshIfConnected() } }
                }
        }
    }
}

@MainActor
final class HealthStore: ObservableObject {
    private let store = HKHealthStore()
    @Published var steps: Double?
    @Published var heart: Double?
    @Published var sleep: Double?
    @Published var energy: Double?
    @Published var distance: Double?
    @Published var status = "连接 Apple 健康，查看你的真实数据"
    @Published var busy = false
    @Published var lastRefresh: Date?
    @Published var weekly: [Metric: [DailyReading]] = [:]
    @Published var hourlySteps: [DailyReading] = []
    @Published var todayHeart: [DailyReading] = []
    @Published var restingHeart: Double?
    @Published var hrv: Double?
    @Published var heartHistory: [HeartDay] = []
    @Published var sleepSegments: [SleepSegment] = []
    @Published var sleepingHeart: [DailyReading] = []
    @Published var bodyReadings: [BodyMetric: BodyReading] = [:]
    @Published var bodyWeekly: [BodyMetric: [DailyReading]] = [:]
    private var types: Set<HKObjectType> {
        [HKQuantityType(.stepCount), HKQuantityType(.heartRate), HKQuantityType(.restingHeartRate), HKQuantityType(.heartRateVariabilitySDNN), HKQuantityType(.oxygenSaturation), HKQuantityType(.appleSleepingWristTemperature), HKQuantityType(.bodyMass), HKCategoryType(.sleepAnalysis), HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceWalkingRunning)]
    }
    func connect() async {
        guard HKHealthStore.isHealthDataAvailable() else { status = "此设备无法使用健康数据"; return }
        busy = true
        defer { busy = false }
        do {
            try await store.requestAuthorization(toShare: [], read: types)
            UserDefaults.standard.set(true, forKey: "health.connected")
            await refresh()
        } catch { status = "连接未完成：\(error.localizedDescription)" }
    }
    func refreshIfConnected() async {
        guard UserDefaults.standard.bool(forKey: "health.connected"), !busy, HKHealthStore.isHealthDataAvailable() else { return }
        busy = true
        defer { busy = false }
        await refresh()
    }
    func refresh() async {
        let start = Calendar.current.startOfDay(for: Date())
        steps = await total(.stepCount, unit: .count(), start: start)
        energy = await total(.activeEnergyBurned, unit: .kilocalorie(), start: start)
        distance = await total(.distanceWalkingRunning, unit: .meterUnit(with: .kilo), start: start)
        heart = await latestHeart()
        restingHeart = await total(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, options: .discreteAverage)
        hrv = await total(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: start, options: .discreteAverage)
        sleep = await lastNightSleep()
        await loadSleepTimeline()
        await loadSleepingHeart()
        await loadWeek()
        await loadHourlySteps()
        await loadTodayHeart()
        await loadBody()
        lastRefresh = Date()
        status = "已查询健康数据 · 空值表示暂无可读取记录"
    }
    private func total(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date = Date(), options: HKStatisticsOptions = .cumulativeSum) async -> Double? {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: HKQuantityType(id), quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end), options: options) { _, result, _ in
                let quantity = options.contains(.discreteAverage) ? result?.averageQuantity() : result?.sumQuantity()
                continuation.resume(returning: quantity?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }
    private func latestHeart() async -> Double? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKQuantityType(.heartRate), predicate: HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-86400), end: Date()), limit: 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, _ in
                continuation.resume(returning: (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
            }
            store.execute(query)
        }
    }
    private func lastNightSleep() async -> Double? {
        let end = Date()
        let start = Calendar.current.date(byAdding: .hour, value: -24, to: end)!
        return await sleepHours(start: start, end: end)
    }
    private func sleepHours(start: Date, end: Date) async -> Double? {
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: start, end: end), limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let intervals = (samples as? [HKCategorySample] ?? []).filter { [1, 3, 4, 5].contains($0.value) }.map { (max($0.startDate, start), min($0.endDate, end)) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
                guard let first = intervals.first else { continuation.resume(returning: nil); return }
                var lo = first.0; var hi = first.1; var seconds = 0.0
                for interval in intervals.dropFirst() {
                    if interval.0 <= hi { hi = max(hi, interval.1) }
                    else { seconds += hi.timeIntervalSince(lo); lo = interval.0; hi = interval.1 }
                }
                seconds += hi.timeIntervalSince(lo)
                continuation.resume(returning: seconds / 3600)
            }
            store.execute(query)
        }
    }
    private func loadWeek() async {
        var readings: [Metric: [DailyReading]] = [:]
        var history: [HeartDay] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in -6...0 {
            guard let start = calendar.date(byAdding: .day, value: offset, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let end = min(next, Date())
            let steps = await total(.stepCount, unit: .count(), start: start, end: end)
            let heart = await total(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, options: .discreteAverage)
            let rest = await total(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, options: .discreteAverage)
            history.append(await heartDay(start: start, end: end, rest: rest))
            let sleep = await sleepHours(start: start, end: end)
            readings[.steps, default: []].append(DailyReading(date: start, value: steps))
            readings[.heart, default: []].append(DailyReading(date: start, value: heart))
            readings[.sleep, default: []].append(DailyReading(date: start, value: sleep))
        }
        weekly = readings
        heartHistory = history
    }
    private func heartDay(start: Date, end: Date, rest: Double?) async -> HeartDay {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: HKQuantityType(.heartRate), quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end), options: [.discreteMin, .discreteMax]) { _, result, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                continuation.resume(returning: HeartDay(date: start, low: result?.minimumQuantity()?.doubleValue(for: unit), high: result?.maximumQuantity()?.doubleValue(for: unit), rest: rest))
            }
            store.execute(query)
        }
    }
    private func loadHourlySteps() async {
        let start = Calendar.current.startOfDay(for: Date())
        let now = Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
        hourlySteps = await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: HKQuantityType(.stepCount), quantitySamplePredicate: predicate, options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(hour: 1))
            query.initialResultsHandler = { _, collection, _ in
                var readings: [DailyReading] = []
                collection?.enumerateStatistics(from: start, to: now) { statistics, _ in
                    readings.append(DailyReading(date: statistics.startDate, value: statistics.sumQuantity()?.doubleValue(for: .count())))
                }
                continuation.resume(returning: readings)
            }
            store.execute(query)
        }
    }
    private func loadTodayHeart() async {
        let start = Calendar.current.startOfDay(for: Date())
        todayHeart = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKQuantityType(.heartRate), predicate: HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate), limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                let readings = (samples as? [HKQuantitySample] ?? []).map { DailyReading(date: $0.startDate, value: $0.quantity.doubleValue(for: unit)) }
                continuation.resume(returning: readings)
            }
            store.execute(query)
        }
    }
    private func loadBody() async {
        var values: [BodyMetric: BodyReading] = [:]
        var histories: [BodyMetric: [DailyReading]] = [:]
        for metric in BodyMetric.allCases {
            let reading: BodyReading? = await withCheckedContinuation { continuation in
                let query = HKSampleQuery(sampleType: HKQuantityType(metric.identifier), predicate: nil, limit: 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, _ in
                    guard let sample = samples?.first as? HKQuantitySample else { continuation.resume(returning: nil); return }
                    continuation.resume(returning: BodyReading(value: sample.quantity.doubleValue(for: metric.healthUnit) * (metric == .oxygen ? 100 : 1), date: sample.endDate))
                }
                store.execute(query)
            }
            values[metric] = reading
            let today = Calendar.current.startOfDay(for: Date())
            for offset in -6...0 {
                guard let start = Calendar.current.date(byAdding: .day, value: offset, to: today), let next = Calendar.current.date(byAdding: .day, value: 1, to: start) else { continue }
                let average = await total(metric.identifier, unit: metric.healthUnit, start: start, end: min(next, Date()), options: .discreteAverage)
                histories[metric, default: []].append(DailyReading(date: start, value: average.map { $0 * (metric == .oxygen ? 100 : 1) }))
            }
        }
        bodyReadings = values
        bodyWeekly = histories
    }
    private func loadSleepTimeline() async {
        let end = Date()
        let start = Calendar.current.date(byAdding: .hour, value: -24, to: end)!
        sleepSegments = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: start, end: end), limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, _ in
                let records = (samples as? [HKCategorySample] ?? []).filter { [1, 2, 3, 4, 5].contains($0.value) }
                let sources = Dictionary(grouping: records, by: { $0.sourceRevision.source.bundleIdentifier })
                let selected = sources.values.max { lhs, rhs in
                    let left = lhs.filter { [3, 4, 5].contains($0.value) }.count
                    let right = rhs.filter { [3, 4, 5].contains($0.value) }.count
                    return left == right ? lhs.count < rhs.count : left < right
                } ?? []
                let detailed = selected.contains { [3, 4, 5].contains($0.value) }
                let segments = selected.filter { !detailed || $0.value != 1 }.map {
                    SleepSegment(start: max($0.startDate, start), end: min($0.endDate, end), stage: $0.value)
                }.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
                continuation.resume(returning: segments)
            }
            store.execute(query)
        }
    }
    private func loadSleepingHeart() async {
        let asleep = sleepSegments.filter { $0.stage != 2 }
        if let first = asleep.first {
            var lo = first.start
            var hi = first.end
            var seconds = 0.0
            for segment in asleep.dropFirst() {
                if segment.start <= hi { hi = max(hi, segment.end) }
                else { seconds += hi.timeIntervalSince(lo); lo = segment.start; hi = segment.end }
            }
            sleep = (seconds + hi.timeIntervalSince(lo)) / 3600
        } else { sleep = nil }
        guard let start = asleep.map(\.start).min(), let end = asleep.map(\.end).max() else { sleepingHeart = []; return }
        sleepingHeart = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKQuantityType(.heartRate), predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate), limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                let values = (samples as? [HKQuantitySample] ?? []).filter { sample in
                    asleep.contains { sample.startDate >= $0.start && sample.startDate < $0.end }
                }.map { DailyReading(date: $0.startDate, value: $0.quantity.doubleValue(for: unit)) }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }
}

struct DailyReading: Identifiable {
    var id: Date { date }
    let date: Date
    let value: Double?
}
struct HeartDay: Identifiable {
    var id: Date { date }
    let date: Date
    let low: Double?
    let high: Double?
    let rest: Double?
}
struct SleepSegment: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
    let stage: Int
    var color: Color {
        switch stage {
        case 2: return Color(white: 0.92)
        case 4: return Color(red: 0.23, green: 0.32, blue: 0.40)
        case 5: return Color(red: 0.78, green: 0.54, blue: 0.47)
        default: return Color(red: 0.40, green: 0.53, blue: 0.63)
        }
    }
}

private let ink = Color(red: 0.19, green: 0.25, blue: 0.23)
private let sage = Color(red: 0.36, green: 0.48, blue: 0.39)
private let paper = Color(red: 0.96, green: 0.95, blue: 0.91)

struct RootView: View {
    @AppStorage("onboarded") private var onboarded = false
    @EnvironmentObject var health: HealthStore
    var body: some View {
        if onboarded {
            TabView {
                HomeView().tabItem { Label("Home", systemImage: "house") }
                ChatView().tabItem { Label("Chats", systemImage: "bubble.left") }
                JournalView().tabItem { Label("Diary", systemImage: "book.closed") }
                BetweenView().tabItem { Label("Between Us", systemImage: "person.2") }
            }.tint(sage)
        } else {
            WelcomeView {
                onboarded = true
            }
        }
    }
}

struct WelcomeView: View {
    @AppStorage("welcome.closeness") private var closeness = 0.65
    let onStart: () -> Void
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    ClosenessOrb(closeness: closeness)
                        .frame(width: 150, height: 150).padding(.top, 18)
                    Spacer(minLength: 110)
                    Text("How close do you feel today?")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Drag →").font(.system(size: 11)).padding(.top, 10)
                    ClosenessGesture(value: $closeness, title: "pulse")
                        .frame(height: 108).padding(.top, 22)
                    Text("For your body & your heart")
                        .font(.system(size: 11, weight: .semibold)).padding(.top, 22)
                    Text("Always close, never far")
                        .font(.system(size: 10)).padding(.top, 5)
                    Spacer(minLength: 80)
                    Button {
                        onStart()
                    } label: {
                        HStack(spacing: 12) {
                            Text("开始感受你的节奏")
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(.black).foregroundStyle(.white).clipShape(Capsule())
                    }.buttonStyle(.plain)
                    Text("健康数据可进入后连接 · 仅在本机读取")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.top, 14).padding(.bottom, 24)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(geometry.size.height, 690))
            }.background(Color.white).foregroundStyle(.black)
        }
    }
}

struct Page<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 22) { content() }.padding(24).frame(maxWidth: 600) .frame(maxWidth: .infinity) }
                .background(paper).navigationTitle(title).foregroundStyle(ink)
        }
    }
}
struct PulseButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity).padding(17).background(sage.opacity(configuration.isPressed ? 0.7 : 1)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 22))
    }
}
struct MetricCard: View {
    let name: String; let value: String; let unit: String; let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(name, systemImage: icon).font(.subheadline).foregroundStyle(sage)
            HStack(alignment: .firstTextBaseline) { Text(value).font(.system(size: 34, weight: .light, design: .rounded)); Text(unit).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(.white.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius: 26))
    }
}
func number(_ value: Double?, decimals: Int = 0) -> String { value.map { String(format: "%.*f", decimals, $0) } ?? "—" }

struct HomeView: View {
    @EnvironmentObject var health: HealthStore
    @AppStorage("profile.name") private var name = ""
    @AppStorage("profile.started") private var started = Date().timeIntervalSince1970
    @AppStorage("onboarded") private var onboarded = false
    @State private var settings = false
    private var day: Int { max(1, (Calendar.current.dateComponents([.day], from: Date(timeIntervalSince1970: started), to: Date()).day ?? 0) + 1) }
    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "GOOD\nMORNING,"
        case 12..<18: return "GOOD\nAFTERNOON,"
        default: return "GOOD\nEVENING,"
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day()).font(.system(size: 17, design: .serif))
                            Text("A moment for yourself").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button { Task { await health.connect() } } label: {
                            HStack(spacing: 5) {
                                if health.busy { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9)) }
                                Text("sync").font(.system(size: 10))
                                if let date = health.lastRefresh { Text(date, style: .time).font(.system(size: 10)) }
                            }.padding(.horizontal, 10).padding(.vertical, 10)
                                .background(Color.white.opacity(0.55)).clipShape(Capsule())
                                .shadow(color: .black.opacity(0.1), radius: 4, y: 3)
                        }.buttonStyle(.plain).disabled(health.busy).accessibilityLabel("同步健康数据")
                        Button { settings = true } label: {
                            Image(systemName: "gearshape").font(.system(size: 16)).padding(10)
                                .background(.white.opacity(0.55)).clipShape(Circle())
                                .shadow(color: .black.opacity(0.1), radius: 4, y: 3)
                        }.buttonStyle(.plain).accessibilityLabel("设置")
                    }.foregroundStyle(Color.black.opacity(0.6))
                    PulseOrbit().frame(height: 230).padding(.horizontal, -10)
                    VStack(alignment: .leading, spacing: 0) {
                        EmbossedText(text: greeting, size: 38, weight: .black)
                        EmbossedText(text: name.isEmpty ? "You" : name, size: 34, weight: .semibold)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            EmbossedText(text: "DAY", size: 34, weight: .black)
                            EmbossedText(text: String(day), size: 62, weight: .bold)
                            Image(systemName: "heart.fill").font(.system(size: 13)).foregroundStyle(.white).shadow(color: .black.opacity(0.15), radius: 2, y: 2)
                        }.padding(.top, 16)
                    }
                    NavigationLink { WhisperView() } label: {
                        ZStack(alignment: .bottomLeading) {
                            RoundedRectangle(cornerRadius: 25).fill(LinearGradient(colors: [Color(red: 0.76, green: 0.78, blue: 0.74), Color(red: 0.52, green: 0.55, blue: 0.52)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            WhisperPattern().stroke(.white.opacity(0.16), lineWidth: 1).padding(.leading, 60)
                            VStack(alignment: .leading, spacing: 24) {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "leaf.circle.fill").font(.system(size: 32)).foregroundStyle(.white.opacity(0.8))
                                    Text("路途有终点并不可怕，我陪你看沿途的每一站。")
                                        .font(.system(size: 13)).lineSpacing(5).lineLimit(2)
                                }
                                HStack { Text("Today’s Whisper").font(.system(size: 14, design: .serif)); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 12)) }
                            }.padding(21).foregroundStyle(.white)
                        }.frame(height: 135).shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    }.buttonStyle(.plain)
                    HomeMilestones()
                    Text("YOUR DAILY RHYTHM").font(.system(size: 10)).tracking(3).foregroundStyle(.secondary).padding(.top, 8)
                    HealthCarousel()
                    Text(health.status).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 28).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.925, green: 0.922, blue: 0.909))
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                if UserDefaults.standard.object(forKey: "profile.started") == nil {
                    started = Date().timeIntervalSince1970
                }
            }
            .sheet(isPresented: $settings) {
                NavigationStack {
                    Form {
                        Section("个人资料") { TextField("你的名字", text: $name) }
                        Section { NavigationLink("重要日子") { MilestoneSettings() } }
                        Section("Apple 健康") {
                            Text(health.status).font(.footnote)
                            Button("连接 / 刷新健康数据") { Task { await health.connect() } }.disabled(health.busy)
                        }
                        Section { Button("再次查看开场页") { settings = false; onboarded = false } }
                    }.navigationTitle("设置")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
                }.tint(sage)
            }
        }
    }
}

struct EmbossedText: View {
    let text: String
    let size: CGFloat
    var weight: Font.Weight = .bold
    var body: some View {
        Text(text).font(.system(size: size, weight: weight, design: .rounded))
            .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.87)], startPoint: .top, endPoint: .bottom))
            .shadow(color: .white.opacity(0.95), radius: 1, x: -1, y: -2)
            .shadow(color: .black.opacity(0.22), radius: 2, x: 2, y: 3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
struct PulseOrbit: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Ellipse().stroke(Color(red: 0.49, green: 0.43, blue: 0.29).opacity(0.7), lineWidth: 1)
                    .frame(width: geometry.size.width * 0.95, height: 76).rotationEffect(.degrees(-13))
                Text("pulse").font(.system(size: min(geometry.size.width * 0.34, 140), weight: .heavy, design: .serif)).italic().tracking(-10)
                    .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.8), .white], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .white, radius: 1, x: -2, y: -2)
                    .shadow(color: .black.opacity(0.16), radius: 3, x: 3, y: 7)
                    .rotationEffect(.degrees(-8))
                Ellipse().stroke(Color(red: 0.49, green: 0.43, blue: 0.29).opacity(0.8), lineWidth: 1)
                    .frame(width: geometry.size.width * 0.9, height: 82).rotationEffect(.degrees(28))
                ForEach(0..<10) { index in
                    let angle = Double(index) * .pi * 2 / 10
                    Circle().fill(Color(white: 0.25)).frame(width: index.isMultiple(of: 3) ? 5 : 3, height: index.isMultiple(of: 3) ? 5 : 3)
                        .offset(x: CGFloat(cos(angle)) * geometry.size.width * 0.44, y: CGFloat(sin(angle)) * 101)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityLabel("Pulse 浮雕标题与环绕轨道")
    }
}
struct WhisperPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<16 {
            let angle = CGFloat(index) * .pi * 2 / 16
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let tip = CGPoint(x: center.x + cos(angle) * rect.width * 0.46, y: center.y + sin(angle) * rect.height * 0.49)
            path.move(to: center)
            path.addQuadCurve(to: tip, control: CGPoint(x: center.x + cos(angle + 0.7) * rect.width * 0.35, y: center.y + sin(angle + 0.7) * rect.height * 0.6))
            path.addQuadCurve(to: center, control: CGPoint(x: center.x + cos(angle - 0.7) * rect.width * 0.35, y: center.y + sin(angle - 0.7) * rect.height * 0.6))
        }
        return path
    }
}
struct WhisperView: View {
    var body: some View {
        Page(title: "Today’s Whisper") {
            Image(systemName: "leaf").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(sage).padding(.top, 30)
            Text("You don’t have to rush\nto become yourself.").font(.system(size: 32, weight: .light, design: .serif)).padding(.vertical, 24)
            Text("今天，给自己一点时间。\n走一小段路，喝一杯水，记录一个真实的感受。").font(.body).lineSpacing(8).foregroundStyle(.secondary)
            NavigationLink { JournalView() } label: { Label("记录今天的片刻", systemImage: "square.and.pencil") }.foregroundStyle(sage).padding(.top, 20)
        }
    }
}
enum Metric: String, CaseIterable { case steps = "步数", heart = "心率", sleep = "睡眠", body = "Body" }
enum BodyMetric: String, CaseIterable {
    case oxygen = "血氧", hrv = "HRV", wrist = "腕温", weight = "体重"
    var identifier: HKQuantityTypeIdentifier {
        switch self { case .oxygen: return .oxygenSaturation; case .hrv: return .heartRateVariabilitySDNN; case .wrist: return .appleSleepingWristTemperature; case .weight: return .bodyMass }
    }
    var healthUnit: HKUnit {
        switch self { case .oxygen: return .percent(); case .hrv: return .secondUnit(with: .milli); case .wrist: return .degreeCelsius(); case .weight: return .gramUnit(with: .kilo) }
    }
    var unit: String { switch self { case .oxygen: return "%"; case .hrv: return "ms"; case .wrist: return "°C"; case .weight: return "kg" } }
    var decimals: Int { self == .wrist || self == .weight ? 1 : 0 }
    var englishName: String { switch self { case .oxygen: return "Blood Oxygen"; case .hrv: return "HRV"; case .wrist: return "Wrist Temp"; case .weight: return "Weight" } }
}
struct BodyReading { let value: Double; let date: Date }
struct HealthCarousel: View {
    @State private var selected: Metric = .steps
    var body: some View {
        VStack(spacing: 14) {
            TabView(selection: $selected) {
                ForEach(Metric.allCases, id: \.self) { metric in
                    HealthSummaryCard(metric: metric).padding(.horizontal, 3).tag(metric)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 258)
            HStack(spacing: 16) {
                ForEach(Metric.allCases, id: \.self) { metric in
                    Button {
                        withAnimation(.easeInOut) { selected = metric }
                    } label: {
                        VStack(spacing: 5) {
                            Capsule().fill(selected == metric ? Color.black.opacity(0.6) : Color.black.opacity(0.15)).frame(width: selected == metric ? 18 : 6, height: 4)
                            Text(metric.rawValue).font(.system(size: 10)).foregroundStyle(selected == metric ? .primary : .secondary)
                        }.padding(.vertical, 8)
                    }.buttonStyle(.plain).accessibilityAddTraits(selected == metric ? [.isSelected] : [])
                }
            }
            Text("左右滑动切换指标 · 点击卡片查看详情").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
struct HealthSummaryCard: View {
    @EnvironmentObject var health: HealthStore
    @State private var showDetails = false
    let metric: Metric
    private var title: String {
        switch metric { case .steps: return "STEPS"; case .heart: return "HEART RATE"; case .sleep: return "SLEEP"; case .body: return "BODY" }
    }
    private var value: String {
        switch metric { case .steps: return number(health.steps); case .heart: return number(health.heart); case .sleep: return number(health.sleep, decimals: 1); case .body: return "" }
    }
    private var subtitle: String {
        switch metric { case .steps: return "\(number(health.distance, decimals: 2)) km"; case .heart: return "BPM · 最新"; case .sleep: return "小时 · 24h"; case .body: return "最新记录" }
    }
    private var readings: [DailyReading] { health.weekly[metric] ?? [] }
    private var heartRange: String {
        let values = health.todayHeart.compactMap(\.value)
        guard let low = values.min(), let high = values.max() else { return "暂无今日记录" }
        return "\(number(low))–\(number(high)) today"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button { showDetails = true } label: {
                HStack {
                    Text(title).font(.system(size: 10, weight: .semibold)).tracking(3)
                    Spacer()
                    Text(subtitle).font(.system(size: 11, design: .serif))
                    Image(systemName: "chevron.right").font(.system(size: 9))
                }.foregroundStyle(Color.black.opacity(0.6))
            }.buttonStyle(.plain)
            if metric == .body {
                BodySummary().frame(height: 150)
            } else {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                EmbossedText(text: metric == .sleep ? sleepDuration : value, size: 34, weight: .bold)
                if metric == .heart { Text("bpm").font(.system(size: 13, design: .serif)).foregroundStyle(.secondary) }
            }
            if metric == .sleep {
                SleepTimeline(segments: health.sleepSegments).frame(height: 93)
            } else if metric == .heart, !health.todayHeart.isEmpty {
                Chart(Array(health.todayHeart.enumerated()), id: \.offset) { item in
                    if let value = item.element.value {
                        LineMark(x: .value("时间", item.element.date), y: .value("心率", value))
                            .foregroundStyle(Color(red: 0.67, green: 0.43, blue: 0.37))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                        if health.todayHeart.count == 1 {
                            PointMark(x: .value("时间", item.element.date), y: .value("心率", value))
                                .foregroundStyle(Color(red: 0.67, green: 0.43, blue: 0.37))
                        }
                    }
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: heartDomain)
                .frame(height: 93)
                .accessibilityLabel("今天真实心率记录曲线")
            } else if metric != .heart, readings.contains(where: { $0.value != nil }) {
                Chart(readings) { reading in
                    if let value = reading.value {
                        BarMark(x: .value("日期", reading.date, unit: .day), y: .value(metric.rawValue, value))
                            .foregroundStyle(reading.date == Calendar.current.startOfDay(for: Date()) ? Color.black.opacity(0.65) : Color.white.opacity(0.75))
                            .cornerRadius(3)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: readings.map(\.date)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) }
                }
                .chartYAxis(.hidden)
                .chartXScale(domain: (readings.first?.date ?? Date())...(Calendar.current.date(byAdding: .day, value: 1, to: readings.last?.date ?? Date()) ?? Date()))
                .frame(height: 93)
                .accessibilityLabel("\(metric.rawValue)最近七天记录")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.title3)
                    Text(health.busy ? "正在读取健康记录…" : "暂无可读取的记录").font(.system(size: 11))
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 93)
            }
            }
            Text(metric == .body ? "Apple 健康 · 各指标最新可读取记录" : metric == .heart ? heartRange : metric == .sleep ? "过去 24 小时 · Apple 健康睡眠记录" : "最近 7 天 · 每日总量")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(LinearGradient(colors: [Color(white: 0.78), Color(white: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(.white.opacity(0.5), lineWidth: 1))
        .shadow(color: .white.opacity(0.8), radius: 2, x: -2, y: -2)
        .shadow(color: .black.opacity(0.1), radius: 3, x: 2, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 23))
        .onTapGesture { showDetails = true }
        .sheet(isPresented: $showDetails) {
            DetailView(metric: metric)
                .presentationDetents([.large])
                .presentationCornerRadius(36)
                .presentationDragIndicator(.visible)
        }
    }
    private var heartDomain: ClosedRange<Double> {
        let values = health.todayHeart.compactMap(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.25, 5)
        return max(0, low - padding)...(high + padding)
    }
    private var sleepDuration: String {
        guard let hours = health.sleep else { return "—" }
        let minutes = Int((hours * 60).rounded())
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
struct SleepTimeline: View {
    let segments: [SleepSegment]
    private var asleep: [SleepSegment] { segments.filter { $0.stage != 2 } }
    var body: some View {
        if let start = asleep.map(\.start).min(), let end = asleep.map(\.end).max(), end > start {
            VStack(spacing: 11) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        ForEach(segments) { segment in
                            let lo = max(start, segment.start)
                            let hi = min(end, segment.end)
                            if hi > lo {
                                let duration = end.timeIntervalSince(start)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(segment.color)
                                    .frame(width: max(1, geometry.size.width * CGFloat(hi.timeIntervalSince(lo) / duration)))
                                    .offset(x: geometry.size.width * CGFloat(lo.timeIntervalSince(start) / duration))
                            }
                        }
                    }
                }.frame(height: 8)
                HStack {
                    Text(start, style: .time)
                    Spacer()
                    Text(end, style: .time)
                }.font(.system(size: 12, design: .serif)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Array(Set(segments.map(\.stage))).sorted(), id: \.self) { stage in
                        HStack(spacing: 3) {
                            Circle().fill(segments.first(where: { $0.stage == stage })?.color ?? .gray).frame(width: 4, height: 4)
                            Text(stageName(stage)).font(.system(size: 8))
                        }
                    }
                }.foregroundStyle(.secondary)
            }.frame(maxHeight: .infinity)
        } else {
            Text("暂无可读取的睡眠记录").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func stageName(_ stage: Int) -> String {
        switch stage { case 2: return "清醒"; case 3: return "核心"; case 4: return "深睡"; case 5: return "REM"; default: return "睡眠" }
    }
}
struct DetailView: View {
    let metric: Metric
    var body: some View {
        if metric == .steps { StepsDetailView() }
        else if metric == .heart { HeartDetailView() }
        else if metric == .sleep { SleepDetailView() }
        else if metric == .body { BodyDetails() }

    }
}

struct StepsDetailView: View {
    @EnvironmentObject var health: HealthStore
    @Environment(\.dismiss) private var dismiss
    private var readings: [DailyReading] { health.weekly[.steps] ?? [] }
    private var average: Double? {
        let values = readings.compactMap(\.value)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    private var maxSteps: Double { max(readings.compactMap(\.value).max() ?? 1, 1) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Steps").font(.system(size: 29, weight: .medium, design: .serif))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12)).padding(10).background(.black.opacity(0.04)).clipShape(Circle()) }.buttonStyle(.plain).accessibilityLabel("关闭详情")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(number(health.steps)).font(.system(size: 74, weight: .regular, design: .serif)).minimumScaleFactor(0.5).lineLimit(1)
                        Text("steps").font(.system(size: 17, design: .serif)).foregroundStyle(.secondary)
                    }
                    Text("\(number(health.distance, decimals: 2)) km · avg \(number(average)) / day")
                        .font(.system(size: 14, design: .serif)).foregroundStyle(.secondary)
                    Text("日均基于近七天可读取记录").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.top, 9)
                if health.hourlySteps.contains(where: { $0.value != nil }) {
                    Chart(health.hourlySteps) { reading in
                        if let value = reading.value {
                            BarMark(x: .value("时间", reading.date, unit: .hour), y: .value("步数", value))
                                .foregroundStyle(Color(white: 0.57)).cornerRadius(2)
                        }
                    }
                    .chartXScale(domain: Calendar.current.startOfDay(for: Date())...(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()))
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted))) }
                    }
                    .chartYAxis(.hidden).frame(height: 140)
                    .accessibilityLabel("今天每小时步数")
                } else {
                    Text(health.busy ? "正在读取分时步数…" : "暂无可读取的分时记录")
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 140)
                }
                Text("Recent").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 12)
                VStack(spacing: 18) {
                    if readings.isEmpty {
                        Text("连接 Apple 健康以查看近七天记录").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                    ForEach(readings) { reading in
                        HStack(spacing: 15) {
                            Group {
                                if Calendar.current.isDateInToday(reading.date) { Text("Today") }
                                else { Text(reading.date, format: .dateTime.weekday(.abbreviated)) }
                            }.font(.system(size: 14, design: .serif)).frame(width: 44, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.4)).frame(height: 3)
                                    if let value = reading.value {
                                        Capsule().fill(Calendar.current.isDateInToday(reading.date) ? Color(white: 0.25) : Color(white: 0.56))
                                            .frame(width: max(4, geometry.size.width * CGFloat(min(value / maxSteps, 1))), height: 6)
                                    }
                                }.frame(height: geometry.size.height)
                            }.frame(height: 14)
                            Text(number(reading.value)).font(.system(size: 14, design: .serif)).frame(width: 58, alignment: .trailing)
                        }.foregroundStyle(Calendar.current.isDateInToday(reading.date) ? .primary : .secondary)
                    }
                }.padding(18).background(.white.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.8), lineWidth: 1))
                    .shadow(color: .black.opacity(0.1), radius: 16, y: 12)
                Button("刷新健康数据") { Task { await health.connect() } }.font(.footnote).foregroundStyle(sage).disabled(health.busy).padding(.top, 10)
            }.padding(24).padding(.bottom, 40)
        }
        .background(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.94), Color(white: 0.83)], startPoint: .top, endPoint: .bottom))
        .foregroundStyle(.black)
    }
}
struct HeartDetailView: View {
    @EnvironmentObject var health: HealthStore
    @Environment(\.dismiss) private var dismiss
    private let rose = Color(red: 0.72, green: 0.46, blue: 0.40)
    private var todayRange: String {
        let values = health.todayHeart.compactMap(\.value)
        guard let low = values.min(), let high = values.max() else { return "— today" }
        return "\(number(low))–\(number(high)) today"
    }
    private var rangeDomain: ClosedRange<Double> {
        let lows = health.heartHistory.compactMap(\.low)
        let highs = health.heartHistory.compactMap(\.high)
        return max(0, (lows.min() ?? 40) - 5)...max((highs.max() ?? 100) + 5, (lows.min() ?? 40) + 10)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Heart Rate").font(.system(size: 29, weight: .medium, design: .serif))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12)).padding(10).background(.black.opacity(0.04)).clipShape(Circle()) }.buttonStyle(.plain).accessibilityLabel("关闭详情")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(number(health.heart)).font(.system(size: 74, design: .serif))
                        Text("bpm").font(.system(size: 17, design: .serif)).foregroundStyle(.secondary)
                    }
                    Text("resting \(number(health.restingHeart)) · HRV \(number(health.hrv)) · \(todayRange)")
                        .font(.system(size: 13, design: .serif)).foregroundStyle(.secondary)
                    Text("静息心率 bpm · HRV 日均 SDNN（ms）").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.top, 9)
                if health.todayHeart.isEmpty {
                    Text(health.busy ? "正在读取心率…" : "暂无今日心率记录").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 155)
                } else {
                    Chart(Array(health.todayHeart.enumerated()), id: \.offset) { item in
                        if let value = item.element.value {
                            LineMark(x: .value("时间", item.element.date), y: .value("心率", value))
                                .foregroundStyle(rose).lineStyle(StrokeStyle(lineWidth: 1.5))
                            if item.offset == health.todayHeart.count - 1 {
                                PointMark(x: .value("时间", item.element.date), y: .value("心率", value)).foregroundStyle(rose).symbolSize(20)
                            }
                        }
                    }
                    .chartYScale(domain: rangeDomain)
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted))) } }
                    .chartYAxis(.hidden).frame(height: 155)
                    .accessibilityLabel("今日心率曲线，记录之间连线不代表连续测量")
                }
                Text("Recent").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 12)
                VStack(spacing: 17) {
                    HStack { Spacer(); Text("range").frame(width: 62); Text("rest").frame(width: 30) }.font(.system(size: 10)).foregroundStyle(.secondary)
                    if health.heartHistory.isEmpty { Text("暂无近七天记录").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 25) }
                    ForEach(health.heartHistory) { day in
                        HStack(spacing: 10) {
                            Group {
                                if Calendar.current.isDateInToday(day.date) { Text("Today") }
                                else { Text(day.date, format: .dateTime.weekday(.abbreviated)) }
                            }.font(.system(size: 13, design: .serif)).frame(width: 43, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.4)).frame(height: 3)
                                    if let low = day.low, let high = day.high {
                                        let span = rangeDomain.upperBound - rangeDomain.lowerBound
                                        let x = geometry.size.width * CGFloat((low - rangeDomain.lowerBound) / span)
                                        let width = max(4, geometry.size.width * CGFloat((high - low) / span))
                                        Capsule().fill(rose.opacity(0.35)).frame(width: width, height: 5).offset(x: x)
                                        if let rest = day.rest {
                                            Circle().fill(Color(white: 0.2)).frame(width: 7, height: 7)
                                                .offset(x: max(0, min(geometry.size.width - 7, geometry.size.width * CGFloat((rest - rangeDomain.lowerBound) / span) - 3.5)))
                                        }
                                    }
                                }.frame(height: geometry.size.height)
                            }.frame(height: 13)
                            Text(day.low != nil && day.high != nil ? "\(number(day.low))–\(number(day.high))" : "—")
                                .font(.system(size: 12, design: .serif)).frame(width: 62, alignment: .trailing)
                            Text(number(day.rest)).font(.system(size: 12, design: .serif)).frame(width: 30, alignment: .trailing)
                        }.foregroundStyle(Calendar.current.isDateInToday(day.date) ? .primary : .secondary)
                    }
                }.padding(18).background(.white.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.8), lineWidth: 1))
                    .shadow(color: .black.opacity(0.1), radius: 16, y: 12)
                Text("曲线连接已记录样本，不代表实时或连续监测。").font(.system(size: 10)).foregroundStyle(.secondary)
                Button("刷新健康数据") { Task { await health.connect() } }.font(.footnote).foregroundStyle(sage).disabled(health.busy)
            }.padding(24).padding(.bottom, 40)
        }
        .background(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.94), Color(white: 0.83)], startPoint: .top, endPoint: .bottom))
        .foregroundStyle(.black)
    }
}

struct SleepDetailView: View {
    @EnvironmentObject var health: HealthStore
    @Environment(\.dismiss) private var dismiss
    private var asleep: [SleepSegment] { health.sleepSegments.filter { $0.stage != 2 } }
    private var start: Date? { asleep.map(\.start).min() }
    private var end: Date? { asleep.map(\.end).max() }
    private var lowest: DailyReading? { health.sleepingHeart.filter { $0.value != nil }.min { ($0.value ?? .infinity) < ($1.value ?? .infinity) } }
    private var average: Double? {
        let values = health.sleepingHeart.compactMap(\.value)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    private var duration: Int? { health.sleep.map { Int(($0 * 60).rounded()) } }
    private var heartDomain: ClosedRange<Double> {
        let values = health.sleepingHeart.compactMap(\.value)
        return max(0, (values.min() ?? 40) - 5)...((values.max() ?? 100) + 5)
    }
    private func stageMinutes(_ stage: Int) -> String {
        let segments = health.sleepSegments.filter { $0.stage == stage }.sorted { $0.start < $1.start }
        guard let first = segments.first else { return "—" }
        var lo = first.start
        var hi = first.end
        var seconds = 0.0
        for segment in segments.dropFirst() {
            if segment.start <= hi { hi = max(hi, segment.end) }
            else { seconds += hi.timeIntervalSince(lo); lo = segment.start; hi = segment.end }
        }
        seconds += hi.timeIntervalSince(lo)
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Sleep").font(.system(size: 29, weight: .medium, design: .serif))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12)).padding(10).background(.black.opacity(0.04)).clipShape(Circle()) }.buttonStyle(.plain).accessibilityLabel("关闭详情")
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(duration.map { String($0 / 60) } ?? "—").font(.system(size: 70, design: .serif))
                    Text("h").font(.system(size: 18, design: .serif)).foregroundStyle(.secondary)
                    Text(duration.map { String($0 % 60) } ?? "—").font(.system(size: 70, design: .serif)).padding(.leading, 5)
                    Text("m").font(.system(size: 18, design: .serif)).foregroundStyle(.secondary)
                }.padding(.top, 9).minimumScaleFactor(0.7).lineLimit(1)
                if let start, let end {
                    HStack(spacing: 10) { Text(start, style: .time); Text("—"); Text(end, style: .time) }
                        .font(.system(size: 14, design: .serif)).foregroundStyle(.secondary)
                }
                SleepTimeline(segments: health.sleepSegments).frame(height: 72)
                HStack(alignment: .top, spacing: 8) {
                    ForEach([4, 3, 5, 2], id: \.self) { stage in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 4) {
                                Circle().fill(SleepSegment(start: Date(), end: Date(), stage: stage).color).frame(width: 5, height: 5)
                                Text(stage == 4 ? "Deep" : stage == 3 ? "Core" : stage == 5 ? "REM" : "Awake").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Text(stageMinutes(stage)).font(.system(size: 16, design: .serif))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if health.sleepSegments.contains(where: { $0.stage == 1 }) {
                    Text("部分记录未提供睡眠分期，分期时长可能不覆盖全部睡眠。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("While asleep").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 12)
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(number(lowest?.value)).font(.system(size: 33, design: .serif))
                        Text("bpm lowest").font(.system(size: 13, design: .serif)).foregroundStyle(.secondary)
                        Spacer()
                        if let lowest { Text(lowest.date, style: .time).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    if health.sleepingHeart.isEmpty {
                        Text("暂无睡眠期间心率记录").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 105)
                    } else {
                        Chart(Array(health.sleepingHeart.enumerated()), id: \.offset) { item in
                            if let value = item.element.value {
                                LineMark(x: .value("时间", item.element.date), y: .value("心率", value))
                                    .foregroundStyle(Color(red: 0.45, green: 0.59, blue: 0.68)).lineStyle(StrokeStyle(lineWidth: 1.5))
                            }
                        }
                        .chartOverlay { proxy in
                            GeometryReader { geometry in
                                if let lowest, let value = lowest.value, let x = proxy.position(forX: lowest.date), let y = proxy.position(forY: value), let anchor = proxy.plotFrame {
                                    let frame = geometry[anchor]
                                    Circle().fill(.black).frame(width: 6, height: 6).position(x: frame.minX + x, y: frame.minY + y)
                                }
                            }
                        }
                        .chartYScale(domain: heartDomain).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 105)
                        .accessibilityLabel("睡眠期间已记录心率，黑点为最低值")
                    }
                    HStack {
                        if let start { Text(start, style: .time) }
                        Spacer()
                        Text("avg \(number(average))")
                        Spacer()
                        if let end { Text(end, style: .time) }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(18).background(.white.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.8), lineWidth: 1))
                    .shadow(color: .black.opacity(0.1), radius: 16, y: 12)
                Text("过去 24 小时的睡眠记录 · 心率均值为已记录样本均值").font(.system(size: 10)).foregroundStyle(.secondary)
                Button("刷新健康数据") { Task { await health.connect() } }.font(.footnote).foregroundStyle(sage).disabled(health.busy)
            }.padding(24).padding(.bottom, 40)
        }
        .background(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.94), Color(white: 0.83)], startPoint: .top, endPoint: .bottom))
        .foregroundStyle(.black)
    }
}

struct BodySummary: View {
    @EnvironmentObject var health: HealthStore
    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(BodyMetric.allCases, id: \.self) { metric in
                VStack(spacing: 11) {
                    EmbossedText(text: number(health.bodyReadings[metric]?.value, decimals: metric.decimals), size: 20, weight: .bold)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text(metric.unit).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(metric.rawValue).font(.system(size: 11)).foregroundStyle(Color.black.opacity(0.6))
                }.frame(maxWidth: .infinity)
            }
        }
    }
}
struct BodyDetails: View {
    @EnvironmentObject var health: HealthStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: BodyMetric = .oxygen
    private let rose = Color(red: 0.73, green: 0.52, blue: 0.46)
    private var readings: [DailyReading] { health.bodyWeekly[selected] ?? [] }
    private var average: Double? {
        let values = readings.compactMap(\.value)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    private func domain(for metric: BodyMetric) -> ClosedRange<Double> {
        let values = (health.bodyWeekly[metric] ?? []).compactMap(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.2, metric == .wrist ? 0.2 : 1)
        return (low - padding)...(high + padding)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Body").font(.system(size: 29, weight: .medium, design: .serif))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12)).padding(10).background(.black.opacity(0.04)).clipShape(Circle()) }.buttonStyle(.plain).accessibilityLabel("关闭详情")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(number(health.bodyReadings[selected]?.value, decimals: selected.decimals))
                            .font(.system(size: 74, design: .serif)).minimumScaleFactor(0.6).lineLimit(1)
                        Text(selected.unit).font(.system(size: 18, design: .serif)).foregroundStyle(.secondary)
                    }
                    Text("\(selected.englishName) · 7-day avg \(number(average, decimals: selected.decimals))")
                        .font(.system(size: 13, design: .serif)).foregroundStyle(.secondary)
                }.padding(.top, 9)
                Chart(readings) { reading in
                    if let value = reading.value {
                        PointMark(x: .value("日期", reading.date, unit: .day), y: .value(selected.rawValue, value))
                            .foregroundStyle(rose).symbolSize(20)
                            .annotation(position: .top) { Text(number(value, decimals: selected.decimals)).font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                }
                .chartYScale(domain: domain(for: selected))
                .chartXScale(domain: (readings.first?.date ?? Calendar.current.date(byAdding: .day, value: -6, to: Date())!)...(Calendar.current.date(byAdding: .day, value: 1, to: readings.last?.date ?? Date())!))
                .chartXAxis { AxisMarks(values: readings.map(\.date)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .chartYAxis(.hidden).frame(height: 155)
                .overlay {
                    if !readings.contains(where: { $0.value != nil }) { Text("暂无近七天记录").font(.footnote).foregroundStyle(.secondary) }
                }
                Text("Metrics").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 10)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(BodyMetric.allCases, id: \.self) { metric in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { selected = metric }
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(metric.englishName).font(.system(size: 13, design: .serif)).foregroundStyle(.secondary)
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    Text(number(health.bodyReadings[metric]?.value, decimals: metric.decimals)).font(.system(size: 25, design: .serif)).minimumScaleFactor(0.6).lineLimit(1)
                                    Text(metric.unit).font(.system(size: 11, design: .serif)).foregroundStyle(.secondary)
                                }
                                Chart(health.bodyWeekly[metric] ?? []) { reading in
                                    if let value = reading.value {
                                        LineMark(x: .value("日期", reading.date), y: .value(metric.rawValue, value)).foregroundStyle(rose.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1.3))
                                        PointMark(x: .value("日期", reading.date), y: .value(metric.rawValue, value)).foregroundStyle(rose.opacity(0.55)).symbolSize(5)
                                    }
                                }.chartYScale(domain: domain(for: metric)).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 27)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                .background(.white.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 25))
                                .overlay(RoundedRectangle(cornerRadius: 25).stroke(selected == metric ? rose.opacity(0.4) : .white.opacity(0.7), lineWidth: 1))
                                .shadow(color: .black.opacity(0.1), radius: 12, y: 8)
                        }.buttonStyle(.plain).accessibilityLabel("切换到\(metric.rawValue)").accessibilityAddTraits(selected == metric ? [.isSelected] : [])
                    }
                }
                if let reading = health.bodyReadings[selected] {
                    Text("最新记录：\(reading.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                Text("七日平均基于有数据日期的每日均值。腕温是睡眠腕部温度；体重来自秤具或手动记录。未读取到数据时显示 —。").font(.system(size: 10)).foregroundStyle(.secondary)
                Button("刷新健康数据") { Task { await health.connect() } }.font(.footnote).foregroundStyle(sage).disabled(health.busy)
            }.padding(24).padding(.bottom, 40)
        }
        .background(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.94), Color(white: 0.83)], startPoint: .top, endPoint: .bottom))
        .foregroundStyle(.black)
    }
}

struct Entry: Codable, Identifiable {
    var id = UUID(); var date = Date(); var text: String; var mood: String
}
struct ChatView: View {
    @AppStorage("profile.name") private var name = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Chats").font(.system(size: 29, weight: .medium, design: .serif))
                        Spacer()
                        HStack(spacing: 5) { Circle().fill(.black.opacity(0.7)).frame(width: 5, height: 5); Text("本地").font(.system(size: 11)) }.foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(ChatRoom.allCases.enumerated()), id: \.element) { index, room in
                            ChatInboxRow(room: room, name: name)
                            if index < ChatRoom.allCases.count - 1 { Divider().padding(.leading, 73).opacity(0.3) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .background(.white.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.8), lineWidth: 1))
                    .shadow(color: .black.opacity(0.15), radius: 18, y: 14)
                    Text("消息保存在本机；尚未连接 Claude、Codex 或群聊服务。").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 10)
                }.padding(24).padding(.top, 12)
            }
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.94), Color(white: 0.83)], startPoint: .top, endPoint: .bottom))
            .foregroundStyle(.black).toolbar(.hidden, for: .navigationBar)
        }
    }
}
enum ChatRoom: String, CaseIterable {
    case claude, codex, work
    var key: String { "chat.room.\(rawValue)" }
    func title(name: String) -> String { switch self { case .claude: return "Claude"; case .codex: return "Codex"; case .work: return "\(name.isEmpty ? "My" : name + "’s") work chat" } }
    var symbol: String { switch self { case .claude: return "leaf.fill"; case .codex: return "chevron.left.forwardslash.chevron.right"; case .work: return "person.2.fill" } }
    var color: Color { switch self { case .claude: return Color(red: 0.55, green: 0.43, blue: 0.35); case .codex: return Color(white: 0.42); case .work: return Color(red: 0.48, green: 0.49, blue: 0.55) } }
}
struct ChatMessage: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let text: String
}
struct ChatAvatar: View {
    let room: ChatRoom
    var body: some View {
        Image(systemName: room.symbol).font(.system(size: 19, weight: .light))
            .foregroundStyle(room.color).frame(width: 44, height: 44)
            .background(LinearGradient(colors: [.white, room.color.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)).clipShape(Circle())
            .overlay(Circle().stroke(.white, lineWidth: 1)).shadow(color: .black.opacity(0.06), radius: 3, y: 2)
    }
}
struct ChatInboxRow: View {
    let room: ChatRoom
    let name: String
    @AppStorage private var stored: String
    init(room: ChatRoom, name: String) {
        self.room = room; self.name = name
        _stored = AppStorage(wrappedValue: "[]", room.key)
    }
    private var last: ChatMessage? { (try? JSONDecoder().decode([ChatMessage].self, from: Data(stored.utf8)))?.last }
    var body: some View {
        NavigationLink { ChatRoomView(room: room, name: name) } label: {
            HStack(spacing: 13) {
                ChatAvatar(room: room)
                VStack(alignment: .leading, spacing: 5) {
                    Text(room.title(name: name)).font(.system(size: 19, weight: .semibold, design: .serif))
                    Text(last?.text ?? "写下第一条消息…").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 5)
                VStack(alignment: .trailing, spacing: 9) {
                    if let last { Text(last.date, style: .time).font(.system(size: 10)).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 16).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
struct ChatRoomView: View {
    let room: ChatRoom
    let name: String
    @AppStorage private var stored: String
    @State private var draft = ""
    @State private var confirmClear = false
    init(room: ChatRoom, name: String) {
        self.room = room; self.name = name
        _stored = AppStorage(wrappedValue: "[]", room.key)
    }
    private var messages: [ChatMessage] { (try? JSONDecoder().decode([ChatMessage].self, from: Data(stored.utf8))) ?? [] }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    Text("本地消息记录 · 尚未连接服务").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 15)
                    if messages.isEmpty {
                        VStack(spacing: 15) { ChatAvatar(room: room); Text("这里可以留下你的想法。").font(.system(size: 17, design: .serif)) }.padding(.top, 55).foregroundStyle(.secondary)
                    }
                    ForEach(messages) { message in
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(message.text).font(.system(size: 15)).padding(15).background(.white.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius: 20))
                            Text(message.date, style: .time).font(.system(size: 9)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .trailing).id(message.id)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
            .onChange(of: messages.count) { _, _ in if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            .onAppear { if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .safeAreaInset(edge: .bottom) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("写下消息…", text: $draft, axis: .vertical).lineLimit(1...5).padding(13).background(.white.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius: 20))
                    Button {
                        var updated = messages
                        updated.append(ChatMessage(text: draft.trimmingCharacters(in: .whitespacesAndNewlines)))
                        if let data = try? JSONEncoder().encode(updated), let json = String(data: data, encoding: .utf8) { stored = json; draft = "" }
                    } label: { Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).frame(width: 42, height: 42).background(.black).foregroundStyle(.white).clipShape(Circle()) }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("保存消息")
                }.padding(16).background(.ultraThinMaterial)
            }
            .background(Color(white: 0.94))
            .navigationTitle(room.title(name: name)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { confirmClear = true } label: { Image(systemName: "trash") }.disabled(messages.isEmpty).accessibilityLabel("清空本地消息") } }
            .confirmationDialog("清空这个会话的本地消息？", isPresented: $confirmClear, titleVisibility: .visible) { Button("清空消息", role: .destructive) { stored = "[]" } }
        }
    }
}
struct ClosenessOrb: View {
    let closeness: Double
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 39, style: .continuous).fill(.black)
            Ellipse().fill(Color.green.opacity(0.18)).frame(width: 75, height: 92).blur(radius: 14)
            ForEach(0..<4) { index in
                Ellipse()
                    .stroke(LinearGradient(colors: [.clear, Color(red: 0.25, green: 0.9, blue: 0.38).opacity(0.85), .green.opacity(0.1), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: index == 0 ? 3 : 1.5)
                    .frame(width: 39 + CGFloat(closeness * 16) + CGFloat(index * 3), height: 72 + CGFloat(index * 2))
                    .rotationEffect(.degrees(30 + Double(index * 5)))
                    .blur(radius: index == 0 ? 1 : 3)
                    .offset(x: CGFloat(index - 2) * 2)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 15)
        .animation(.easeInOut(duration: 0.25), value: closeness)
        .accessibilityLabel("绿色光团，随亲密度改变")
    }
}

struct ClosenessGesture: View {
    @Binding var value: Double
    var title = "closer"
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    let y = geometry.size.height * 0.65
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width * 0.3, y: y))
                }.stroke(.black, lineWidth: 1.7)
                Text(title)
                    .font(.system(size: min(geometry.size.width * 0.24, 84), weight: .ultraLight, design: .serif))
                    .italic().tracking(-5)
                    .offset(x: geometry.size.width * 0.09)
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                    .position(x: 12 + (geometry.size.width - 24) * CGFloat(value), y: geometry.size.height * 0.3)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                value = Double(min(max((event.location.x - 12) / max(geometry.size.width - 24, 1), 0), 1))
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("今天的亲密度")
            .accessibilityValue("\(Int(value * 100))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value = min(value + 0.1, 1)
                case .decrement: value = max(value - 0.1, 0)
                @unknown default: break
                }
            }
        }
    }
}
