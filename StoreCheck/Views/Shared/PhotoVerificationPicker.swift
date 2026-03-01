import PhotosUI
import SwiftUI
import UIKit

struct PhotoVerificationPicker: View {
    let title: String
    let onPickedImage: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var selectedItem: PhotosPickerItem?
    @State private var presentPicker = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: DS.Spacing.m) {
            Spacer()

            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(DS.Colors.primary)

            Text(title)
                .font(.headline)

            Button {
                presentPicker = true
            } label: {
                Label("Take Photo / Choose Photo", systemImage: "camera")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())

            if isLoading {
                ProgressView("Loading photo…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)

            Spacer()
        }
        .padding(DS.Spacing.l)
        .task {
            PhotoVerifyLogger.log("photo picker sheet opened title=\(title)")
            presentPicker = true
        }
        .photosPicker(
            isPresented: $presentPicker,
            selection: $selectedItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: selectedItem) { _, item in
            guard let item else { return }
            PhotoVerifyLogger.log("photo picker item selected title=\(title)")
            Task {
                await loadImage(item)
            }
        }
    }

    @MainActor
    private func loadImage(_ item: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                PhotoVerifyLogger.log("photo picker transfer returned nil data")
                return
            }

            guard let image = UIImage(data: data) else {
                PhotoVerifyLogger.log("photo picker failed UIImage conversion bytes=\(data.count)")
                return
            }

            PhotoVerifyLogger.log("photo picker UIImage conversion success bytes=\(data.count)")
            onPickedImage(image)
        } catch {
            PhotoVerifyLogger.log("photo picker load failure error=\(error.localizedDescription)")
        }
    }
}
