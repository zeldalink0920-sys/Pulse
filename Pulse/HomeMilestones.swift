import SwiftUI

struct HomeMilestones: View {
    @AppStorage("dates.anniversary.enabled") private var anniversaryEnabled = false
    @AppStorage("dates.anniversary") private var anniversary = Date().timeIntervalSince1970
    @AppStorage("dates.birthday.enabled") private var birthdayEnabled = false
    @AppStorage("dates.birthday") private var birthday = Date().timeIntervalSince1970
    @State private var showSettings = false
    @State private var offset = 0.0
    private var preview: Date { Calendar.current.date(byAdding: .day, value: Int(offset), to: Date()) ?? Date() }
    private func next(_ date: Date, monthly: Bool) -> Date? {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.month, .day], from: date)
        if monthly { components.month = nil }
        return calendar.nextDate(after: calendar.startOfDay(for: preview).addingTimeInterval(-1), matching: components, matchingPolicy: .nextTime)
    }
    private func card(title: String, date: Date?) -> some View {
        Button { showSettings = true } label: {
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 8)).tracking(2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                VStack(alignment: .leading, spacing: 7) {
                    EmbossedText(text: date.map { String(max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: preview), to: $0).day ?? 0)) } ?? "—", size: 27, weight: .bold)
                    Text(date.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "设置日期").font(.system(size: 10, design: .serif)).foregroundStyle(.secondary)
                }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.85)).clipShape(RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.5), lineWidth: 1))
                    .shadow(color: .white.opacity(0.7), radius: 2, x: -1, y: -1)
            }
        }.buttonStyle(.plain)
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                card(title: "MONTHLY", date: anniversaryEnabled ? next(Date(timeIntervalSince1970: anniversary), monthly: true) : nil)
                card(title: "BIRTHDAY", date: birthdayEnabled ? next(Date(timeIntervalSince1970: birthday), monthly: false) : nil)
                card(title: "ANNIVERSARY", date: anniversaryEnabled ? next(Date(timeIntervalSince1970: anniversary), monthly: false) : nil)
            }
            Slider(value: $offset, in: 0...365, step: 1).tint(Color(white: 0.35)).accessibilityLabel("预览未来一年的倒计时")
            HStack { Text("today"); Spacer(); Text("one year") }.font(.system(size: 9)).foregroundStyle(.secondary)
            if offset > 0 { Text("预览 \(preview.formatted(date: .abbreviated, time: .omitted)) 的剩余天数").font(.system(size: 9)).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $showSettings) { MilestoneSettings() }
    }
}

struct MilestoneSettings: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dates.anniversary.enabled") private var anniversaryEnabled = false
    @AppStorage("dates.anniversary") private var anniversary = Date().timeIntervalSince1970
    @AppStorage("dates.birthday.enabled") private var birthdayEnabled = false
    @AppStorage("dates.birthday") private var birthday = Date().timeIntervalSince1970
    var body: some View {
        NavigationStack {
            Form {
                Section("在一起的日子") {
                    Toggle("显示每月纪念日与周年倒计时", isOn: $anniversaryEnabled)
                    if anniversaryEnabled {
                        DatePicker("纪念日期", selection: Binding(get: { Date(timeIntervalSince1970: anniversary) }, set: { anniversary = $0.timeIntervalSince1970 }), in: ...Date(), displayedComponents: .date)
                    }
                }
                Section("生日") {
                    Toggle("显示生日倒计时", isOn: $birthdayEnabled)
                    if birthdayEnabled {
                        DatePicker("生日", selection: Binding(get: { Date(timeIntervalSince1970: birthday) }, set: { birthday = $0.timeIntervalSince1970 }), in: ...Date(), displayedComponents: .date)
                    }
                }
                Section { Text("日期保存在本机。Monthly 使用纪念日期的日数；生日与周年每年重复。").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("重要日子").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}