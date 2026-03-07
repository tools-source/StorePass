import SwiftUI

enum DS {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 22
        static let button: CGFloat = 16
        static let pill: CGFloat = 999
    }

    enum Metrics {
        static let cardPadding: CGFloat = 18
        static let rowHeight: CGFloat = 54
        static let iconSize: CGFloat = 18
        static let maxReadableWidth: CGFloat = 760
    }

    enum Colors {
        static let background = Color(red: 0.95, green: 0.97, blue: 1.00)
        static let backgroundAlt = Color(red: 1.00, green: 0.97, blue: 0.93)
        static let card = Color.white.opacity(0.92)
        static let elevated = Color(red: 0.89, green: 0.93, blue: 0.98)
        static let primary = Color(red: 0.07, green: 0.33, blue: 0.67)
        static let accent = Color(red: 0.05, green: 0.60, blue: 0.63)
        static let textPrimary = Color(red: 0.10, green: 0.14, blue: 0.22)
        static let textSecondary = Color(red: 0.36, green: 0.42, blue: 0.54)
        static let separator = Color.black.opacity(0.08)
        static let destructive = Color(red: 0.74, green: 0.16, blue: 0.20)
        static let success = Color(red: 0.08, green: 0.57, blue: 0.33)
        static let warning = Color(red: 0.78, green: 0.49, blue: 0.08)

        static let primaryGradient = LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.36, blue: 0.76),
                Color(red: 0.06, green: 0.54, blue: 0.76)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let canvasGradient = LinearGradient(
            colors: [background, backgroundAlt],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    enum Typography {
        static let hero = Font.system(size: 34, weight: .bold, design: .rounded)
        static let largeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let title = Font.system(.title2, design: .rounded).weight(.bold)
        static let headline = Font.system(.headline, design: .rounded).weight(.semibold)
        static let body = Font.system(.body, design: .rounded)
        static let caption = Font.system(.caption, design: .rounded)
        static let micro = Font.system(.caption2, design: .rounded)
        static let mono = Font.system(.caption, design: .monospaced)
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            DS.Colors.canvasGradient.ignoresSafeArea()

            Circle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 280, height: 280)
                .blur(radius: 8)
                .offset(x: -130, y: -340)

            Circle()
                .fill(DS.Colors.accent.opacity(0.18))
                .frame(width: 220, height: 220)
                .blur(radius: 12)
                .offset(x: 160, y: -250)

            Circle()
                .fill(DS.Colors.primary.opacity(0.10))
                .frame(width: 260, height: 260)
                .blur(radius: 18)
                .offset(x: 130, y: 360)
        }
    }
}

struct ScreenHeader: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(DS.Colors.primaryGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title)
                    .font(DS.Typography.title)
                    .foregroundStyle(DS.Colors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

struct MetricChip: View {
    let label: String
    let value: String
    var icon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                Text(label)
                    .font(DS.Typography.micro)
                    .foregroundStyle(DS.Colors.textSecondary)
            }

            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(DS.Colors.textPrimary)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, DS.Spacing.s)
        .background(DS.Colors.elevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct KeyValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Text(title)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(DS.Typography.body.weight(.semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
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
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(DS.Colors.card)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Colors.separator, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.05), radius: 16, x: 0, y: 8)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DS.Metrics.rowHeight)
            .background(
                DS.Colors.primaryGradient
                    .opacity(configuration.isPressed ? 0.86 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
            .shadow(color: DS.Colors.primary.opacity(0.25), radius: 8, x: 0, y: 4)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.headline)
            .foregroundStyle(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DS.Metrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
                    .fill(DS.Colors.elevated.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
                    .stroke(DS.Colors.separator, lineWidth: 1)
            }
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.headline)
            .foregroundStyle(DS.Colors.destructive)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DS.Metrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
                    .fill(DS.Colors.destructive.opacity(configuration.isPressed ? 0.20 : 0.13))
            )
    }
}

enum BadgeStyle {
    case approved
    case rejected
    case inside
    case outside
    case open
    case closed
    case neutral

    var title: String {
        switch self {
        case .approved:
            return "Approved"
        case .rejected:
            return "Rejected"
        case .inside:
            return "Inside"
        case .outside:
            return "Outside"
        case .open:
            return "Open"
        case .closed:
            return "Closed"
        case .neutral:
            return "Info"
        }
    }

    var color: Color {
        switch self {
        case .approved, .inside, .closed:
            return DS.Colors.success
        case .rejected, .outside:
            return DS.Colors.destructive
        case .open, .neutral:
            return DS.Colors.warning
        }
    }

    var icon: String {
        switch self {
        case .approved, .inside, .closed:
            return "checkmark.circle.fill"
        case .rejected, .outside:
            return "xmark.octagon.fill"
        case .open:
            return "clock.badge.exclamationmark"
        case .neutral:
            return "info.circle.fill"
        }
    }
}

struct StatBadge: View {
    let style: BadgeStyle
    var text: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: style.icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text ?? style.title)
                .font(DS.Typography.micro.weight(.semibold))
        }
        .foregroundStyle(style.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(style.color.opacity(0.14), in: Capsule())
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
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(DS.Colors.primary)

                Text(title)
                    .font(DS.Typography.headline)
                    .foregroundStyle(DS.Colors.textPrimary)

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
            Color.black.opacity(0.22)
                .ignoresSafeArea()

            VStack(spacing: DS.Spacing.s) {
                ProgressView()
                    .tint(DS.Colors.primary)
                Text(message)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.textPrimary)
            }
            .padding(22)
            .background(DS.Colors.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .stroke(DS.Colors.separator, lineWidth: 1)
            }
        }
    }
}

struct BannerView: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .background((isError ? DS.Colors.destructive : DS.Colors.success).opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
        .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 4)
    }
}

struct SkeletonLine: View {
    var width: CGFloat? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(DS.Colors.elevated)
            .frame(width: width, height: 11)
            .redacted(reason: .placeholder)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }

    func appScreenBackground() -> some View {
        background(AppBackground())
    }
}

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(DS.Metrics.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(DS.Colors.card)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Colors.separator, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.05), radius: 16, x: 0, y: 8)
    }
}
