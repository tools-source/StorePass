# StorePass Firebase to CloudKit Migration Plan

## Target authentication model

- Employee app: manual login and sign-up with email/password.
- Manager app: Sign in with Apple only.
- Google Sign-In: removed.

## Delivery approach

### Phase 1: freeze and compatibility layer

- Keep current Firebase app running while adding backend-agnostic repository interfaces.
- Add a `BackendProvider` switch in app configuration with two modes:
  - `firebase` (current production)
  - `cloudKit` (new path)
- Add shared DTO mappers so `Store`, `CheckIn`, `UserProfile`, and employee membership views serialize identically in both backends.

### Phase 2: CloudKit schema

- Use CloudKit private database for personal app state and public database for shared store/team data.
- Record types:
  - `SCUser`: `userId`, `role`, `name`, `email`, `isActive`, `provider`, `createdAt`, `updatedAt`
  - `SCStore`: `storeId`, `managerUserId`, `name`, `address`, `lat`, `lng`, `radiusMeters`, `isActive`, `joinCode`, `createdAt`, `updatedAt`
  - `SCMembership`: `membershipId`, `storeId`, `employeeUserId`, `employeeName`, `employeeEmail`, `hourlyRate`, `isActive`, `joinedAt`, `updatedAt`
  - `SCCheckIn`: `checkInId`, `storeId`, `employeeUserId`, `managerUserId`, `checkInTime`, `checkOutTime`, geo/accuracy fields, verification fields, status fields
  - `SCVerificationPhoto`: `checkInId`, `storeId`, `employeeUserId`, `createdAt`, `photoAsset`
  - `SCDeletionRequest`: `userId`, `role`, `requestedAt`, `status`, `reason`
- Add CloudKit indexes for:
  - store by `joinCode`
  - memberships by `storeId` and `employeeUserId`
  - check-ins by `employeeUserId + checkInTime`
  - check-ins by `managerUserId + storeId + checkInTime`

### Phase 3: authentication and identity

- Employees:
  - Add manual credential flow in app UI.
  - Store salted password hash in Keychain-backed auth service and sync account metadata to `SCUser`.
  - Enforce employee role in manual-auth path.
- Managers:
  - Apple Sign-In token flow.
  - Upsert `SCUser` as manager only when manager entitlement exists.
- Add migration bridge:
  - On first CloudKit sign-in, import legacy Firebase profile once, then mark `firebaseMigratedAt`.

### Phase 4: core feature migration

- Stores:
  - create/rotate/join/leave via CloudKit operations.
- Employee management:
  - manager fetches memberships by owned stores.
  - remove employee updates memberships and employee store mirrors in one transaction-like batch.
- Check-ins:
  - write one canonical `SCCheckIn` row and query by role-specific indexes.
  - delete/clear propagates to all relevant queries through canonical source (no mirrored duplication).
- Payroll:
  - keep hourly rate in membership and snapshot `hourlyRateAtCheckIn` on `SCCheckIn` for historical accuracy.

### Phase 5: photo verification hardening

- Camera:
  - default to front camera for employee verification capture.
  - fallback to rear only if front camera unavailable.
- Storage:
  - write photo as `CKAsset` in `SCVerificationPhoto`.
  - manager-only photo fetch policy in app layer.
- Reliability:
  - retry upload with local pending queue.
  - verify photo reference before final check-in commit.

### Phase 6: cutover and Firebase removal

- Disable new writes to Firebase once CloudKit parity tests pass.
- Run one-time migration job:
  - users
  - stores
  - memberships
  - check-ins
  - verification photos (where available)
- Remove Firebase SDKs and config files:
  - `FirebaseAuth`, `FirebaseFirestore`, `FirebaseFunctions`, `FirebaseStorage`, `GoogleSignIn`
  - `GoogleService-Info.plist`
- Remove Firebase functions and rules from deployment pipeline.

## Test matrix

- Employee manual sign-up/sign-in/sign-out.
- Manager Apple sign-in success and non-manager rejection.
- Store join/leave and manager remove employee.
- Check-in/check-out with verification photo (front camera).
- Edit and clear check-ins visible in both manager and employee history.
- Account deletion for employee and manager.
- Offline queue replay for check-ins and photo uploads.

## Risk controls

- Keep Firebase path feature-flagged until CloudKit parity is reached.
- Add telemetry for sign-in failures, check-in write failures, and photo upload failures.
- Add migration rollback switch per build if CloudKit production records fail validation.
