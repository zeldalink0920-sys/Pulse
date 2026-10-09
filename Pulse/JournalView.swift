import SwiftUI

struct JournalView: View {
    @AppStorage("journal.entries") private var stored = "[]"
    @State private var selectedDate = Date()
    @State private var editing: Entry?
    @State private var showEditor = false
    @State private var draft = ""
    @State private var mood = "平静"
    @State private var deleteTarget: Entry?
    @State private var showDelete = false
    private var entries: [Entry] {
        ((try? JSONDecoder().decode([Entry].self, from: Data(stored.utf8))) ?? []).sorted { $0.date > $1.date }
    }
    private var visible: [Entry] { entries.filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) } }
    private func write(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(entries), let json = String(data: data, encoding: .utf8) { stored = json }
    }
    private func open(_ entry: Entry?) {
        editing = entry
        draft = entry?.text ?? ""
        mood = entry?.mood ?? "平静"
        showEditor = true
    }
    private func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var updated = entries
        if let editing, let index = updated.firstIndex(where: { $0.id == editing.id }) {
            updated[index].text = text
            updated[index].mood = mood
        } else {
            updated.append(Entry(date: selectedDate, text: text, mood: mood))
        }
        write(updated)
        showEditor = false
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text("Diary").font(.system(size: 29, weight: .medium, design: .serif))
                        Spacer()
                        Button { open(nil) } label: { Image(systemName: "plus").font(.system(size: 16)).padding(12).background(.white.opacity(0.7)).clipShape(Circle()) }
                            .buttonStyle(.plain).accessibilityLabel("写日记")
                    }
                    Text("A place for the little things.").font(.system(size: 14, design: .serif)).foregroundStyle(.secondary)
                    DatePicker("日期", selection: $selectedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical).tint(Color(white: 0.25)).padding(12)
                        .background(.white.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 25))
                    if visible.isEmpty {
                        VStack(spacing: 15) {
                            Image(systemName: "book.closed").font(.system(size: 28, weight: .ultraLight))
                            Text("这一天，还留着空白。").font(.system(size: 17, design: .serif))
                            Button("记录一个片刻") { open(nil) }.font(.system(size: 12))
                        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(visible) { entry in
                        VStack(alignment: .leading, spacing: 15) {
                            HStack {
                                Text(entry.date, style: .date)
                                Spacer()
                                Text(entry.mood)
                            }.font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(entry.text).font(.system(size: 17, design: .serif)).lineSpacing(7)
                            HStack(spacing: 22) {
                                Button("编辑") { open(entry) }
                                ShareLink(item: entry.text) { Text("分享") }
                                Spacer()
                                Button("删除", role: .destructive) { deleteTarget = entry; showDelete = true }
                            }.font(.system(size: 11))
                        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 25))
                            .overlay(RoundedRectangle(cornerRadius: 25).stroke(.white.opacity(0.8), lineWidth: 1))
                            .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
                    }
                    Text("所有日记保存在本机。").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(24).padding(.top, 12).padding(.bottom, 35)
            }
            .background(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.94), Color(white: 0.83)], startPoint: .top, endPoint: .bottom))
            .foregroundStyle(.black).toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("删除这篇日记？", isPresented: $showDelete, titleVisibility: .visible) {
                Button("删除日记", role: .destructive) { if let deleteTarget { write(entries.filter { $0.id != deleteTarget.id }) } }
            }
            .sheet(isPresented: $showEditor) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(selectedDate, style: .date).font(.caption).foregroundStyle(.secondary)
                        Picker("心情", selection: $mood) { ForEach(["开心", "平静", "疲惫", "低落"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                        TextEditor(text: $draft).font(.system(size: 18, design: .serif)).lineSpacing(7).scrollContentBackground(.hidden)
                            .accessibilityIdentifier("diary.editor")
                    }.padding(24).background(Color(white: 0.96))
                        .navigationTitle(editing == nil ? "写日记" : "编辑日记").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { showEditor = false } }
                            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("diary.save") }
                        }
                }
            }
        }
    }
}