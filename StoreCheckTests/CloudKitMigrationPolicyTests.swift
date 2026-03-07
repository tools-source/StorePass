import CloudKit
import XCTest
@testable import StoreCheck

final class CloudKitMigrationPolicyTests: XCTestCase {
    func testSchemaMismatchRecognizedForInvalidArguments() {
        let policy = CloudKitMigrationPolicy()
        let error = CKError(.invalidArguments)

        XCTAssertTrue(policy.isSchemaMismatch(error))
    }

    func testShouldFallbackToLegacyWhenUnauthorized() {
        let policy = CloudKitMigrationPolicy()

        XCTAssertTrue(policy.shouldFallbackToLegacyAfterPrimarySaveFailure(CloudKitClientError.unauthorized))
    }

    func testShouldSuppressPermissionFailureWhenAllowed() {
        let policy = CloudKitMigrationPolicy()
        let error = CKError(.permissionFailure)

        XCTAssertTrue(policy.shouldSuppress(error, tolerateLookupErrors: false, suppressPermissionErrors: true))
        XCTAssertFalse(policy.shouldSuppress(error, tolerateLookupErrors: false, suppressPermissionErrors: false))
    }

    func testPartialFailureWithSchemaErrorsIsSchemaMismatch() {
        let policy = CloudKitMigrationPolicy()
        let recordID = CKRecord.ID(recordName: "record")
        let partial = CKError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    recordID: CKError(.serverRejectedRequest)
                ]
            ]
        )

        XCTAssertTrue(policy.isSchemaMismatch(partial))
    }
}
