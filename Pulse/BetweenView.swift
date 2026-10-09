import SwiftUI

private enum BetweenMode: String, CaseIterable {
    case plan = "Plan", receipt = "Receipt", letter = "Letter"
    var hint: String {
        switch self {
        case .plan: return "写下我们想一起做的事…"
        case .receipt: return "记录今天值得收藏的小事…"
        case .letter: return "写一封只属于彼此的信…"
        }
    }
}

struct BetweenView: View {
    @AppStorage("between.documents") private var stored = "{}"
    @State private var mode: BetweenMode = .receipt
    @State private var date = Date()
    @State private var showDate = false
    @State private var showEditor = false
    @State private var draft = ""
    private var documents: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8))) ?? [:]
    }
    private var key: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0).\(mode.rawValue)"
    }
    private var text: String { documents[key] ?? "" }
    private func save(_ text: String) {
        var updated = documents
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { updated.removeValue(forKey: key) }
        else { updated[key] = text }
        if let data = try? JSONEncoder().encode(updated), let json = String(data: data, encoding: .utf8) { stored = json }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Between Us").font(.system(size: 29, weight: .medium, design: .serif))
                        Text("只在你我之间 · for no one else").font(.system(size: 12, design: .serif)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        HStack(spacing: 0) {
                            ForEach(BetweenMode.allCases, id: \.self) { option in
                                Button { withAnimation(.easeInOut(duration: 0.2)) { mode = option } } label: {
                                    Text(option.rawValue).font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 12)
                                        .background(mode == option ? Color(white: 0.11) : .clear)
                                        .foregroundStyle(mode == option ? .white : .black.opacity(0.65)).clipShape(Capsule())
                                        .shadow(color: .black.opacity(mode == option ? 0.15 : 0), radius: 4, y: 3)
                                }.buttonStyle(.plain).accessibilityAddTraits(mode == option ? [.isSelected] : [])
                            }
                        }.padding(3).background(.black.opacity(0.035)).clipShape(Capsule())
                        Button { showDate = true } label: {
                            HStack(spacing: 6) { Image(systemName: "calendar"); Text(Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.month(.abbreviated).day())) }
                                .font(.system(size: 12)).padding(.horizontal, 15).padding(.vertical, 14)
                                .background(.white.opacity(0.75)).clipShape(Capsule())
                                .shadow(color: .black.opacity(0.1), radius: 5, y: 4)
                        }.buttonStyle(.plain).accessibilityLabel("选择日期")
                    }
                    TypewriterIllustration(text: text, mode: mode.rawValue)
                        .frame(height: 310).padding(.top, 10)
                    Button { draft = text; showEditor = true } label: {
                        Text("Type").font(.system(size: 14)).padding(.horizontal, 29).padding(.vertical, 14)
                            .background(Color(white: 0.11)).foregroundStyle(.white).clipShape(Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))
                            .shadow(color: .black.opacity(0.2), radius: 10, y: 8)
                    }.buttonStyle(.plain).frame(maxWidth: .infinity)
                    if !text.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(mode.rawValue.uppercased()).font(.system(size: 9)).tracking(3).foregroundStyle(.secondary)
                            Text(text).font(.system(size: 15, design: .serif)).lineSpacing(6)
                            ShareLink(item: "\(mode.rawValue) · \(date.formatted(date: .abbreviated, time: .omitted))\n\n\(text)") { Label("分享这页", systemImage: "square.and.arrow.up").font(.system(size: 11)) }
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 22))
                    }
                }.padding(24).padding(.top, 12).padding(.bottom, 40)
            }
            .background(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.94), Color(white: 0.83)], startPoint: .top, endPoint: .bottom))
            .foregroundStyle(.black).toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showDate) {
                NavigationStack {
                    DatePicker("日期", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).padding()
                        .navigationTitle("选择日期").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showDate = false } } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showEditor) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                        ZStack(alignment: .topLeading) {
                            if draft.isEmpty { Text(mode.hint).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                            TextEditor(text: $draft).scrollContentBackground(.hidden).font(.system(size: 18, design: .serif)).lineSpacing(7)
                        }
                        Text("自动保存在本机，尚未连接对方设备。").font(.caption).foregroundStyle(.secondary)
                    }.padding(24).background(Color(red: 0.98, green: 0.96, blue: 0.92))
                        .navigationTitle(mode.rawValue).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { save(draft); showEditor = false } } }
                        .onChange(of: draft) { _, value in save(value) }
                }
            }
        }
    }
}

private struct TypewriterIllustration: View {
    let text: String
    let mode: String
    private let cream = Color(red: 0.80, green: 0.72, blue: 0.59)
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                RoundedRectangle(cornerRadius: 15).fill(LinearGradient(colors: [cream.opacity(0.8), cream, Color(red: 0.59, green: 0.49, blue: 0.37)], startPoint: .top, endPoint: .bottom))
                    .frame(width: width * 0.91, height: 203).offset(y: 47)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 13)
                RoundedRectangle(cornerRadius: 11).fill(Color(red: 0.91, green: 0.84, blue: 0.73)).frame(width: width * 0.86, height: 182).offset(y: 36)
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.18)).frame(width: width * 0.97, height: 36).offset(y: -109)
                RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [.white, Color(red: 0.97, green: 0.93, blue: 0.86)], startPoint: .top, endPoint: .bottom))
                    .frame(width: width * 0.73, height: 90).offset(y: -113)
                VStack(spacing: 5) {
                    Text(text.isEmpty ? "" : mode.uppercased()).font(.system(size: 7, design: .monospaced))
                    Text(String(text.prefix(90))).font(.system(size: 8, design: .monospaced)).lineLimit(3).multilineTextAlignment(.center)
                }.frame(width: width * 0.64, height: 55).offset(y: -126)
                RoundedRectangle(cornerRadius: 7).fill(LinearGradient(colors: [Color(red: 0.97, green: 0.90, blue: 0.79), cream, Color(red: 0.95, green: 0.86, blue: 0.72)], startPoint: .top, endPoint: .bottom))
                    .frame(width: width * 0.93, height: 22).offset(y: -94)
                HStack {
                    spool
                    Spacer()
                    spool
                }.padding(.horizontal, width * 0.12).offset(y: -63)
                RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Color(red: 0.95, green: 0.88, blue: 0.76), cream], startPoint: .top, endPoint: .bottom))
                    .frame(width: width * 0.88, height: 36).offset(y: -28)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 3)
                Text("PULSE").font(.system(size: 7, weight: .semibold, design: .serif)).tracking(2).padding(.horizontal, 9).padding(.vertical, 4).background(Color(white: 0.13)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 3)).offset(y: -28)
                ZStack {
                    ForEach(0..<25) { index in
                        Rectangle().fill(Color(white: 0.35)).frame(width: 1, height: 47).rotationEffect(.degrees(Double(index - 12) * 4)).offset(y: -8)
                    }
                }.frame(width: 120, height: 50).offset(y: 14)
                VStack(spacing: 6) {
                    ForEach(0..<4) { row in
                        HStack(spacing: 5) {
                            ForEach(0..<(row == 3 ? 11 : 12), id: \.self) { _ in
                                ZStack {
                                    Circle().fill(Color(white: 0.2)).offset(y: 3)
                                    Circle().fill(LinearGradient(colors: [.white, Color(white: 0.85)], startPoint: .top, endPoint: .bottom))
                                    Image(systemName: "heart.fill").font(.system(size: max(5, width * 0.019))).foregroundStyle(Color(red: 0.69, green: 0.16, blue: 0.18))
                                }.frame(width: width * 0.052, height: width * 0.043)
                            }
                        }
                    }
                    RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [.white, cream], startPoint: .top, endPoint: .bottom)).frame(width: width * 0.61, height: 13).overlay(Text("♥ ♥ ♥ ♥ ♥").font(.system(size: 9)).foregroundStyle(.red.opacity(0.65)))
                }.offset(y: 76)
            }.frame(width: width, height: geometry.size.height)
        }.accessibilityLabel("复古米色打字机，纸张预览已保存的文字")
    }
    private var spool: some View {
        RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.12)).frame(width: 40, height: 27)
            .overlay(Ellipse().stroke(Color(white: 0.4), lineWidth: 1).frame(width: 23, height: 13))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.35), lineWidth: 2))
    }
}
