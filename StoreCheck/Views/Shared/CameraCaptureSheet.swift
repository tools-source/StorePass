import SwiftUI
import UIKit

struct CameraCaptureSheet: View {
    @Binding var isPresented: Bool
    let title: String
    let onCaptured: (UIImage) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    SystemCameraPicker(
                        onCaptured: { image in
                            PhotoVerifyLogger.log("image captured; size=\(Int(image.size.width))x\(Int(image.size.height))")
                            onCaptured(image)
                            isPresented = false
                        },
                        onCancel: {
                            PhotoVerifyLogger.log("camera sheet canceled by user")
                            isPresented = false
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    unavailableUI(message: "Camera not available on this device.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        PhotoVerifyLogger.log("camera sheet canceled from toolbar")
                        isPresented = false
                    }
                }
            }
        }
        .onAppear {
            PhotoVerifyLogger.log("camera sheet opened title=\(title)")
        }
    }

    private func unavailableUI(message: String) -> some View {
        VStack(spacing: DS.Spacing.s) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 34))
                .foregroundStyle(DS.Colors.textSecondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(DS.Colors.textPrimary)
        }
        .padding(DS.Spacing.l)
    }
}

struct SystemCameraPicker: UIViewControllerRepresentable {
    let onCaptured: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .front
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        PhotoVerifyLogger.log("configured UIImagePickerController sourceType=camera cameraDevice=front cameraCaptureMode=photo")
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: SystemCameraPicker

        init(parent: SystemCameraPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCaptured(image)
            } else {
                PhotoVerifyLogger.log("picker returned without UIImage; treating as cancel")
                parent.onCancel()
            }
        }
    }
}

enum PhotoVerifyLogger {
    static func log(_ message: String) {
        #if DEBUG
        print("[PhotoVerify] \(message)")
        #endif
    }
}
