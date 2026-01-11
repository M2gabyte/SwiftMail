import Foundation
import SwiftUI

struct InboxViewState: Sendable {
    var sections: [EmailSection] = []
    var filterCounts: [InboxFilter: Int] = [:]
    var categoryBundles: [CategoryBundle] = []
}
