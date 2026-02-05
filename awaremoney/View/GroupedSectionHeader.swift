import SwiftUI

struct GroupedSectionHeader: View {
    private let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .textCase(.none)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
