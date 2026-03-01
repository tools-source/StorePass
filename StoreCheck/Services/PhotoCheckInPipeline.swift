import FirebaseFirestore
import FirebaseStorage
import Foundation
import UIKit

struct PhotoCheckInPipelineResult {
    let checkInId: String
    let correlationId: String
    let photoPath: String
    let photoURL: String?
}

enum PhotoCheckInPipelineError: LocalizedError {
    case preconditionFailed(String)
    case photoEncodingFailed
    case firebaseFailure(step: String, path: String?, underlying: NSError)

    var errorDescription: String? {
        switch self {
        case .preconditionFailed(let reason):
            return reason
        case .photoEncodingFailed:
            return "Could not process photo. Please try again."
        case .firebaseFailure(let step, _, let underlying):
            if underlying.domain == StorageErrorDomain,
               let code = StorageErrorCode(rawValue: underlying.code) {
                switch code {
                case .unauthenticated:
                    return "You were signed out. Please sign in and try again."
                case .unauthorized:
                    return "Upload permission was denied for your account. Please contact your manager."
                case .cancelled:
                    return "Upload was canceled. Please try again."
                case .retryLimitExceeded, .quotaExceeded:
                    return "Upload failed after multiple retries. Please try again."
                default:
                    return "Photo upload failed. Please try again."
                }
            }

            if underlying.domain == FirestoreErrorDomain,
               underlying.code == FirestoreErrorCode.permissionDenied.rawValue {
                return "Check-in permission was denied. Please verify store access and try again."
            }

            return "Check-in failed at \(step). Please try again."
        }
    }
}

protocol PhotoCheckInPipelineProtocol {
    func run(user: AppUser, store: Store, image: UIImage, locationStatus: LocationCheckState) async throws -> PhotoCheckInPipelineResult
}

final class PhotoCheckInPipeline: PhotoCheckInPipelineProtocol {
    private let db: Firestore
    private let storage: Storage
    private let compressionQuality: CGFloat

    init(
        db: Firestore? = nil,
        storage: Storage? = nil,
        compressionQuality: CGFloat = 0.75
    ) {
        FirebaseBootstrap.assertConfigured(context: "PhotoCheckInPipeline.init")
        self.db = db ?? Firestore.firestore()
        self.storage = storage ?? Storage.storage()
        self.compressionQuality = compressionQuality
    }

    func run(user: AppUser, store: Store, image: UIImage, locationStatus: LocationCheckState) async throws -> PhotoCheckInPipelineResult {
        let correlationId = UUID().uuidString
        let uid = user.id
        let storeId = store.id

        log(correlationId: correlationId, step: "start", extra: "uid=\(uid) storeId=\(storeId)")

        do {
            let managerId = try await validatePreconditions(user: user, store: store, locationStatus: locationStatus, correlationId: correlationId)
            let checkInId = UUID().uuidString

            try await createCheckInDocument(
                correlationId: correlationId,
                checkInId: checkInId,
                user: user,
                store: store,
                managerId: managerId
            )
            log(correlationId: correlationId, step: "create_doc_ok", extra: "checkInId=\(checkInId)")

            guard let jpegData = image.jpegData(compressionQuality: compressionQuality), !jpegData.isEmpty else {
                throw PhotoCheckInPipelineError.photoEncodingFailed
            }

            let photoPath = CheckInPhotoStoragePath.makePath(storeId: storeId, employeeId: uid, checkinId: checkInId, kind: .checkIn)
            log(correlationId: correlationId, step: "upload_start", extra: "bytes=\(jpegData.count) path=\(photoPath)")

            let reference = storage.reference().child(photoPath)
            let metadata = StorageMetadata()
            metadata.contentType = "image/jpeg"

            _ = try await reference.putDataAsync(jpegData, metadata: metadata)
            log(correlationId: correlationId, step: "upload_ok", extra: "path=\(photoPath)")

            var photoURLString: String?
            do {
                photoURLString = try await reference.downloadURL().absoluteString
                log(correlationId: correlationId, step: "url_ok", extra: "url=\(photoURLString ?? "nil")")
            } catch {
                let nsError = error as NSError
                logFailure(correlationId: correlationId, step: "url_failed_proceeding", error: nsError, path: photoPath)
            }

            try await updateCheckInDocumentWithPhoto(
                correlationId: correlationId,
                checkInId: checkInId,
                uid: uid,
                storeId: storeId,
                managerId: managerId,
                photoPath: photoPath,
                photoURL: photoURLString
            )
            log(correlationId: correlationId, step: "firestore_update_ok", extra: "checkInId=\(checkInId)")
            log(correlationId: correlationId, step: "mirror_update_ok", extra: "path=managerCheckins/\(managerId)/stores/\(storeId)/checkins/\(checkInId)")
            log(correlationId: correlationId, step: "done", extra: "checkInId=\(checkInId)")

            return PhotoCheckInPipelineResult(checkInId: checkInId, correlationId: correlationId, photoPath: photoPath, photoURL: photoURLString)
        } catch let pipelineError as PhotoCheckInPipelineError {
            throw pipelineError
        } catch {
            let nsError = error as NSError
            logFailure(correlationId: correlationId, step: "unknown", error: nsError, path: nil)
            throw PhotoCheckInPipelineError.firebaseFailure(step: "unknown", path: nil, underlying: nsError)
        }
    }

    private func validatePreconditions(user: AppUser, store: Store, locationStatus: LocationCheckState, correlationId: String) async throws -> String {
        guard !user.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhotoCheckInPipelineError.preconditionFailed("You must be signed in to check in.")
        }

        guard user.assignedStoreIds.contains(store.id) else {
            throw PhotoCheckInPipelineError.preconditionFailed("You are not assigned to this store.")
        }

        guard case .inRange = locationStatus else {
            throw PhotoCheckInPipelineError.preconditionFailed("You must be in range to check in.")
        }

        let memberDocPath = "stores/\(store.id)/members/\(user.id)"
        let employeeStorePath = "employeeStores/\(user.id)/stores/\(store.id)"
        async let memberDoc = db.document(memberDocPath).getDocument()
        async let employeeStoreDoc = db.document(employeeStorePath).getDocument()
        async let storeDoc = db.collection("stores").document(store.id).getDocument()

        let memberExists = try await memberDoc.exists
        let employeeStoreExists = try await employeeStoreDoc.exists
        let storeSnapshot = try await storeDoc

        guard memberExists || employeeStoreExists else {
            throw PhotoCheckInPipelineError.preconditionFailed("Store membership was not found for this account.")
        }

        let managerId = (store.managerId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? store.managerId!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (storeSnapshot.data()?["managerId"] as? String ?? "")

        guard !managerId.isEmpty else {
            throw PhotoCheckInPipelineError.preconditionFailed("Store manager could not be resolved for check-in.")
        }

        log(correlationId: correlationId, step: "preconditions_ok", extra: "managerId=\(managerId) memberDoc=\(memberExists) employeeStoreDoc=\(employeeStoreExists)")
        return managerId
    }

    private func createCheckInDocument(
        correlationId: String,
        checkInId: String,
        user: AppUser,
        store: Store,
        managerId: String
    ) async throws {
        let payload: [String: Any] = [
            "id": checkInId,
            "storeId": store.id,
            "managerId": managerId,
            "employeeId": user.id,
            "employeeName": user.name,
            "employeeEmail": user.email as Any,
            "storeName": store.name,
            "photoRequired": true,
            "photoVersion": 1,
            "status": "checking_in",
            "checkInTime": FieldValue.serverTimestamp(),
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ]

        let rootRef = db.collection("checkins").document(checkInId)
        let employeeRef = db.collection("employeeCheckins").document(user.id).collection("checkins").document(checkInId)
        let managerMirrorRef = db.collection("managerCheckins").document(managerId).collection("stores").document(store.id).collection("checkins").document(checkInId)

        do {
            let batch = db.batch()
            batch.setData(payload, forDocument: rootRef)
            batch.setData(payload, forDocument: employeeRef)
            batch.setData(payload, forDocument: managerMirrorRef)
            try await batch.commit()
        } catch {
            let nsError = error as NSError
            logFailure(correlationId: correlationId, step: "create_doc_failed", error: nsError, path: "employeeCheckins/\(user.id)/checkins/\(checkInId)")
            throw PhotoCheckInPipelineError.firebaseFailure(step: "create_doc", path: "employeeCheckins/\(user.id)/checkins/\(checkInId)", underlying: nsError)
        }
    }

    private func updateCheckInDocumentWithPhoto(
        correlationId: String,
        checkInId: String,
        uid: String,
        storeId: String,
        managerId: String,
        photoPath: String,
        photoURL: String?
    ) async throws {
        var payload: [String: Any] = [
            "photoPath": photoPath,
            "checkInPhotoPath": photoPath,
            "photoUploadedAt": FieldValue.serverTimestamp(),
            "checkInPhotoUploadedAt": FieldValue.serverTimestamp(),
            "status": "checked_in",
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if let photoURL, !photoURL.isEmpty {
            payload["photoURL"] = photoURL
            payload["checkInPhotoURL"] = photoURL
        }

        let rootRef = db.collection("checkins").document(checkInId)
        let employeeRef = db.collection("employeeCheckins").document(uid).collection("checkins").document(checkInId)
        let managerMirrorRef = db.collection("managerCheckins").document(managerId).collection("stores").document(storeId).collection("checkins").document(checkInId)

        do {
            let batch = db.batch()
            batch.updateData(payload, forDocument: rootRef)
            batch.updateData(payload, forDocument: employeeRef)
            batch.updateData(payload, forDocument: managerMirrorRef)
            try await batch.commit()
        } catch {
            let nsError = error as NSError
            logFailure(correlationId: correlationId, step: "firestore_update_failed", error: nsError, path: "employeeCheckins/\(uid)/checkins/\(checkInId)")
            throw PhotoCheckInPipelineError.firebaseFailure(step: "firestore_update", path: "employeeCheckins/\(uid)/checkins/\(checkInId)", underlying: nsError)
        }
    }

    private func log(correlationId: String, step: String, extra: String = "") {
        let suffix = extra.isEmpty ? "" : " \(extra)"
        PhotoVerifyLogger.log("[CheckInPhoto] correlationId=\(correlationId) step=\(step)\(suffix)")
    }

    private func logFailure(correlationId: String, step: String, error: NSError, path: String?) {
        let pathPart = path.map { " path=\($0)" } ?? ""
        PhotoVerifyLogger.log("[CheckInPhoto] correlationId=\(correlationId) step=\(step)\(pathPart) errorDomain=\(error.domain) code=\(error.code) message=\(error.localizedDescription)")
    }
}
