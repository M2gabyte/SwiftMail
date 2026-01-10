import SwiftUI

struct BriefingView: View {
    @StateObject var viewModel = BriefingViewModel()
    let onOpenEmail: (Email) -> Void = { _ in }

    var body: some View {
        ContentUnavailableView(
            "Briefing disabled",
            systemImage: "lightbulb.slash",
            description: Text("This build ships without Briefing AI. Switch back to Inbox to continue.")
        )
    }
}
