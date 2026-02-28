import SwiftUI

extension Date {
    func timesheetDayString() -> String {
        formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

struct TimesheetHeaderCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(14)
        .background(DS.Colors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct TimesheetLabeledMenu: View {
    let title: String
    let selectionTitle: String
    let isInteractive: Bool
    private let content: AnyView

    init(
        title: String,
        selectionTitle: String,
        isInteractive: Bool = true,
        @ViewBuilder content: () -> some View
    ) {
        self.title = title
        self.selectionTitle = selectionTitle
        self.isInteractive = isInteractive
        self.content = AnyView(content())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            if isInteractive {
                Menu {
                    content
                } label: {
                    selectionLabel
                }
                .accessibilityLabel("\(title) filter")
            } else {
                selectionLabel
            }
        }
    }

    private var selectionLabel: some View {
        HStack(spacing: 8) {
            Text(selectionTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Colors.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            if isInteractive {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DS.Colors.background.opacity(0.8), in: Capsule())
    }
}

struct TimesheetListCard<Header: View, Rows: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            rows
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .background(DS.Colors.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct TimesheetColumnHeaderRow: View {
    let leadingTitle: String

    var body: some View {
        HStack(spacing: 8) {
            Text(leadingTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Start")
                .frame(width: 95, alignment: .leading)
            Text("End")
                .frame(width: 95, alignment: .leading)
            Text("Time")
                .frame(width: 72, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}
