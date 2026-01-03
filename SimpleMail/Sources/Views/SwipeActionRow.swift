import SwiftUI
import UIKit

// MARK: - Swipe Action Configuration

/// Configuration for a swipe action
struct SwipeAction {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    init(icon: String, label: String, color: Color, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.color = color
        self.action = action
    }
}

// MARK: - Swipe Action Row

/// A row component with fixed-threshold swipe actions.
/// Commits action at a fixed threshold with haptic feedback.
/// Prevents accidental over-swipes from triggering multiple states.
struct SwipeActionRow<Content: View>: View {
    let content: Content
    let leadingAction: SwipeAction?
    let trailingAction: SwipeAction?

    /// Fixed threshold distance for action commit (in points)
    private let commitThreshold: CGFloat = 80

    /// Maximum swipe distance (prevents over-swiping)
    private let maxSwipeDistance: CGFloat = 100

    /// Action icon reveal threshold
    private let revealThreshold: CGFloat = 40

    @State private var offset: CGFloat = 0
    @State private var hasCommittedLeading = false
    @State private var hasCommittedTrailing = false
    @State private var isDragging = false
    @State private var hasTriggeredHaptic = false

    @GestureState private var dragState: CGFloat = 0

    init(
        leadingAction: SwipeAction? = nil,
        trailingAction: SwipeAction? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.leadingAction = leadingAction
        self.trailingAction = trailingAction
    }

    private var effectiveOffset: CGFloat {
        let raw = offset + dragState

        // Clamp to max swipe distance in each direction
        if raw > 0 {
            return leadingAction != nil ? min(raw, maxSwipeDistance) : 0
        } else {
            return trailingAction != nil ? max(raw, -maxSwipeDistance) : 0
        }
    }

    private var isAtLeadingThreshold: Bool {
        effectiveOffset >= commitThreshold
    }

    private var isAtTrailingThreshold: Bool {
        effectiveOffset <= -commitThreshold
    }

    var body: some View {
        ZStack {
            // Background action indicators
            HStack {
                // Leading action background (swipe right to reveal)
                if let leading = leadingAction, effectiveOffset > revealThreshold {
                    leadingActionBackground(leading)
                }

                Spacer()

                // Trailing action background (swipe left to reveal)
                if let trailing = trailingAction, effectiveOffset < -revealThreshold {
                    trailingActionBackground(trailing)
                }
            }

            // Main content
            content
                .offset(x: effectiveOffset)
                .gesture(swipeGesture)
        }
        .clipped()
        .onChange(of: effectiveOffset) { _, newValue in
            checkThresholdCrossing(newValue)
        }
    }

    @ViewBuilder
    private func leadingActionBackground(_ action: SwipeAction) -> some View {
        HStack(spacing: 8) {
            Image(systemName: action.icon)
                .font(.title3)
                .fontWeight(.medium)

            if isAtLeadingThreshold {
                Text(action.label)
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
        .foregroundStyle(.white)
        .frame(width: abs(effectiveOffset), alignment: .center)
        .background(action.color)
        .scaleEffect(isAtLeadingThreshold ? 1.05 : 1.0)
        .animation(.quickSpring, value: isAtLeadingThreshold)
    }

    @ViewBuilder
    private func trailingActionBackground(_ action: SwipeAction) -> some View {
        HStack(spacing: 8) {
            if isAtTrailingThreshold {
                Text(action.label)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            Image(systemName: action.icon)
                .font(.title3)
                .fontWeight(.medium)
        }
        .foregroundStyle(.white)
        .frame(width: abs(effectiveOffset), alignment: .center)
        .background(action.color)
        .scaleEffect(isAtTrailingThreshold ? 1.05 : 1.0)
        .animation(.quickSpring, value: isAtTrailingThreshold)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .updating($dragState) { value, state, _ in
                // Only allow horizontal swipes
                if abs(value.translation.width) > abs(value.translation.height) {
                    state = value.translation.width
                }
            }
            .onChanged { value in
                isDragging = true
            }
            .onEnded { value in
                isDragging = false
                handleSwipeEnd(translation: value.translation.width)
            }
    }

    private func checkThresholdCrossing(_ newOffset: CGFloat) {
        // Leading threshold crossing (swipe right)
        if newOffset >= commitThreshold && !hasTriggeredHaptic && leadingAction != nil {
            triggerThresholdHaptic()
            hasTriggeredHaptic = true
        }
        // Trailing threshold crossing (swipe left)
        else if newOffset <= -commitThreshold && !hasTriggeredHaptic && trailingAction != nil {
            triggerThresholdHaptic()
            hasTriggeredHaptic = true
        }
        // Reset haptic flag when returning below threshold
        else if abs(newOffset) < commitThreshold {
            hasTriggeredHaptic = false
        }
    }

    private func triggerThresholdHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    private func triggerSuccessHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    private func handleSwipeEnd(translation: CGFloat) {
        let currentOffset = offset + translation

        // Check if we've crossed the commit threshold and should execute action
        if currentOffset >= commitThreshold, let leading = leadingAction, !hasCommittedLeading {
            // Mark as committed to prevent re-triggering
            hasCommittedLeading = true

            // Animate out and execute action
            withAnimation(.quickSpring) {
                offset = maxSwipeDistance + 50 // Animate past edge
            }

            triggerSuccessHaptic()

            // Execute action after brief delay for visual feedback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                leading.action()
                // Reset state
                resetState()
            }
        }
        else if currentOffset <= -commitThreshold, let trailing = trailingAction, !hasCommittedTrailing {
            // Mark as committed to prevent re-triggering
            hasCommittedTrailing = true

            // Animate out and execute action
            withAnimation(.quickSpring) {
                offset = -(maxSwipeDistance + 50) // Animate past edge
            }

            triggerSuccessHaptic()

            // Execute action after brief delay for visual feedback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                trailing.action()
                // Reset state
                resetState()
            }
        }
        else {
            // Snap back to origin
            withAnimation(.smoothSpring) {
                offset = 0
            }
            hasTriggeredHaptic = false
        }
    }

    private func resetState() {
        withAnimation(.quickSpring) {
            offset = 0
        }
        hasCommittedLeading = false
        hasCommittedTrailing = false
        hasTriggeredHaptic = false
    }
}

// MARK: - Preview

#Preview {
    List {
        SwipeActionRow(
            leadingAction: SwipeAction(
                icon: "envelope.open",
                label: "Read",
                color: .blue,
                action: { print("Mark as read") }
            ),
            trailingAction: SwipeAction(
                icon: "archivebox",
                label: "Archive",
                color: .green,
                action: { print("Archive") }
            )
        ) {
            HStack {
                VStack(alignment: .leading) {
                    Text("John Doe")
                        .font(.headline)
                    Text("Subject line here")
                        .font(.subheadline)
                    Text("Preview of the email content...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
        .listRowInsets(EdgeInsets())
    }
}
