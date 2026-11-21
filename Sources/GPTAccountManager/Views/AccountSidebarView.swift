import SwiftUI

@MainActor
private final class AccountDragSelectionCache {
    private(set) var accountIDs: Set<UUID> = []
    private var clearTask: Task<Void, Never>?

    func update(with ids: Set<UUID>) {
        clearTask?.cancel()

        if ids.isEmpty || ids.count > 1 {
            accountIDs = ids
            return
        }

        guard let id = ids.first,
              accountIDs.count > 1,
              accountIDs.contains(id) else {
            accountIDs = ids
            return
        }

        // List collapses a multi-selection to the row under the mouse just
        // before asking for the drag provider. Keep the old set briefly.
        clearTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.accountIDs = ids
        }
    }

    func cancel() {
        clearTask?.cancel()
        clearTask = nil
    }
}

struct AccountSidebarView: View {
    let store: AccountStore
    @Binding var selection: SidebarSelection?
    @Binding var selectedAccountIDs: Set<UUID>
    let rotationStates: [UUID: RotationQueueItemState]
    let onCreateGroup: () -> Void
    let onRequestMoveAccounts: (Set<UUID>, UUID?) -> Void

    @State private var listSelection: Set<SidebarSelection> = []
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var isUngroupedExpanded = true
    @State private var searchText = ""
    @State private var dragSelectionCache = AccountDragSelectionCache()

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $listSelection) {
                ForEach(store.groups) { group in
                    let accounts = filtered(store.accounts(in: group.id))
                    if !isSearching || !accounts.isEmpty {
                        groupDisclosure(group, accounts: accounts)
                    }
                }
                let ungrouped = filtered(store.accounts.filter { $0.groupID == nil })
                if !isSearching || !ungrouped.isEmpty {
                    ungroupedDisclosure(accounts: ungrouped)
                }
            }
            .overlay {
                if store.accounts.isEmpty && store.groups.isEmpty {
                    ContentUnavailableView(
                        "Нет аккаунтов",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text("Импортируйте файл LOGIN|PASS|2FA"))
                } else if isSearching && visibleAccountIDs.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, prompt: "Поиск по логину или тегу")
            .onChange(of: listSelection) { oldRows, rows in
                synchronizeFromList(rows, previousRows: oldRows)
            }

            Divider()
            controls
        }
        .navigationTitle("Аккаунты")
        .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 360)
        .onAppear {
            synchronizeFromNavigation(selection)
        }
        .onChange(of: selection) { _, navigation in
            synchronizeFromNavigation(navigation)
        }
        .onDisappear {
            dragSelectionCache.cancel()
        }
    }

    private func groupDisclosure(
        _ group: AccountGroup,
        accounts: [AccountRecord]
    ) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: group.id)) {
            ForEach(accounts) { account in accountRow(account) }
        } label: {
            groupRow(name: group.name, tag: group.tag, accountCount: accounts.count)
                .background(AccountGroupDropTarget { payload in
                    dropAccounts([payload], to: group.id)
                })
        }
        .tag(SidebarSelection.group(group.id))
    }

    private func ungroupedDisclosure(accounts: [AccountRecord]) -> some View {
        DisclosureGroup(isExpanded: ungroupedExpansionBinding) {
            ForEach(accounts) { account in accountRow(account) }
        } label: {
            groupRow(name: "Без группы", tag: nil, accountCount: accounts.count)
                .background(AccountGroupDropTarget { payload in
                    dropAccounts([payload], to: nil)
                })
        }
        .tag(SidebarSelection.ungrouped)
    }

    private func groupRow(name: String, tag: String?, accountCount: Int) -> some View {
        let subtitle = [tag, "\(accountCount) аккаунтов"]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func accountRow(_ account: AccountRecord) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                    .lineLimit(1)
                Text(accountSubtitle(account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 28)
                .help("Перетащить в группу")
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(SidebarSelection.account(account.id))
        .itemProvider {
            NSItemProvider(object: dragToken(for: account.id) as NSString)
        }
    }

    private func dragToken(for accountID: UUID) -> String {
        let effectiveIDs = AccountDragSelection.effectiveSelectedIDs(
            for: accountID,
            currentIDs: selectedAccountIDs,
            preservedIDs: dragSelectionCache.accountIDs)
        let ids = AccountDragSelection.ids(
            for: accountID,
            selectedIDs: effectiveIDs,
            orderedIDs: visibleAccountIDs)
        return AccountDragToken.encode(AccountDragPayload(accountIDs: ids))
    }

    private func accountSubtitle(_ account: AccountRecord) -> String {
        let base = AccountPresentation.sidebarSubtitle(account: account)
        guard let state = rotationStates[account.id] else { return base }
        let queue: String
        switch state {
        case .queued: queue = "2FA: очередь"
        case .running: queue = "2FA: смена"
        case .manualAction: queue = "2FA: вручную"
        case .complete: queue = "2FA: готово"
        case .failed: queue = "2FA: ошибка"
        }
        return "\(base) · \(queue)"
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: onCreateGroup) {
                Image(systemName: "plus")
            }
            .help("Новая группа")

            Spacer()

            if !selectedAccountIDs.isEmpty {
                Text("\(selectedAccountIDs.count) выбрано")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(8)
    }

    private func expansionBinding(for groupID: UUID) -> Binding<Bool> {
        Binding(
            get: { isSearching || expandedGroupIDs.contains(groupID) },
            set: { isExpanded in
                guard !isSearching else { return }
                if isExpanded {
                    expandedGroupIDs.insert(groupID)
                } else {
                    expandedGroupIDs.remove(groupID)
                }
            })
    }

    private var ungroupedExpansionBinding: Binding<Bool> {
        Binding(
            get: { isSearching || isUngroupedExpanded },
            set: { isExpanded in
                guard !isSearching else { return }
                isUngroupedExpanded = isExpanded
            })
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func filtered(_ accounts: [AccountRecord]) -> [AccountRecord] {
        AccountSearch.filter(accounts, query: searchText)
    }

    private var visibleAccountIDs: [UUID] {
        let groupedIDs = store.groups.flatMap { group in
            filtered(store.accounts(in: group.id)).map(\.id)
        }
        let ungroupedIDs = filtered(store.accounts.filter { $0.groupID == nil })
            .map(\.id)
        return groupedIDs + ungroupedIDs
    }

    private func synchronizeFromList(
        _ rows: Set<SidebarSelection>,
        previousRows: Set<SidebarSelection>
    ) {
        let normalizedRows = SidebarAccountSelection.normalizedRows(rows)
        if listSelection != normalizedRows {
            listSelection = normalizedRows
        }

        let accountIDs = SidebarAccountSelection.normalized(normalizedRows)
        if selectedAccountIDs != accountIDs {
            selectedAccountIDs = accountIDs
        }
        dragSelectionCache.update(with: accountIDs)

        let navigation = SidebarAccountSelection.navigationSelection(
            for: normalizedRows,
            previousSelections: previousRows,
            preserving: selection,
            orderedAccountIDs: visibleAccountIDs)
        if selection != navigation {
            selection = navigation
        }
    }

    private func synchronizeFromNavigation(_ navigation: SidebarSelection?) {
        let rows: Set<SidebarSelection>
        switch navigation {
        case .account(let id):
            if selectedAccountIDs.contains(id) {
                rows = Set(selectedAccountIDs.map(SidebarSelection.account))
            } else {
                rows = [.account(id)]
            }
        case .group(let id):
            rows = [.group(id)]
        case .ungrouped:
            rows = [.ungrouped]
        case nil:
            rows = []
        }

        if listSelection != rows {
            listSelection = rows
        }
        let accountIDs = SidebarAccountSelection.normalized(rows)
        if selectedAccountIDs != accountIDs {
            selectedAccountIDs = accountIDs
        }
        dragSelectionCache.update(with: accountIDs)
    }

    private func dropAccounts(_ payloads: [AccountDragPayload], to groupID: UUID?) -> Bool {
        let knownIDs = Set(store.accounts.map(\.id))
        let accountIDs = AccountDragSelection.knownIDs(
            from: payloads,
            knownIDs: knownIDs)
        guard !accountIDs.isEmpty else { return false }

        let hasChange = accountIDs.contains { id in
            store.accounts.first(where: { $0.id == id })?.groupID != groupID
        }
        guard hasChange else { return false }

        if let groupID {
            expandedGroupIDs.insert(groupID)
        } else {
            isUngroupedExpanded = true
        }
        onRequestMoveAccounts(accountIDs, groupID)
        return true
    }
}
