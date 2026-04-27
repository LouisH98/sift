import AppKit
import Combine
import SwiftUI

@MainActor
final class ActionListNavigationModel: ObservableObject {
    @Published var selectedActionID: UUID?
    @Published var completingActionIDs = Set<UUID>()

    func ensureSelection(in items: [ActionItem]) {
        let ids = items.map(\.id)

        guard !ids.isEmpty else {
            selectedActionID = nil
            return
        }

        if let selectedActionID, ids.contains(selectedActionID) {
            return
        }

        selectedActionID = ids[0]
    }

    func moveSelection(_ delta: Int, in items: [ActionItem]) {
        let ids = items.map(\.id)

        guard !ids.isEmpty else {
            selectedActionID = nil
            return
        }

        let currentIndex = selectedActionID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), ids.count - 1)
        selectedActionID = ids[nextIndex]
    }

    func completeSelected(in items: [ActionItem], store: ThoughtStore) {
        guard
            let selectedActionID,
            let item = items.first(where: { $0.id == selectedActionID })
        else {
            return
        }

        complete(item, store: store)
    }

    func complete(_ item: ActionItem, store: ThoughtStore) {
        guard !completingActionIDs.contains(item.id) else {
            return
        }

        _ = withAnimation(.spring(response: 0.24, dampingFraction: 0.62)) {
            completingActionIDs.insert(item.id)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.44) { [weak self, weak store] in
            guard let self, let store else {
                return
            }

            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                store.setActionItemDone(item.id, isDone: true)
                self.completingActionIDs.remove(item.id)
                self.ensureSelection(in: store.openActionItems)
            }
        }
    }
}

struct ActionChecklistView: View {
    @ObservedObject var store: ThoughtStore
    @ObservedObject var navigationModel: ActionListNavigationModel
    let onCancel: () -> Void

    private var visibleActionItems: [ActionItem] {
        store.openActionItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))

                Text("Actions")
                    .font(.headline)

                Spacer()

                Text("\(visibleActionItems.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.52))
            }
            .foregroundStyle(.white.opacity(0.86))

            if visibleActionItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22))
                    Text("No open actions")
                        .font(.callout.weight(.medium))
                }
                .frame(maxWidth: .infinity, minHeight: 82)
                .foregroundStyle(.white.opacity(0.48))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollViewReader { proxy in
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(visibleActionItems) { item in
                                    ActionRow(
                                        item: item,
                                        sourceThought: store.thought(with: item.thoughtID),
                                        isSelected: navigationModel.selectedActionID == item.id,
                                        isCompleting: navigationModel.completingActionIDs.contains(item.id),
                                        onComplete: {
                                            navigationModel.complete(item, store: store)
                                        }
                                    )
                                    .id(item.id)
                                    .transition(
                                        .asymmetric(
                                            insertion: .opacity.combined(with: .move(edge: .top)),
                                            removal: .opacity
                                                .combined(with: .scale(scale: 0.92, anchor: .top))
                                                .combined(with: .move(edge: .trailing))
                                        )
                                    )
                                }
                            }
                            .padding(.trailing, 4)
                            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: visibleActionItems)
                            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: navigationModel.selectedActionID)
                            .onChange(of: navigationModel.selectedActionID) { _, id in
                                guard let id else {
                                    return
                                }

                                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 96)
            }
        }
        .background(
            ActionKeyboardCatcher(
                onMove: { navigationModel.moveSelection($0, in: visibleActionItems) },
                onComplete: { navigationModel.completeSelected(in: visibleActionItems, store: store) },
                onCancel: onCancel
            )
            .frame(width: 0, height: 0)
        )
        .onAppear {
            navigationModel.ensureSelection(in: visibleActionItems)
        }
        .onChange(of: visibleActionItems.map(\.id)) { _, _ in
            navigationModel.ensureSelection(in: visibleActionItems)
        }
    }
}

private struct ActionRow: View {
    let item: ActionItem
    let sourceThought: Thought?
    let isSelected: Bool
    let isCompleting: Bool
    let onComplete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onComplete()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white.opacity(isCompleting ? 0 : 0.58), lineWidth: 1.4)
                        .scaleEffect(isCompleting ? 0.72 : 1)
                        .opacity(isCompleting ? 0 : 1)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.green)
                        .scaleEffect(isCompleting ? 1 : 0.3)
                        .opacity(isCompleting ? 1 : 0)
                }
                .frame(width: 18, height: 18)
                .animation(.spring(response: 0.22, dampingFraction: 0.52), value: isCompleting)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isCompleting ? .green : .white.opacity(0.58))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isCompleting ? .green.opacity(0.96) : .white.opacity(0.92))
                    .lineLimit(1)

                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isCompleting ? .green.opacity(0.56) : .white.opacity(0.56))
                        .lineLimit(1)
                }

                if let sourceThought {
                    Text(sourceThought.title ?? sourceThought.text)
                        .font(.caption2)
                        .foregroundStyle(isCompleting ? .green.opacity(0.36) : .white.opacity(0.34))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? .white.opacity(0.1) : .clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? .white.opacity(0.18) : .clear, lineWidth: 1)
                }
        }
        .scaleEffect(isCompleting ? 0.985 : 1, anchor: .center)
        .contentShape(Rectangle())
        .onTapGesture {
            onComplete()
        }
    }
}

private struct ActionKeyboardCatcher: NSViewRepresentable {
    let onMove: (Int) -> Void
    let onComplete: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ActionKeyView {
        let view = ActionKeyView()
        view.identifier = .thoughtNotchActionKeyboardCatcher
        view.onMove = onMove
        view.onComplete = onComplete
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: ActionKeyView, context: Context) {
        view.onMove = onMove
        view.onComplete = onComplete
        view.onCancel = onCancel

        DispatchQueue.main.async {
            guard let window = view.window, window.firstResponder !== view else {
                return
            }

            window.makeFirstResponder(view)
        }
    }

    final class ActionKeyView: NSView {
        var onMove: ((Int) -> Void)?
        var onComplete: (() -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool {
            true
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126:
                onMove?(-1)
            case 125:
                onMove?(1)
            case 36, 76:
                onComplete?()
            case 53:
                onCancel?()
            default:
                super.keyDown(with: event)
            }
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    static let thoughtNotchActionKeyboardCatcher = Self("ThoughtNotchActionKeyboardCatcher")
}
