import SwiftUI
import UIKit

public extension View {
    @ViewBuilder
    func constrainForIPad(maxWidth: CGFloat = 720, alignment: Alignment = .center) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            GeometryReader { proxy in
                let available = proxy.size.width
                // Leave a little breathing room for horizontal padding
                let target = min(maxWidth, max(0, available - 32))
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    self
                        .frame(width: target, alignment: alignment)
                    Spacer(minLength: 0)
                }
                .frame(width: available, alignment: .center)
                .padding(.horizontal)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
