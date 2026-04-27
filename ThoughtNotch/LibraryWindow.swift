import SwiftUI

struct LibraryWindow: View {
    enum Mode: String, CaseIterable, Identifiable {
        case raw = "Raw"
        case distilled = "Distilled"

        var id: String { rawValue }
    }

    enum PageViewMode: String, CaseIterable, Identifiable {
        case synthesis = "Synthesis"
        case distilled = "Distilled"

        var id: String { rawValue }
    }

    @ObservedObject var store: ThoughtStore
    @StateObject private var reorganizer = ThoughtReorganizer()
    @State private var mode: Mode = .distilled
    @State private var pageViewMode: PageViewMode = .synthesis
    @State private var searchText = ""
    @State private var selectedPageID: UUID?
    @State private var rawSelectionMode = false
    @State private var selectedThoughtIDs = Set<UUID>()
    @State private var pendingThoughtDeletion: Thought?
    @State private var pendingBulkThoughtDeletion = false
    @State private var pendingPageDeletion: ThoughtPage?
    @State private var reorganizationProposal: ReorganizationProposal?

    private var filteredThoughts: [Thought] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return store.thoughts
        }

        return store.thoughts.filter { thought in
            thought.text.localizedCaseInsensitiveContains(query)
                || (thought.title?.localizedCaseInsensitiveContains(query) ?? false)
                || (thought.distilled?.localizedCaseInsensitiveContains(query) ?? false)
                || thought.tags.contains { $0.localizedCaseInsensitiveContains(query) }
                || (store.page(with: thought.pageID)?.title.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            notebookView
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            ensureSelection()
            ThoughtProcessor.shared.synthesizeStalePages()
        }
        .onChange(of: store.pages.map(\.id)) { _, _ in
            ensureSelection()
        }
        .onChange(of: store.thoughts.map(\.id)) { _, ids in
            selectedThoughtIDs.formIntersection(Set(ids))
        }
        .onChange(of: mode) { _, mode in
            if mode != .raw {
                rawSelectionMode = false
                selectedThoughtIDs.removeAll()
            }
        }
        .alert("Delete Thought?", isPresented: deleteThoughtBinding) {
            Button("Delete", role: .destructive) {
                if let pendingThoughtDeletion {
                    store.deleteThought(pendingThoughtDeletion.id)
                    ThoughtProcessor.shared.synthesizeStalePages()
                }
                pendingThoughtDeletion = nil
            }

            Button("Cancel", role: .cancel) {
                pendingThoughtDeletion = nil
            }
        } message: {
            Text("This removes the raw thought, its action items, and marks affected pages stale.")
        }
        .alert("Delete Selected Thoughts?", isPresented: $pendingBulkThoughtDeletion) {
            Button("Delete \(selectedThoughtIDs.count)", role: .destructive) {
                for thoughtID in selectedThoughtIDs {
                    store.deleteThought(thoughtID)
                }

                selectedThoughtIDs.removeAll()
                rawSelectionMode = false
                ThoughtProcessor.shared.synthesizeStalePages()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected raw thoughts, their action items, and marks affected pages stale.")
        }
        .alert("Delete Page?", isPresented: deletePageBinding) {
            Button("Delete Page", role: .destructive) {
                if let pendingPageDeletion {
                    store.deletePage(pendingPageDeletion.id)
                    ThoughtProcessor.shared.synthesizeStalePages()
                }
                pendingPageDeletion = nil
            }

            Button("Cancel", role: .cancel) {
                pendingPageDeletion = nil
            }
        } message: {
            Text("Linked thoughts will be moved to Unsorted. Child pages will be removed too.")
        }
        .sheet(item: proposalBinding) { proposal in
            ReorganizationPreviewSheet(
                proposal: proposal,
                store: store,
                onApply: {
                    store.applyReorganizationProposal(proposal)
                    reorganizationProposal = nil
                    ensureSelection()
                    ThoughtProcessor.shared.synthesizeStalePages()
                },
                onCancel: {
                    reorganizationProposal = nil
                }
            )
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            TextField("Search thoughts", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            Spacer()

            if let error = reorganizer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            if mode == .raw {
                rawBulkToolbar
            } else {
                pageViewToolbar
            }

            Button {
                Task {
                    reorganizationProposal = await reorganizer.makeProposal()
                }
            } label: {
                Label(reorganizer.isReorganizing ? "Tidying..." : "Tidy", systemImage: "wand.and.sparkles")
            }
            .disabled(reorganizer.isReorganizing || store.thoughts.isEmpty)
        }
        .padding(12)
    }

    private var pageViewToolbar: some View {
        Picker("Page View", selection: $pageViewMode) {
            Image(systemName: "sparkles")
                .tag(PageViewMode.synthesis)
                .help("Synthesis")

            Image(systemName: "doc.text.magnifyingglass")
                .tag(PageViewMode.distilled)
                .help("Distilled")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 82)
        .help(pageViewMode.rawValue)
    }

    @ViewBuilder
    private var rawBulkToolbar: some View {
        Divider()
            .frame(height: 18)

        Button {
            withAnimation(.smooth(duration: 0.18)) {
                rawSelectionMode.toggle()
                if !rawSelectionMode {
                    selectedThoughtIDs.removeAll()
                }
            }
        } label: {
            Label(rawSelectionMode ? "Done" : "Select", systemImage: rawSelectionMode ? "checkmark" : "checklist")
        }

        if rawSelectionMode {
            Button {
                selectedThoughtIDs = Set(filteredThoughts.map(\.id))
            } label: {
                Label("All", systemImage: "checkmark.circle")
            }
            .disabled(filteredThoughts.isEmpty)

            Button {
                selectedThoughtIDs.removeAll()
            } label: {
                Label("Clear", systemImage: "circle")
            }
            .disabled(selectedThoughtIDs.isEmpty)

            Button(role: .destructive) {
                pendingBulkThoughtDeletion = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedThoughtIDs.isEmpty)
            .help(selectedThoughtIDs.isEmpty ? "Select thoughts to delete" : "Delete \(selectedThoughtIDs.count) selected thoughts")
        }
    }

    private var notebookView: some View {
        NavigationSplitView {
            switch mode {
            case .raw:
                RawManagementSidebar(
                    visibleThoughtCount: filteredThoughts.count,
                    totalThoughtCount: store.thoughts.count,
                    selectionMode: $rawSelectionMode,
                    selectedThoughtIDs: $selectedThoughtIDs
                )
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            case .distilled:
                PageSidebar(
                    pages: store.pages,
                    selectedPageID: $selectedPageID
                )
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            }
        } detail: {
            switch mode {
            case .raw:
                rawDetailView
            case .distilled:
                distilledDetailView
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var rawDetailView: some View {
        if store.thoughts.isEmpty {
            ContentUnavailableView(
                "No Thoughts Yet",
                systemImage: "text.bubble",
                description: Text("Capture one with option+space.")
            )
        } else if filteredThoughts.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Raw Thoughts")
                            .font(.title2.weight(.semibold))

                        Text(rawSelectionMode ? "\(selectedThoughtIDs.count) selected" : "\(filteredThoughts.count) visible")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                Divider()

                List(filteredThoughts) { thought in
                    RawThoughtRow(
                        thought: thought,
                        page: store.page(with: thought.pageID),
                        isSelecting: rawSelectionMode,
                        isSelected: selectedThoughtIDs.contains(thought.id),
                        onToggleSelection: {
                            toggleRawSelection(thought.id)
                        },
                        onDelete: {
                            pendingThoughtDeletion = thought
                        }
                    )
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var distilledDetailView: some View {
        if let selectedPage {
            PageDetailView(
                page: selectedPage,
                pages: store.pages,
                thoughts: linkedThoughts(for: selectedPage),
                childPages: childPages(for: selectedPage.id),
                viewMode: pageViewMode,
                store: store,
                onDelete: {
                    pendingPageDeletion = selectedPage
                },
                onSelectPage: { pageID in
                    selectedPageID = pageID
                }
            )
        } else {
            ContentUnavailableView(
                store.pages.isEmpty ? "No Pages Yet" : "Select a Page",
                systemImage: "doc.text.magnifyingglass",
                description: Text(store.pages.isEmpty ? "New notebook pages appear after thoughts are processed." : "Choose a page in the sidebar.")
            )
        }
    }

    private var selectedPage: ThoughtPage? {
        selectedPageID.flatMap { id in
            store.pages.first { $0.id == id }
        }
    }

    private var deleteThoughtBinding: Binding<Bool> {
        Binding(
            get: { pendingThoughtDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingThoughtDeletion = nil
                }
            }
        )
    }

    private var deletePageBinding: Binding<Bool> {
        Binding(
            get: { pendingPageDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingPageDeletion = nil
                }
            }
        )
    }

    private var proposalBinding: Binding<ReorganizationProposal?> {
        Binding(
            get: { reorganizationProposal },
            set: { reorganizationProposal = $0 }
        )
    }

    private func ensureSelection() {
        guard !store.pages.isEmpty else {
            selectedPageID = nil
            return
        }

        if let selectedPageID, store.pages.contains(where: { $0.id == selectedPageID }) {
            return
        }

        selectedPageID = store.pages.first(where: { $0.parentID == nil })?.id ?? store.pages[0].id
    }

    private func linkedThoughts(for page: ThoughtPage) -> [Thought] {
        let ids = Set(page.thoughtIDs)
        return store.thoughts
            .filter { ids.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func childPages(for parentID: UUID) -> [ThoughtPage] {
        store.pages
            .filter { $0.parentID == parentID }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func toggleRawSelection(_ id: UUID) {
        if selectedThoughtIDs.contains(id) {
            selectedThoughtIDs.remove(id)
        } else {
            selectedThoughtIDs.insert(id)
        }
    }
}

private struct RawManagementSidebar: View {
    let visibleThoughtCount: Int
    let totalThoughtCount: Int
    @Binding var selectionMode: Bool
    @Binding var selectedThoughtIDs: Set<UUID>

    var body: some View {
        List {
            Section {
                Label("\(totalThoughtCount) thoughts", systemImage: "text.bubble")
                Label("\(visibleThoughtCount) visible", systemImage: "line.3.horizontal.decrease.circle")

                if selectionMode {
                    Label("\(selectedThoughtIDs.count) selected", systemImage: "checkmark.circle")
                }
            }

            if selectionMode {
                Section {
                    Text("Use the top toolbar to select all, clear, or delete selected thoughts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Thoughts")
    }
}

private struct RawThoughtRow: View {
    let thought: Thought
    let page: ThoughtPage?
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isSelecting {
                Button(action: onToggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(thought.title ?? "Untitled Thought")
                    .font(.headline)
                    .lineLimit(2)

                Text(highlightedRawText)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let distilled = thought.distilled, !distilled.isEmpty {
                    Text(distilled)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                HStack(spacing: 10) {
                    Text(thought.createdAt.formatted(date: .abbreviated, time: .shortened))

                    if let page {
                        Label(page.title, systemImage: "doc.text")
                            .foregroundStyle(Color.thoughtCategoryColor(hex: page.colorHex))
                    }

                    if !thought.tags.isEmpty {
                        Text(thought.tags.map { "#\($0)" }.joined(separator: " "))
                    }

                    if thought.processingError != nil {
                        Label("Processing failed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            if !isSelecting {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete thought")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                onToggleSelection()
            }
        }
    }

    private var highlightedRawText: AttributedString {
        var value = AttributedString(thought.text)
        guard
            let prefixLength = thought.themeHintPrefixLength,
            prefixLength > 0,
            prefixLength <= thought.text.count
        else {
            return value
        }

        let end = value.index(value.startIndex, offsetByCharacters: prefixLength)
        value[value.startIndex..<end].foregroundColor = Color.thoughtCategoryColor(hex: thought.themeHintColorHex)
        value[value.startIndex..<end].font = .body.bold()
        return value
    }
}

private struct PageSidebar: View {
    let pages: [ThoughtPage]
    @Binding var selectedPageID: UUID?

    private var nodes: [PageNode] {
        PageNode.roots(from: pages)
    }

    var body: some View {
        List(selection: $selectedPageID) {
            if nodes.isEmpty {
                Text("No pages")
                    .foregroundStyle(.secondary)
            } else {
                OutlineGroup(nodes, children: \.children) { node in
                    Label {
                        HStack {
                            Text(node.page.title)
                                .lineLimit(1)

                            if node.page.isStale {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .help("Page may need regeneration")
                            }
                        }
                    } icon: {
                        Image(systemName: (node.children?.isEmpty ?? true) ? "doc.text" : "folder")
                            .foregroundStyle(Color.thoughtCategoryColor(hex: node.page.colorHex))
                    }
                    .tag(node.page.id)
                }
            }
        }
        .navigationTitle("Pages")
    }
}

private struct PageDetailView: View {
    let page: ThoughtPage
    let pages: [ThoughtPage]
    let thoughts: [Thought]
    let childPages: [ThoughtPage]
    let viewMode: LibraryWindow.PageViewMode
    let store: ThoughtStore
    let onDelete: () -> Void
    let onSelectPage: (UUID) -> Void

    @State private var editedTitle = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 10) {
                    TextField("Page title", text: $editedTitle, onCommit: commitTitle)
                        .font(.system(size: 28, weight: .bold))
                        .textFieldStyle(.plain)

                    if page.isStale {
                        Label("Stale", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    Circle()
                        .fill(Color.thoughtCategoryColor(hex: page.colorHex))
                        .frame(width: 12, height: 12)
                }

                HStack(spacing: 8) {
                    MovePageMenu(page: page, pages: pages, store: store)

                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                }

                if !page.summary.isEmpty {
                    Text(page.summary)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !childPages.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Subpages")
                            .font(.headline)

                        ForEach(childPages) { childPage in
                            Button {
                                onSelectPage(childPage.id)
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(childPage.title)
                                            .font(.callout.weight(.medium))
                                        if !childPage.summary.isEmpty {
                                            Text(childPage.summary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        }
                    }
                }

                switch viewMode {
                case .synthesis:
                    synthesisView
                case .distilled:
                    distilledView
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear {
            editedTitle = page.title
        }
        .onChange(of: page.id) { _, _ in
            editedTitle = page.title
        }
        .onChange(of: page.title) { _, title in
            editedTitle = title
        }
    }

    private var distilledView: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !page.bodyMarkdown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Distilled Notes")
                        .font(.headline)

                    MarkdownDocumentView(markdown: page.bodyMarkdown)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Raw Ideas")
                    .font(.headline)

                if thoughts.isEmpty {
                    Text("No raw thoughts are linked to this page yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(thoughts) { thought in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(thought.title ?? thought.text)
                                .font(.callout.weight(.medium))
                            Text(thought.text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(thought.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var synthesisView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Synthesis")
                    .font(.headline)

                if page.isStale {
                    Label("Updating", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if let synthesizedAt = page.synthesizedAt {
                    Text(synthesizedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if let synthesisMarkdown = page.synthesisMarkdown, !synthesisMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownDocumentView(markdown: synthesisMarkdown)
            } else if page.isStale {
                ProgressView("Synthesizing page")
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            } else {
                Text("Synthesis will appear after AI processing.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitTitle() {
        store.renamePage(page.id, title: editedTitle)
        ThoughtProcessor.shared.synthesizeStalePages()
    }
}

private extension Color {
    static func thoughtCategoryColor(hex: String?) -> Color {
        guard let hex else {
            return .accentColor
        }

        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return .accentColor
        }

        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private struct MovePageMenu: View {
    let page: ThoughtPage
    let pages: [ThoughtPage]
    let store: ThoughtStore

    var body: some View {
        Menu {
            Button("Top Level") {
                store.movePage(page.id, to: nil)
                ThoughtProcessor.shared.synthesizeStalePages()
            }

            Divider()

            ForEach(validParents) { candidate in
                Button(candidate.title) {
                    store.movePage(page.id, to: candidate.id)
                    ThoughtProcessor.shared.synthesizeStalePages()
                }
            }
        } label: {
            Label("Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
        }
    }

    private var validParents: [ThoughtPage] {
        let descendants = descendantIDs(of: page.id)
        return pages
            .filter { $0.id != page.id && !descendants.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func descendantIDs(of pageID: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        var frontier = [pageID]

        while let currentID = frontier.popLast() {
            let children = pages.filter { $0.parentID == currentID }
            for child in children where !result.contains(child.id) {
                result.insert(child.id)
                frontier.append(child.id)
            }
        }

        return result
    }
}

private struct ReorganizationPreviewSheet: View {
    let proposal: ReorganizationProposal
    let store: ThoughtStore
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tidy Preview")
                    .font(.title2.weight(.semibold))

                Spacer()

                Button("Cancel", action: onCancel)
                Button("Apply", action: onApply)
                    .buttonStyle(.borderedProminent)
            }

            if !proposal.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.headline)
                    ForEach(proposal.notes, id: \.self) { note in
                        Text(note)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("\(proposal.pages.count) pages proposed, \(proposal.deletedPageIDs.count) existing pages removed or replaced.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(proposal.pages) { page in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(page.title)
                                .font(.headline)

                            if page.existingPageID == nil {
                                Text("New")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                            } else {
                                Text("Existing")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !page.summary.isEmpty {
                            Text(page.summary)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Text("\(page.thoughtIDs.count) linked thoughts")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }
}

private struct PageNode: Identifiable {
    let page: ThoughtPage
    let children: [PageNode]?

    var id: UUID {
        page.id
    }

    static func roots(from pages: [ThoughtPage]) -> [PageNode] {
        let childrenByParentID = Dictionary(grouping: pages, by: \.parentID)
        let pageIDs = Set(pages.map(\.id))
        let roots = pages
            .filter { page in
                guard let parentID = page.parentID else {
                    return true
                }

                return !pageIDs.contains(parentID)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        return roots.map { node(for: $0, childrenByParentID: childrenByParentID) }
    }

    private static func node(
        for page: ThoughtPage,
        childrenByParentID: [UUID?: [ThoughtPage]]
    ) -> PageNode {
        let children = (childrenByParentID[page.id] ?? [])
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { node(for: $0, childrenByParentID: childrenByParentID) }

        return PageNode(page: page, children: children.isEmpty ? nil : children)
    }
}
