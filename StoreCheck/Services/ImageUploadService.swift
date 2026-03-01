import FirebaseStorage
import Foundation
import UIKit

struct UploadedImageResult {
    let path: String
    let downloadURL: String
}

protocol ImageUploadServiceProtocol {
    func uploadCheckInPhoto(
        image: UIImage,
        storeId: String,
        employeeId: String,
        checkinId: String,
        kind: CheckInPhotoKind
    ) async throws -> UploadedImageResult
}

enum CheckInPhotoKind: String {
    case checkIn = "checkin"
    case checkOut = "checkout"

    var filename: String {
        rawValue == "checkin" ? "checkin.jpg" : "checkout.jpg"
    }
}

final class ImageUploadService: ImageUploadServiceProtocol {
    private let maxDimension: CGFloat = 1600
    private let compressionQuality: CGFloat = 0.75

    private var storage: Storage {
        FirebaseBootstrap.assertConfigured(context: "ImageUploadService.storage")
        return Storage.storage()
    }

    func uploadCheckInPhoto(
        image: UIImage,
        storeId: String,
        employeeId: String,
        checkinId: String,
        kind: CheckInPhotoKind
    ) async throws -> UploadedImageResult {
        guard let processedImage = image.resizedMaintainingAspectRatio(maxDimension: maxDimension),
              let imageData = processedImage.jpegData(compressionQuality: compressionQuality) else {
            throw NSError(domain: "StorePass", code: 5201, userInfo: [NSLocalizedDescriptionKey: "Could not process photo."])
        }

        let path = CheckInPhotoStoragePath.makePath(storeId: storeId, employeeId: employeeId, checkinId: checkinId, kind: kind)
        let reference = storage.reference(withPath: path)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        _ = try await reference.putDataAsync(imageData, metadata: metadata)
        let url = try await reference.downloadURL()

        return UploadedImageResult(path: path, downloadURL: url.absoluteString)
    }
}

private extension UIImage {
    func resizedMaintainingAspectRatio(maxDimension: CGFloat) -> UIImage? {
        let largest = max(size.width, size.height)
        guard largest > maxDimension else { return self }

        let scale = maxDimension / largest
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
