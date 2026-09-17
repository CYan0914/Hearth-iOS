import SwiftUI

/// The server's category vocabulary, as a pickable list.
///
/// Driven by `SessionStore.categories` rather than a table compiled into the
/// app. The category is what decides which maintenance gets scheduled, and the
/// knowledge base grows server-side between releases -- a hardcoded list would
/// quietly offer a subset, and a user choosing from it would never find out
/// what they were not shown.
struct CategoryPickerView: View {
    let selected: String
    let onPick: (String) -> Void

    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var isLoading = false

    private var matches: [CategoryOption] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return session.categories }
        return session.categories.filter {
            $0.label.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.categories.isEmpty {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EmptyState(
                            icon: "square.grid.2x2",
                            title: "Types did not load",
                            message: "The list of types comes from Hearth. Check your connection and try again.",
                            actionTitle: "Try again",
                            action: { Task { await load() } }
                        )
                    }
                } else if matches.isEmpty {
                    EmptyState(
                        icon: "magnifyingglass",
                        title: "Nothing matches",
                        message: "No type in Hearth is called \"\(query)\"."
                    )
                } else {
                    list
                }
            }
            .navigationTitle("What is it?")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search types")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var list: some View {
        List(matches) { option in
            Button {
                onPick(option.id)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .foregroundStyle(.primary)
                        // Shown because it is the reason the type matters: a type
                        // with no reminders attached schedules nothing, and the
                        // user should be able to see that before picking it.
                        Text(reminderCount(option.templateCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if option.id == selected {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.ember)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
    }

    private func reminderCount(_ count: Int) -> String {
        switch count {
        case 0: return "No reminders scheduled for this"
        case 1: return "1 reminder scheduled"
        default: return "\(count) reminders scheduled"
        }
    }

    private func load() async {
        guard session.categories.isEmpty else { return }
        isLoading = true
        await session.loadCategories()
        isLoading = false
    }
}
