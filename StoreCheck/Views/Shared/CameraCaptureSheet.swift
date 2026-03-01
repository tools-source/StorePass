import AVFoundation
import SwiftUI
import UIKit

struct CameraCaptureSheet: View {
    @Binding var isPresented: Bool
    let title: String
    let onCaptured: (UIImage) -> Void

    @StateObject private var cameraService = CameraCaptureService()
    @State private var didRunInitialSetup = false

    var body: some View {
        NavigationStack {
            Group {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    CustomCameraView(cameraService: cameraService) {
                        cameraService.capturePhoto { image in
                            guard let image else {
                                PhotoVerifyLogger.log("[UI] camera capture returned nil image")
                                return
                            }

                            PhotoVerifyLogger.log("[UI] image captured size=\(Int(image.size.width))x\(Int(image.size.height))")
                            onCaptured(image)
                            isPresented = false
                        }
                    }
                    // ✅ avoids "Cannot infer contextual base in reference to member 'bottom'"
                    .ignoresSafeArea(.all, edges: .bottom)
                } else {
                    unavailableUI(message: "Camera not available on this device.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        PhotoVerifyLogger.log("[UI] camera sheet canceled")
                        isPresented = false
                    }
                }
            }
        }
        .onAppear {
            PhotoVerifyLogger.log("[UI] camera sheet opened title=\(title)")
            guard !didRunInitialSetup else { return }
            didRunInitialSetup = true

            Task {
                let granted = await cameraService.requestCameraPermissionIfNeeded()
                guard granted else {
                    PhotoVerifyLogger.log("[UI] camera sheet setup stopped: permission not granted")
                    return
                }

                cameraService.configureSessionIfNeeded()
                cameraService.startSession()
                cameraService.updateRotationForCurrentDevice()
            }
        }
        .onDisappear {
            PhotoVerifyLogger.log("[UI] camera sheet dismissed")
            didRunInitialSetup = false
            cameraService.stopSession()
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

struct CustomCameraView: View {
    @ObservedObject var cameraService: CameraCaptureService
    let onCaptureTap: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreviewView(session: cameraService.session)
                .overlay(alignment: .top) {
                    if let error = cameraService.lastErrorMessage {
                        Text(error)
                            .font(.footnote)
                            .padding(8)
                            .background(.black.opacity(0.7))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.top, 16)
                    }
                }

            Button(action: onCaptureTap) {
                Circle()
                    .fill(.white)
                    .frame(width: 76, height: 76)
                    .overlay {
                        Circle()
                            .stroke(.black.opacity(0.2), lineWidth: 2)
                            .padding(6)
                    }
            }
            .padding(.bottom, 28)
        }
        // ✅ Keep portrait-only stable (no orientation fight / no iOS 17 deprecated API)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            cameraService.updateRotationForCurrentDevice()
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session

        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session
    }
}

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Unexpected layer type for PreviewContainerView")
        }
        return layer
    }
}
