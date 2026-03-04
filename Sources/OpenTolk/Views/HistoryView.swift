import SwiftUI

struct HistoryView: View {
    @State private var entries: [HistoryEntry] = []
    @State private var searchText = ""
    @State private var expandedIndex: Int? = nil
    @State private var copiedIndex: Int? = nil

    private var maxEntries: Int { 50 }

    private var filteredEntries: [HistoryEntry] {
        let limited = Array(entries.prefix(maxEntries))
        if searchText.isEmpty { return limited }
        return limited.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                if !entries.isEmpty {
                    Button("Clear All") {
                        HistoryManager.shared.clear()
                        entries = []
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search dictations...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            // List
            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: searchText.isEmpty ? "clock" : "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.quaternary)
                    Text(searchText.isEmpty ? "No dictations yet" : "No results")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(filteredEntries.enumerated()), id: \.offset) { index, entry in
                            historyRow(entry: entry, index: index)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // Footer (sync upsell for non-Pro)
            if !SubscriptionManager.shared.isPro && !entries.isEmpty {
                Divider()
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                    Text("Upgrade to Pro to sync history across all your Macs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
            }
        }
        .frame(minWidth: 360, maxWidth: 360, minHeight: 400, maxHeight: 600)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            entries = HistoryManager.shared.getAll()
        }
    }

    private func historyRow(entry: HistoryEntry, index: Int) -> some View {
        let isExpanded = expandedIndex == index

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text.prefix(isExpanded ? entry.text.count : 80) + (!isExpanded && entry.text.count > 80 ? "..." : ""))
                        .font(.body)
                        .lineLimit(isExpanded ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Text(formattedDate(entry.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(wordCount(entry.text)) words")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    copiedIndex = index
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedIndex == index { copiedIndex = nil }
                    }
                } label: {
                    Image(systemName: copiedIndex == index ? "checkmark.circle.fill" : "doc.on.clipboard")
                        .foregroundStyle(copiedIndex == index ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedIndex = isExpanded ? nil : index
            }
        }
        .background(isExpanded ? Color.accentColor.opacity(0.05) : Color.clear)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func wordCount(_ text: String) -> Int {
        text.split(separator: " ").count
    }
}
