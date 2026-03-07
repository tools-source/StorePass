import SwiftUI
import UIKit

struct ManagerVerificationPhotoCard: View {
    let checkIn: CheckIn
    let checkInRepository: CheckInRepositoryProtocol

    @State private var photoURL: URL?
    @State private var photoData: Data?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var showFullscreen = false

    var body: some View {
        if checkIn.hasVerificationPhoto || checkIn.verificationPhotoPath != nil {
            CardView {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    SectionHeader(
                        "Photo verification",
                        eyebrow: "Manager only",
                        detail: "Captured at check-in and stored as manager-only proof."
                    )

                    if let photoData,
                       let image = UIImage(data: photoData) {
                        Button {
                            showFullscreen = true
                        } label: {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .frame(height: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else if let photoURL {
                        Button {
                            showFullscreen = true
                        } label: {
                            AsyncImage(url: photoURL) { phase in
                                switch phase {
                                case .empty:
                                    photoPlaceholder(message: "Loading photo…")
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 240)
                                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                case .failure:
                                    photoPlaceholder(message: "Photo preview unavailable.")
                                @unknown default:
                                    photoPlaceholder(message: "Photo preview unavailable.")
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        if let capturedAt = checkIn.verificationPhotoCapturedAt {
                            InfoRow(
                                title: "Captured",
                                value: capturedAt.formatted(date: .abbreviated, time: .shortened),
                                emphasize: true
                            )
                        }
                    } else if isLoading {
                        photoPlaceholder(message: "Loading photo…")
                    } else if let errorMessage {
                        BannerView(text: errorMessage, isError: true)
                    } else {
                        photoPlaceholder(message: "Loading photo…")
                    }
                }
            }
            .task(id: cacheKey) {
                await loadPhoto()
            }
            .fullScreenCover(isPresented: $showFullscreen) {
                NavigationStack {
                    ZStack {
                        Color.black.ignoresSafeArea()

                        if let photoData,
                           let image = UIImage(data: photoData) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding(DS.Spacing.m)
                        } else if let photoURL {
                            AsyncImage(url: photoURL) { phase in
                                switch phase {
                                case .empty:
                                    ProgressView()
                                        .tint(.white)
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .padding(DS.Spacing.m)
                                case .failure:
                                    Text("Unable to load photo.")
                                        .foregroundStyle(.white)
                                @unknown default:
                                    Text("Unable to load photo.")
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showFullscreen = false
                            }
                            .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
    }

    private var cacheKey: String {
        "\(checkIn.id)-\(checkIn.verificationPhotoPath ?? "inline")-\(checkIn.hasVerificationPhoto)"
    }

    @ViewBuilder
    private func photoPlaceholder(message: String) -> some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(DS.Colors.elevated)
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .overlay {
                VStack(spacing: DS.Spacing.s) {
                    ProgressView()
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
    }

    private func loadPhoto() async {
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            if let loadedData = try await checkInRepository.fetchVerificationPhotoData(
                checkInId: checkIn.id,
                storeId: checkIn.storeId
            ) {
                photoData = loadedData
                photoURL = nil
                errorMessage = nil
            } else if let path = checkIn.verificationPhotoPath {
                photoURL = try await checkInRepository.fetchVerificationPhotoURL(photoPath: path)
                photoData = nil
                errorMessage = nil
            } else {
                errorMessage = "Photo proof is not available for this check-in."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
