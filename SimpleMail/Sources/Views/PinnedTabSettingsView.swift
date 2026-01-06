import SwiftUI

struct PinnedTabSettingsView: View {
    @State private var selectedOption = InboxPreferences.getPinnedTabOption()

    var body: some View {
        List {
            Section {
                ForEach(PinnedTabOption.allCases) { option in
                    Button {
                        selectedOption = option
                        InboxPreferences.setPinnedTabOption(option)
                    } label: {
                        HStack {
                            Text(option.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedOption == option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Pinned Tab")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedOption = InboxPreferences.getPinnedTabOption()
        }
    }
}

#Preview {
    NavigationStack {
        PinnedTabSettingsView()
    }
}
