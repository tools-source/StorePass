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
            cameraService.configureSessionIfNeeded()
            cameraService.startSession()
            cameraService.updateVideoOrientation(.portrait)
        }
        .onDisappear {
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
                            .clipShape(RoundedRectangle(cornerRadius: 8))
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
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            cameraService.updateVideoOrientation(AVCaptureVideoOrientation.current)
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session
        if let connection = uiView.previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
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

enum PhotoVerifyLogger {
    static func log(_ message: String) {
        #if DEBUG
        print("[PhotoVerify] \(message)")
        #endif
    }
}

private extension AVCaptureVideoOrientation {
    static var current: AVCaptureVideoOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .portraitUpsideDown:
            return .portraitUpsideDown
        default:
            return .portrait
        }
    }
}
