import SwiftUI

enum DS {
    enum Spacing {
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 14
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(DS.Spacing.m)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(DS.Radius.card)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}
