import SwiftUI

struct LibraryWindow: View {
    @ObservedObject var store: ThoughtStore

    var body: some View {
        NavigationStack {
            Group {
                if store.thoughts.isEmpty {
                    ContentUnavailableView(
                        "No Thoughts Yet",
                        systemImage: "text.bubble",
                        description: Text("Capture one with option+space.")
                    )
                } else {
                    List(store.thoughts) { thought in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(thought.title ?? thought.text)
                                .font(.headline)
                                .lineLimit(2)

                            if let distilled = thought.distilled {
                                Text(distilled)
                                    .foregroundStyle(.secondary)
                            } else if thought.title != nil {
                                Text(thought.text)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 8) {
                                Text(thought.createdAt.formatted(date: .abbreviated, time: .shortened))

                                if !thought.tags.isEmpty {
                                    Text(thought.tags.map { "#\($0)" }.joined(separator: " "))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Thoughts")
            .frame(minWidth: 520, minHeight: 420)
        }
    }
}
