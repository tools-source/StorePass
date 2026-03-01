import AVFoundation
import SwiftUI
import UIKit

struct CameraCaptureSheet: View {
    @Binding var isPresented: Bool
    let title: String
    let onCaptured: (UIImage) -> Void

    @State private var capturedImage: UIImage?
    @State private var showPicker = false
    @State private var permissionDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.background.ignoresSafeArea()

                if let capturedImage {
                    VStack(spacing: DS.Spacing.m) {
                        Image(uiImage: capturedImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        HStack(spacing: DS.Spacing.m) {
                            Button("Retake") {
                                self.capturedImage = nil
                                showPicker = true
                            }
                            .buttonStyle(.bordered)

                            Button("Use Photo") {
                                onCaptured(capturedImage)
                                isPresented = false
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                    .padding(DS.Spacing.l)
                } else if permissionDenied {
                    VStack(spacing: DS.Spacing.s) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(DS.Colors.textSecondary)
                        Text("Camera access is required to continue.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Button("Open Settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(DS.Spacing.l)
                } else {
                    ProgressView("Opening camera…")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .task {
            await requestCameraAndPresentIfNeeded()
        }
        .sheet(isPresented: $showPicker) {
            CameraPicker(image: $capturedImage)
                .ignoresSafeArea()
        }
    }

    private func requestCameraAndPresentIfNeeded() async {
        guard capturedImage == nil else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            permissionDenied = true
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            showPicker = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionDenied = !granted
            showPicker = granted
        default:
            permissionDenied = true
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(image: $image)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        @Binding var image: UIImage?

        init(image: Binding<UIImage?>) {
            _image = image
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let captured = info[.originalImage] as? UIImage {
                image = captured
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
