import SwiftUI

struct PrimaryInboxRulesView: View {
    var body: some View {
        List {
            Section {
                ForEach(PrimaryRule.allCases) { rule in
                    Toggle(rule.title, isOn: Binding(
                        get: { InboxPreferences.isPrimaryRuleEnabled(rule) },
                        set: { InboxPreferences.setPrimaryRuleEnabled(rule, $0) }
                    ))
                }
            } header: {
                Text("Primary includes")
            } footer: {
                Text("Primary controls what appears in the Primary tab. Money and security items are good defaults.")
            }
        }
        .navigationTitle("Primary Inbox")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        PrimaryInboxRulesView()
    }
}
