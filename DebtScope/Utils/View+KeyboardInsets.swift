import SwiftUI

#if os(iOS)
extension View {
    @ViewBuilder
    func bottomScrollContentInset(_ inset: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            self.contentMargins(.bottom, inset, for: .scrollContent)
        } else {
            self.padding(.bottom, inset)
        }
    }
}
#else
extension View {
    func bottomScrollContentInset(_ inset: CGFloat) -> some View {
        self
    }
}
#endif
