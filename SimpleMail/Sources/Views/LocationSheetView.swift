import SwiftUI

enum InboxLocationScope: Equatable {
    case unified
    case account(AuthService.Account)

    var displayName: String {
        switch self {
        case .unified:
            return "Unified Inbox"
        case .account(let account):
            return account.name.isEmpty ? account.email : account.name
        }
    }
}

struct LocationSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthService.shared
    @Binding var selectedMailbox: Mailbox
    let onSelectMailbox: (Mailbox) -> Void
    let onSelectScope: (InboxLocationScope) -> Void

    @State private var scopeSelection: InboxLocationScope = .unified
    @State private var sheetDetent: PresentationDetent = .large

    private var accounts: [AuthService.Account] { auth.accounts }
    private var currentAccount: AuthService.Account? { auth.currentAccount }

    private var isUnified: Bool {
        if case .unified = scopeSelection {
            return true
        }
        return false
    }

    private var scopeName: String {
        switch scopeSelection {
        case .unified:
            return "Unified Inbox"
        case .account(let account):
            return account.name.isEmpty ? "Account" : account.name
        }
    }

    private var scopeEmail: String {
        switch scopeSelection {
        case .unified:
            return "All accounts"
        case .account(let account):
            return account.email
        }
    }

    private var availableMailboxes: [Mailbox] {
        if isUnified {
            return [.inbox]
        }
        return [.inbox, .starred, .drafts, .sent, .archive, .trash]
    }

    private var moreMailboxes: [Mailbox] {
        []
    }

    private var selectedMailboxForDisplay: Mailbox {
        if isUnified {
            return .inbox
        }
        return selectedMailbox
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        InboxScopePickerView(
                            current: $scopeSelection,
                            accounts: accounts,
                            onSelectScope: { scope in
                                scopeSelection = scope
                                onSelectScope(scope)
                            }
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            Text(scopeName)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(scopeEmail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("Account")
                }

                Section("Mailboxes") {
                    ForEach(availableMailboxes, id: \.self) { mailbox in
                        Button {
                            if isUnified {
                                onSelectMailbox(.allInboxes)
                            } else {
                                onSelectMailbox(mailbox)
                            }
                            dismiss()
                        } label: {
                            MailboxRow(kind: mailbox, isSelected: mailbox == selectedMailboxForDisplay)
                        }
                        .buttonStyle(.plain)
                    }
                    if !moreMailboxes.isEmpty {
                        NavigationLink {
                            LocationMoreMailboxesView(
                                mailboxes: moreMailboxes,
                                selectedMailbox: selectedMailboxForDisplay,
                                onSelectMailbox: { mailbox in
                                    onSelectMailbox(mailbox)
                                    dismiss()
                                }
                            )
                        } label: {
                            Label("More…", systemImage: "ellipsis")
                        }
                    }
                }

                Section {
                    NavigationLink("Manage accounts…") {
                        SettingsView()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .navigationTitle("Mailboxes")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.large], selection: $sheetDetent)
            .presentationDragIndicator(.visible)
            .onAppear {
                if selectedMailbox == .allInboxes {
                    scopeSelection = .unified
                } else if let account = currentAccount {
                    scopeSelection = .account(account)
                } else {
                    scopeSelection = .unified
                }
                sheetDetent = .large
            }
            .onChange(of: auth.currentAccount?.id) { _, _ in
                if selectedMailbox == .allInboxes {
                    scopeSelection = .unified
                } else if let account = currentAccount {
                    scopeSelection = .account(account)
                } else {
                    scopeSelection = .unified
                }
            }
        }
    }
}

struct InboxScopePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var current: InboxLocationScope
    let accounts: [AuthService.Account]
    let onSelectScope: (InboxLocationScope) -> Void

    var body: some View {
        List {
            Button {
                current = .unified
                onSelectScope(.unified)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tray.full")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unified Inbox")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text("All accounts")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if case .unified = current {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            ForEach(accounts, id: \.id) { account in
                Button {
                    current = .account(account)
                    onSelectScope(.account(account))
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Text(account.name.prefix(1).uppercased())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name.isEmpty ? account.email : account.name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(account.email)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        if case .account(let selected) = current, selected.id == account.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Inbox Scope")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MailboxRow: View {
    let kind: Mailbox
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(kind.rawValue)
                .foregroundStyle(.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

struct LocationMoreMailboxesView: View {
    let mailboxes: [Mailbox]
    let selectedMailbox: Mailbox
    let onSelectMailbox: (Mailbox) -> Void

    var body: some View {
        List {
            ForEach(mailboxes, id: \.self) { mailbox in
                Button {
                    onSelectMailbox(mailbox)
                } label: {
                    MailboxRow(kind: mailbox, isSelected: mailbox == selectedMailbox)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Mailboxes")
        .navigationBarTitleDisplayMode(.inline)
    }
}
