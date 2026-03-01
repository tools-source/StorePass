import SwiftUI

struct PhotoViewer: View {
    let title: String
    let url: URL
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.background.ignoresSafeArea()
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } placeholder: {
                    ProgressView()
                }
                .padding(DS.Spacing.m)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone)
                }
            }
        }
    }
}
