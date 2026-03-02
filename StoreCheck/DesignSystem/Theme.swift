import SwiftUI

enum DS {
    enum Spacing {
        static let xs: CGFloat = 6
        static let s: CGFloat = 10
        static let m: CGFloat = 16
        static let l: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 16
        static let button: CGFloat = 14
    }

    enum Metrics {
        static let cardPadding: CGFloat = 16
        static let rowHeight: CGFloat = 52
        static let iconSize: CGFloat = 18
    }

    enum Colors {
        static let background = Color(uiColor: .systemBackground)
        static let card = Color(uiColor: .secondarySystemBackground)
        static let elevated = Color(uiColor: .tertiarySystemBackground)
        static let primary = Color("AppPrimary")
        static let textPrimary = Color(uiColor: .label)
        static let textSecondary = Color(uiColor: .secondaryLabel)
        static let separator = Color(uiColor: .separator)
        static let destructive = Color(uiColor: .systemRed)
        static let success = Color(uiColor: .systemGreen)
        static let warning = Color(uiColor: .systemOrange)
    }

    enum Typography {
        static let largeTitle = Font.largeTitle.weight(.bold)
        static let title = Font.title2.weight(.bold)
        static let headline = Font.headline
        static let body = Font.body
        static let caption = Font.caption
    }
}

struct CardView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(DS.Metrics.cardPadding)
            .background(DS.Colors.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DS.Metrics.rowHeight)
            .background(DS.Colors.primary.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DS.Metrics.rowHeight)
            .background(DS.Colors.elevated.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
                    .stroke(DS.Colors.separator.opacity(0.25), lineWidth: 1)
            }
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(DS.Colors.destructive)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DS.Metrics.rowHeight)
            .background(DS.Colors.destructive.opacity(configuration.isPressed ? 0.16 : 0.11))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
    }
}

enum BadgeStyle {
    case approved, rejected, inside, outside, open, closed, neutral

    var title: String {
        switch self {
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        case .inside: return "Inside"
        case .outside: return "Outside"
        case .open: return "Open"
        case .closed: return "Closed"
        case .neutral: return "Info"
        }
    }

    var color: Color {
        switch self {
        case .approved, .inside, .closed: return DS.Colors.success
        case .rejected, .outside: return DS.Colors.destructive
        case .open, .neutral: return DS.Colors.warning
        }
    }
}

struct StatBadge: View {
    let style: BadgeStyle
    var text: String? = nil

    var body: some View {
        Text(text ?? style.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(style.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(style.color.opacity(0.15), in: Capsule())
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var ctaTitle: String?
    var ctaAction: (() -> Void)?

    var body: some View {
        CardView {
            VStack(spacing: DS.Spacing.s) {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(DS.Colors.primary)
                Text(title)
                    .font(DS.Typography.headline)
                Text(message)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                if let ctaTitle, let ctaAction {
                    Button(ctaTitle, action: ctaAction)
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, DS.Spacing.xs)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct LoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: DS.Spacing.s) {
                ProgressView()
                Text(message)
                    .font(DS.Typography.body)
            }
            .padding(20)
            .background(DS.Colors.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
    }
}

struct BannerView: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack {
            Image(systemName: isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer()
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .background((isError ? DS.Colors.destructive : DS.Colors.success).opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
    }
}

extension View {
    func cardStyle() -> some View {
        self.modifier(CardStyle())
    }
}

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(DS.Metrics.cardPadding)
            .background(DS.Colors.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}
