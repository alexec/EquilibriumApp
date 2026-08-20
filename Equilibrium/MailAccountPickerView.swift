import SwiftUI

/// Lets the user point Equilibrium at one Mail account.
///
/// Same shape and the same argument as `CalendarPickerView`: most people
/// have work and personal mail on the same Mac, and choosing work means the
/// personal account is never read. Not filtered afterwards — the account is
/// what the AppleScript asks Mail for, so the other mailbox's messages
/// never reach the app.
///
/// "All accounts" stays as the unset default, reading Mail's unified inbox,
/// so the column populates before anyone opens preferences.
struct MailAccountPickerView: View {
    let accounts: [SelectableMailAccount]
    /// The chosen account, or `nil` when the unified inbox is read.
    let selection: String?
    /// Which mailbox the last fetch actually read.
    let scope: MailScope
    let onChange: (String?) -> Void

    private static let allTag = ""

    /// True when an account was picked and has since been removed from
    /// Mail. Worth saying: the fetch quietly falls back to the unified
    /// inbox in that case, which is more mail than was asked for.
    private var selectionIsMissing: Bool {
        guard let selection else { return false }
        return !accounts.contains { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mail account to read")
                .font(.system(size: 12, weight: .medium))

            if accounts.isEmpty {
                Text("No mail accounts available.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { selection ?? Self.allTag },
                    set: { onChange($0 == Self.allTag ? nil : $0) }
                )) {
                    Text("All accounts").tag(Self.allTag)
                    ForEach(accounts) { account in
                        row(for: account).tag(account.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                if selectionIsMissing {
                    Text("That account is no longer in Mail — every account is being read.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if scope == .fellBackToAllAccounts {
                    // The account is still in Mail but its inbox wouldn't
                    // open — an inbox not called INBOX, or Mail mid-sync.
                    // Said out loud because the consequence is more mail on
                    // screen than was asked for, and the picker above is
                    // otherwise sitting there claiming the opposite.
                    Text("Mail wouldn't open that account's inbox — every account is being read.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The address travels with the name for the same reason it does in the
    /// calendar picker: a menu picker shows only the selected row when
    /// closed, and two accounts called "Work" are told apart by the address.
    private func row(for account: SelectableMailAccount) -> some View {
        let summary = account.addressSummary
        return Text(summary.isEmpty ? account.name : "\(account.name) — \(summary)")
    }
}
