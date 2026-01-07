import Foundation

struct InboxViewState {
    var sections: [EmailSection] = []
    var filterCounts: [InboxFilter: Int] = [:]
}
