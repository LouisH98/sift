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

    func toggleSelected(in items: [ActionItem], store: ThoughtStore) {
        guard
            let selectedActionID,
            let item = items.first(where: { $0.id == selectedActionID })
        else {
            return
        }

        toggle(item, store: store)
    }

    func toggle(_ item: ActionItem, store: ThoughtStore) {
        if item.isDone {
            restore(item, store: store)
        } else {
            complete(item, store: store)
        }
    }

    private func restore(_ item: ActionItem, store: ThoughtStore) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            store.setActionItemDone(item.id, isDone: false)
            ensureSelection(in: store.visibleActionItemsForChecklist)
        }
    }

    private func complete(_ item: ActionItem, store: ThoughtStore) {
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
                self.ensureSelection(in: store.visibleActionItemsForChecklist)
            }
        }
    }
}

struct ActionChecklistView: View {
    @ObservedObject var store: ThoughtStore
    @ObservedObject var navigationModel: ActionListNavigationModel
    let onCancel: () -> Void

    @State private var dailyRefreshDate = Date()

    private var openActionItems: [ActionItem] {
        store.openActionItems
    }

    private var recentlyCompletedActionItems: [ActionItem] {
        _ = dailyRefreshDate
        return store.recentlyCompletedActionItems
    }

    private var visibleActionItems: [ActionItem] {
        openActionItems + recentlyCompletedActionItems
    }

    private var actionRows: [ActionListRow] {
        var rows = openActionItems.map { ActionListRow.action($0, isRecentlyCompleted: false) }

        if !recentlyCompletedActionItems.isEmpty {
            rows.append(.divider)
            rows.append(contentsOf: recentlyCompletedActionItems.map { ActionListRow.action($0, isRecentlyCompleted: true) })
        }

        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))

                Text("Actions")
                    .font(.headline)

                Spacer()

                Text("\(openActionItems.count)")
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
                                ForEach(actionRows) { row in
                                    switch row {
                                    case let .action(item, isRecentlyCompleted):
                                        ActionRow(
                                            item: item,
                                            sourceThought: store.thought(with: item.thoughtID),
                                            isSelected: navigationModel.selectedActionID == item.id,
                                            isCompleting: navigationModel.completingActionIDs.contains(item.id),
                                            isRecentlyCompleted: isRecentlyCompleted,
                                            onToggle: {
                                                navigationModel.toggle(item, store: store)
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
                                    case .divider:
                                        RecentlyCompletedDivider()
                                            .id(row.id)
                                            .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                            }
                            .padding(.trailing, 4)
                            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: actionRows)
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
                onToggle: { navigationModel.toggleSelected(in: visibleActionItems, store: store) },
                onCancel: onCancel
            )
            .frame(width: 0, height: 0)
        )
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            dailyRefreshDate = date
        }
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
    let isRecentlyCompleted: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onToggle()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white.opacity(showCompletedState ? 0 : 0.58), lineWidth: 1.4)
                        .scaleEffect(showCompletedState ? 0.72 : 1)
                        .opacity(showCompletedState ? 0 : 1)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.green)
                        .scaleEffect(showCompletedState ? 1 : 0.3)
                        .opacity(showCompletedState ? 1 : 0)
                }
                .frame(width: 18, height: 18)
                .animation(.spring(response: 0.22, dampingFraction: 0.52), value: showCompletedState)
            }
            .buttonStyle(.plain)
            .foregroundStyle(showCompletedState ? .green : .white.opacity(0.58))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(primaryTextColor)
                    .strikethrough(isRecentlyCompleted, color: .white.opacity(0.32))
                    .lineLimit(1)

                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }

                if let dueAt = item.dueAt {
                    HStack(spacing: 5) {
                        Image(systemName: dueIconName(for: dueAt))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(dueIconColor(for: dueAt))

                        Text(DateFormatter.actionDueDate.string(from: dueAt))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(dueTextColor(for: dueAt))
                    }
                        .lineLimit(1)
                }

                if let sourceText {
                    Text(sourceText)
                        .font(.caption2)
                        .foregroundStyle(sourceTextColor)
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
            onToggle()
        }
    }

    private var showCompletedState: Bool {
        isCompleting || isRecentlyCompleted
    }

    private var primaryTextColor: Color {
        if isCompleting {
            return .green.opacity(0.96)
        }

        return isRecentlyCompleted ? .white.opacity(0.48) : .white.opacity(0.92)
    }

    private var secondaryTextColor: Color {
        if isCompleting {
            return .green.opacity(0.56)
        }

        return isRecentlyCompleted ? .white.opacity(0.34) : .white.opacity(0.56)
    }

    private var sourceTextColor: Color {
        if isCompleting {
            return .green.opacity(0.36)
        }

        return isRecentlyCompleted ? .white.opacity(0.24) : .white.opacity(0.34)
    }

    private var sourceText: String? {
        guard let sourceThought else {
            return nil
        }

        let text = sourceThought.title ?? sourceThought.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let normalizedSource = normalizedComparisonText(text)
        let normalizedTitle = normalizedComparisonText(item.title)
        let normalizedDetail = item.detail.map(normalizedComparisonText) ?? ""

        guard !normalizedSource.isEmpty else {
            return nil
        }

        if normalizedSource == normalizedTitle || normalizedSource == normalizedDetail {
            return nil
        }

        if !normalizedTitle.isEmpty, normalizedSource.contains(normalizedTitle) {
            return nil
        }

        if !normalizedDetail.isEmpty, normalizedDetail.contains(normalizedSource) {
            return nil
        }

        return text
    }

    private func dueIconName(for dueAt: Date) -> String {
        dueAt < Date() ? "exclamationmark.circle.fill" : "clock"
    }

    private func dueIconColor(for dueAt: Date) -> Color {
        if showCompletedState {
            return .green.opacity(0.48)
        }

        return dueAt < Date() ? .red.opacity(0.82) : .white.opacity(0.5)
    }

    private func dueTextColor(for dueAt: Date) -> Color {
        if showCompletedState {
            return .green.opacity(0.56)
        }

        return dueAt < Date() ? .red.opacity(0.82) : .teal.opacity(0.72)
    }

    private func normalizedComparisonText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private enum ActionListRow: Identifiable, Hashable {
    case action(ActionItem, isRecentlyCompleted: Bool)
    case divider

    var id: String {
        switch self {
        case let .action(item, _):
            return "action-\(item.id.uuidString)"
        case .divider:
            return "recently-completed-divider"
        }
    }
}

private struct RecentlyCompletedDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(height: 1)

            Text("Completed today")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)

            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(height: 1)
        }
        .padding(.vertical, 2)
    }
}

private extension DateFormatter {
    static let actionDueDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct ActionKeyboardCatcher: NSViewRepresentable {
    let onMove: (Int) -> Void
    let onToggle: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ActionKeyView {
        let view = ActionKeyView()
        view.identifier = .thoughtNotchActionKeyboardCatcher
        view.onMove = onMove
        view.onToggle = onToggle
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: ActionKeyView, context: Context) {
        view.onMove = onMove
        view.onToggle = onToggle
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
        var onToggle: (() -> Void)?
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
            case 36, 49, 76:
                onToggle?()
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

private extension ThoughtStore {
    var visibleActionItemsForChecklist: [ActionItem] {
        openActionItems + recentlyCompletedActionItems
    }
}
