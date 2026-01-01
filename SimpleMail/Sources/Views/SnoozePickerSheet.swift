import SwiftUI

// MARK: - Snooze Picker Sheet

struct SnoozePickerSheet: View {
    let onSelect: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showCustomPicker = false
    @State private var customDate = Date()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SnoozeOption.allCases, id: \.self) { option in
                        Button(action: {
                            if let date = option.date {
                                onSelect(date)
                                dismiss()
                            } else {
                                showCustomPicker = true
                            }
                        }) {
                            HStack {
                                Image(systemName: option.icon)
                                    .foregroundStyle(option.color)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                        .foregroundStyle(.primary)

                                    if let subtitle = option.subtitle {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if option == .custom {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Snooze until...")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showCustomPicker) {
                CustomSnoozePickerView(
                    date: $customDate,
                    onConfirm: {
                        onSelect(customDate)
                        dismiss()
                    }
                )
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Snooze Options

enum SnoozeOption: CaseIterable {
    case laterToday
    case tonight
    case tomorrow
    case thisWeekend
    case nextWeek
    case custom

    var title: String {
        switch self {
        case .laterToday: return "Later Today"
        case .tonight: return "Tonight"
        case .tomorrow: return "Tomorrow"
        case .thisWeekend: return "This Weekend"
        case .nextWeek: return "Next Week"
        case .custom: return "Pick a Date & Time"
        }
    }

    var subtitle: String? {
        guard let date = date else { return nil }

        let formatter = DateFormatter()

        switch self {
        case .laterToday:
            formatter.timeStyle = .short
            return formatter.string(from: date)

        case .tonight:
            formatter.timeStyle = .short
            return formatter.string(from: date)

        case .tomorrow:
            formatter.dateFormat = "EEEE, h:mm a"
            return formatter.string(from: date)

        case .thisWeekend:
            formatter.dateFormat = "EEEE, h:mm a"
            return formatter.string(from: date)

        case .nextWeek:
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: date)

        case .custom:
            return nil
        }
    }

    var icon: String {
        switch self {
        case .laterToday: return "clock"
        case .tonight: return "moon.fill"
        case .tomorrow: return "sun.max.fill"
        case .thisWeekend: return "figure.walk"
        case .nextWeek: return "calendar"
        case .custom: return "calendar.badge.clock"
        }
    }

    var color: Color {
        switch self {
        case .laterToday: return .orange
        case .tonight: return .purple
        case .tomorrow: return .yellow
        case .thisWeekend: return .green
        case .nextWeek: return .blue
        case .custom: return .gray
        }
    }

    var date: Date? {
        let calendar = Calendar.current
        let now = Date()

        switch self {
        case .laterToday:
            // 3 hours from now, or 6 PM if it's already late
            guard let threeHoursLater = calendar.date(byAdding: .hour, value: 3, to: now),
                  let sixPM = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) else {
                return nil
            }

            if calendar.component(.hour, from: now) >= 15 {
                // After 3 PM, suggest 6 PM
                return sixPM > now ? sixPM : threeHoursLater
            }
            return threeHoursLater

        case .tonight:
            // 8 PM today
            guard let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) else {
                return nil
            }
            return tonight > now ? tonight : nil

        case .tomorrow:
            // 8 AM tomorrow
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else {
                return nil
            }
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)

        case .thisWeekend:
            // Saturday 9 AM
            var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            components.weekday = 7 // Saturday
            components.hour = 9
            components.minute = 0

            guard let saturday = calendar.date(from: components) else {
                return nil
            }

            // If it's already Saturday or Sunday, use next Saturday
            let weekday = calendar.component(.weekday, from: now)
            if weekday >= 7 {
                return calendar.date(byAdding: .day, value: 7, to: saturday)
            }
            return saturday

        case .nextWeek:
            // Monday 8 AM
            var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            components.weekday = 2 // Monday
            components.hour = 8
            components.minute = 0

            guard let monday = calendar.date(from: components),
                  let nextMonday = calendar.date(byAdding: .weekOfYear, value: 1, to: monday) else {
                return nil
            }
            return nextMonday

        case .custom:
            return nil
        }
    }
}

// MARK: - Custom Snooze Picker

struct CustomSnoozePickerView: View {
    @Binding var date: Date
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker(
                    "Snooze until",
                    selection: $date,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .padding()

                Spacer()
            }
            .navigationTitle("Pick a time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onConfirm()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SnoozePickerSheet(onSelect: { _ in })
}
