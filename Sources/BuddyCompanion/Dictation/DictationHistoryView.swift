import AppKit
import BuddyOverlay
import SwiftUI

/// The Lumi window's Dictation page: recent dictations, newest first and grouped by day, each a
/// card with when, the app, the words, whether they were typed, Copy and Delete; search and Clear
/// All at the top. StudioView puts the window background behind it.
struct DictationHistoryView: View {
    static let title = "Dictation"

    let history: DictationHistory
    @State private var search = ""
    @State private var confirmingClear = false
    @State private var copied: DictationRecord.ID?

    var body: some View {
        let records = history.matching(search)
        VStack(spacing: 0) {
            header
            Divider()
            if history.records.isEmpty {
                empty(history.temporary
                      ? "Temporary mode is on: dictations from now on are kept only until you turn it off or quit."
                      : "Your dictations will show up here, typed or not.")
            } else if records.isEmpty {
                empty("No dictations match “\(search)”.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        let days = Self.days(records)
                        ForEach(days, id: \.title) { day in
                            StudioGroupLabel(day.title).padding(.top, day.title == days.first?.title ? 0 : 12)
                            ForEach(day.records) { record in
                                DictationRow(record: record, copied: copied == record.id,
                                             copy: { copy(record) }, delete: { history.delete(record.id) })
                            }
                        }
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            }
        }
        .confirmationDialog("Clear dictation history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { history.clearAll() }
        } message: {
            Text("Every dictation is deleted from this Mac. This can't be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label {
                TextField("Search", text: $search, prompt: Text("Search dictations"))
                    .textFieldStyle(.plain)
            } icon: {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            .frame(maxWidth: 320, alignment: .leading)
            Spacer(minLength: 8)
            Button("Clear All…") { confirmingClear = true }
                .buttonStyle(.pill)
                .disabled(history.records.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func empty(_ line: String) -> some View {
        Text(line)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Records (newest first) grouped by day: "Today", "Yesterday", then the date.
    static func days(_ records: [DictationRecord], calendar: Calendar = .current, now: Date = Date())
        -> [(title: String, records: [DictationRecord])] {
        var days: [(title: String, records: [DictationRecord])] = []
        for record in records {
            let title = calendar.isDate(record.date, inSameDayAs: now) ? "Today"
                : calendar.isDateInYesterday(record.date) ? "Yesterday"
                : record.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            if days.last?.title == title { days[days.count - 1].records.append(record) } else { days.append((title, [record])) }
        }
        return days
    }

    private func copy(_ record: DictationRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.text, forType: .string)
        copied = record.id
    }
}

/// One dictation: time · app · status on top, the words (selectable, wrapped), Copy and Delete.
struct DictationRow: View {
    let record: DictationRecord
    let copied: Bool
    let copy: () -> Void
    let delete: () -> Void

    var body: some View {
        StudioCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(record.date, format: .dateTime.hour().minute())
                    if let app = record.appName {
                        Text("·")
                        Text(app).lineLimit(1)
                    }
                    Text("·")
                    Label(Self.status(record.status), systemImage: Self.symbol(record.status))
                        .foregroundStyle(record.status == .inserted ? AnyShapeStyle(.lumiSecondary) : AnyShapeStyle(.lumiAmber))
                    Spacer(minLength: 8)
                    Button(copied ? "Copied" : "Copy", action: copy)
                        .buttonStyle(.lumiLink)
                    Button(action: delete) { Image(systemName: "trash") }
                        .buttonStyle(.roundIcon)
                        .help("Delete")
                        .accessibilityLabel("Delete")
                }
                .font(.system(size: 12))
                .foregroundStyle(.lumiSecondary)
                Text(record.text)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contextMenu {
            Button("Copy", action: copy)
            Button("Delete", role: .destructive, action: delete)
        }
    }

    static func status(_ status: DictationRecord.Status) -> String {
        switch status {
        case .inserted: "Inserted"
        case .notInserted: "Not inserted"
        }
    }

    static func symbol(_ status: DictationRecord.Status) -> String {
        switch status {
        case .inserted: "checkmark"
        case .notInserted: "exclamationmark.circle"
        }
    }
}
