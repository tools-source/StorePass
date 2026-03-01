import AVFoundation
import SwiftUI
import UIKit

struct CameraCaptureSheet: View {
    @Binding var isPresented: Bool
    let title: String
    let onCaptured: (UIImage) -> Void

    @StateObject private var cameraService = CameraCaptureService()

    var body: some View {
        NavigationStack {
            Group {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    CustomCameraView(cameraService: cameraService) {
                        cameraService.capturePhoto { image in
                            guard let image else {
                                PhotoVerifyLogger.log("camera capture returned nil image")
                                return
                            }
                            PhotoVerifyLogger.log("image captured; size=\(Int(image.size.width))x\(Int(image.size.height))")
                            onCaptured(image)
                            isPresented = false
                        }
                    }
                    .ignoresSafeArea(edges: Edge.Set.bottom) // ✅ fixes “cannot infer .bottom”
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
            cameraService.configureSessionIfNeeded()
            cameraService.startSession()
            cameraService.updateVideoRotationAngle(0) // portrait
        }
        .onDisappear {
            cameraService.stopSession()
        }
    }

    private func unavailableUI(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
        }
        .padding(24)
    }
}

struct CustomCameraView: View {
    @ObservedObject var cameraService: CameraCaptureService
    let onCaptureTap: () -> Void

    var body: some View {
        ZStack(alignment: Alignment.bottom) { // ✅ fixes “cannot infer .bottom”
            CameraPreviewView(session: cameraService.session)

            Button(action: onCaptureTap) {
                Circle()
                    .fill(.white)
                    .frame(width: 76, height: 76)
                    .overlay {
                        Circle()
                            .stroke(.black.opacity(0.25), lineWidth: 2)
                            .padding(6)
                    }
            }
            .padding(.bottom, 28)
        }
        .overlay(alignment: .top) {
            if let error = cameraService.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .padding(8)
                    .background(.black.opacity(0.7))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 16)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            cameraService.updateVideoRotationAngle(rotationAngleForCurrentDeviceOrientation())
        }
    }

    private func rotationAngleForCurrentDeviceOrientation() -> Double {
        switch UIDevice.current.orientation {
        case .portraitUpsideDown: return 180
        case .landscapeLeft:      return 90   // device left => rotate preview right
        case .landscapeRight:     return 270
        default:                  return 0
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill

        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }

        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session
        if let connection = uiView.previewLayer.connection, connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
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