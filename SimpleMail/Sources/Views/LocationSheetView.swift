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

    @Binding var selectedMailbox: Mailbox
    let currentAccount: AuthService.Account?
    let accounts: [AuthService.Account]
    let onSelectMailbox: (Mailbox) -> Void
    let onSelectScope: (InboxLocationScope) -> Void

    @State private var scopeSelection: InboxLocationScope = .unified

    private var isUnified: Bool {
        if case .unified = scopeSelection {
            return true
        }
        return false
    }

    private var scopeLabel: String {
        switch scopeSelection {
        case .unified:
            return "Unified Inbox"
        case .account(let account):
            return account.name.isEmpty ? account.email : account.name
        }
    }

    private var availableMailboxes: [Mailbox] {
        if isUnified {
            return [.inbox]
        }
        return [.inbox, .starred, .drafts, .sent, .archive, .trash]
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
                Section("Inbox scope") {
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
                        HStack(spacing: 8) {
                            Label("Inbox scope", systemImage: "tray.full")
                            Spacer()
                            Text(scopeLabel)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
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
                    }
                }

                Section {
                    NavigationLink("Manage accounts…") {
                        SettingsView()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Location")
            .presentationDetents([.height(320), .medium])
            .presentationDragIndicator(.visible)
            .onAppear {
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
                HStack {
                    Label("Unified Inbox", systemImage: "tray.full")
                    Spacer()
                    if case .unified = current {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }

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
                .foregroundStyle(isSelected ? .accentColor : .secondary)
            Text(kind.rawValue)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }
}
