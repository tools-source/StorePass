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
    @State private var cameraUnavailableMessage: String?

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
                } else if let cameraUnavailableMessage {
                    VStack(spacing: DS.Spacing.s) {
                        Image(systemName: "camera.slash.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(DS.Colors.textSecondary)
                        Text(cameraUnavailableMessage)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(DS.Colors.textPrimary)
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

#if targetEnvironment(simulator)
        CameraLogger.log("simulatorDetected; camera start skipped")
        cameraUnavailableMessage = "Camera not available on Simulator."
        return
#endif

        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            CameraLogger.log("sourceType camera unavailable")
            cameraUnavailableMessage = "Camera not available on this device."
            return
        }

        let selectedDevice = CameraDeviceSelector.selectCamera(preferred: .front)
        guard selectedDevice != nil else {
            CameraLogger.log("selectCamera returned nil")
            cameraUnavailableMessage = "Camera not available on this device."
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        CameraLogger.log("authorizationStatus=\(CameraLogger.authorizationDescription(status))")

        switch status {
        case .authorized:
            showPicker = true
            CameraLogger.log("camera presentation allowed (authorized)")
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            CameraLogger.log("requestAccess result=\(granted)")
            permissionDenied = !granted
            showPicker = granted
        case .denied, .restricted:
            permissionDenied = true
            CameraLogger.log("camera presentation denied by permission state")
        @unknown default:
            permissionDenied = true
            CameraLogger.log("camera presentation denied due to unknown authorization state")
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

        let preferredDevice = CameraDeviceSelector.preferredPickerDevice
        picker.cameraDevice = preferredDevice
        CameraLogger.log("picker configured sourceType=camera mode=photo cameraDevice=\(CameraLogger.pickerDeviceDescription(preferredDevice))")

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
                CameraLogger.log("didFinishPickingMedia originalImage found")
                image = captured
            } else {
                CameraLogger.log("didFinishPickingMedia missing originalImage")
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            CameraLogger.log("picker cancelled")
            picker.dismiss(animated: true)
        }
    }
}

private enum CameraDeviceSelector {
    private static let discoveryTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .builtInDualCamera,
        .builtInDualWideCamera,
        .builtInTripleCamera,
    ]

    static var preferredPickerDevice: UIImagePickerController.CameraDevice {
        if UIImagePickerController.isCameraDeviceAvailable(.front) {
            return .front
        }

        if UIImagePickerController.isCameraDeviceAvailable(.rear) {
            return .rear
        }

        return .rear
    }

    static func selectCamera(preferred: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: discoveryTypes,
            mediaType: .video,
            position: .unspecified
        )

        CameraLogger.logDiscoveredDevices(discoverySession.devices)

        if preferred == .front,
           let frontWideAngle = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            CameraLogger.logSelectedDevice(frontWideAngle, reason: "default(.builtInWideAngleCamera, position: .front)")
            return frontWideAngle
        }

        if let anyPreferred = firstDevice(in: discoverySession.devices, position: preferred) {
            CameraLogger.logSelectedDevice(anyPreferred, reason: "discovery fallback for preferred position")
            return anyPreferred
        }

        if let backWideAngle = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            CameraLogger.logSelectedDevice(backWideAngle, reason: "fallback back wide angle")
            return backWideAngle
        }

        if let anyBack = firstDevice(in: discoverySession.devices, position: .back) {
            CameraLogger.logSelectedDevice(anyBack, reason: "discovery fallback for back position")
            return anyBack
        }

        CameraLogger.log("no camera device available")
        return nil
    }

    private static func firstDevice(in devices: [AVCaptureDevice], position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        for type in discoveryTypes {
            if let matched = devices.first(where: { $0.position == position && $0.deviceType == type }) {
                return matched
            }
        }

        return devices.first(where: { $0.position == position })
    }
}

private enum CameraLogger {
    static func log(_ message: String) {
        #if DEBUG
        print("[Camera] \(message)")
        #endif
    }

    static func logDiscoveredDevices(_ devices: [AVCaptureDevice]) {
        let descriptions = devices.map { device in
            "name=\(device.localizedName) type=\(device.deviceType.rawValue) position=\(positionDescription(device.position)) id=\(device.uniqueID)"
        }
        log("discovered=[\(descriptions.joined(separator: " | "))]")
    }

    static func logSelectedDevice(_ device: AVCaptureDevice, reason: String) {
        log("selectedDevice name=\(device.localizedName) type=\(device.deviceType.rawValue) position=\(positionDescription(device.position)) id=\(device.uniqueID) reason=\(reason)")
    }

    static func authorizationDescription(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    static func pickerDeviceDescription(_ device: UIImagePickerController.CameraDevice) -> String {
        switch device {
        case .front: return "front"
        case .rear: return "rear"
        @unknown default: return "unknown"
        }
    }

    static func positionDescription(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .front: return "front"
        case .back: return "back"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }
}
