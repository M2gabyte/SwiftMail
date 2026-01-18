import SwiftUI

struct CustomLanePickerSheet: View {
    @Binding var selectedLane: PinnedTabOption
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(PinnedTabOption.allCases) { lane in
                        Button {
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
                            selectedLane = lane
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: lane.symbolName)
                                    .foregroundStyle(lane.color)
                                    .frame(width: 22)

                                Text(lane.title)
                                    .foregroundStyle(.primary)

                                Spacer()

                                if lane == selectedLane {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Custom Tab")
                } footer: {
                    Text("This changes the 3rd tab in the top bar.")
                }
            }
            .navigationTitle("Choose Lane")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    CustomLanePickerSheet(selectedLane: .constant(.money))
}
