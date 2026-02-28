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

    enum Colors {
        static let background = Color("AppBackground")
        static let card = Color("AppCard")
        static let primary = Color("AppPrimary")
        static let textPrimary = Color("AppTextPrimary")
        static let textSecondary = Color("AppTextSecondary")
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(DS.Spacing.m)
            .background(DS.Colors.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(DS.Colors.primary.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}
