# StorePass / StoreCheck (Release Ready)

StorePass is a SwiftUI + MVVM employee attendance app with Firebase Auth, Firestore, and geo-fenced check-ins.

## Features
- Employee role
  - Google / Apple sign-in
  - Assigned store selection
  - Live in-range / out-of-range state
  - Check-in button gated by geo + permission + account status
  - Last 30 check-ins with pull-to-refresh
- Manager role
  - Create/edit/delete stores with address search + code tools
  - Manage joined employees by store assignments
  - View today check-ins
  - Export check-ins to CSV

## Data Model (Firestore)

### `users/{uid}`
```json
{
  "name": "String",
  "email": "String?",
  "role": "employee | manager",
  "createdAt": "Timestamp",
  "lastLoginAt": "Timestamp",
  "provider": "google | apple | password",
  "assignedStoreIds": ["String"],
  "isActive": true
}
```

### `stores/{storeId}`
```json
{
  "name": "String",
  "address": "String",
  "latitude": 0.0,
  "longitude": 0.0,
  "managerId": "uid",
  "joinCodeHash": "sha256",
  "joinCodeLast4": "ABCD",
  "radiusMeters": 150,
  "isActive": true
}
```

### `checkins/{checkinId}`
```json
{
  "employeeId": "String",
  "storeId": "String",
  "checkInTime": "Timestamp",
  "clientLat": 0.0,
  "clientLng": 0.0,
  "distanceMeters": 0.0,
  "accuracyMeters": 0.0,
  "status": "approved | rejected",
  "rejectReason": "String?"
}
```

---

## Firebase Console Setup (Required)
1. **Register iOS app** in Firebase Console with the same bundle ID as Xcode target (`PRODUCT_BUNDLE_IDENTIFIER`).
2. Download `GoogleService-Info.plist` and place it at `StoreCheck/GoogleService-Info.plist`.
3. Enable Auth providers:
   - Google
   - Apple
4. Create Firestore database (Production mode preferred + deploy custom rules).
5. Deploy Firestore rules:
   ```bash
   firebase deploy --only firestore:rules
   ```
6. Deploy indexes:
   ```bash
   firebase deploy --only firestore:indexes
   ```
7. Deploy Cloud Functions in `us-central1`:
   ```bash
   firebase deploy --only functions
   ```

## Required Firestore Composite Indexes
Defined in `firebase/firestore.indexes.json`:
1. `checkins`: `storeId ASC`, `checkInTime DESC`
2. `checkins`: `status ASC`, `checkInTime DESC`
3. `checkins`: `storeId ASC`, `status ASC`, `checkInTime DESC`
4. `checkins`: `employeeId ASC`, `checkInTime DESC`

---

## Xcode Setup Checklist
1. Open `StoreCheck.xcodeproj`.
2. Confirm `GoogleService-Info.plist` is in **Build Phases → Copy Bundle Resources**.
3. In **Signing & Capabilities**, add **Sign in with Apple**.
4. Add URL Type using `REVERSED_CLIENT_ID` from `GoogleService-Info.plist`:
   - `Info.plist` key: `CFBundleURLTypes`
5. Confirm location keys are present in `Info.plist`:
   - `NSLocationWhenInUseUsageDescription`
   - `NSLocationAlwaysAndWhenInUseUsageDescription`
6. Confirm `FirebaseApp.configure()` is called once in `AppDelegate`.

---

## Production Auth/Routing Contract
- The app signs in with Google/Apple, then only upserts `users/{uid}` for the signed-in account.
- It reads only `users/{uid}` to resolve role + active status and routes accordingly.
- Selecting **Manager** on login does not change authentication provider; it only requests manager routing.
- If selected mode is Manager but profile role is not manager, login is denied with a friendly message and the user is returned to login.

---

## Production Role Bootstrap (Manual)
StoreCheck does **not** auto-assign manager privileges.

After first sign-in for the intended manager account:
1. Launch the app and sign in once (Google or Apple).
2. Open **Firestore Console → users → {uid}** for that account.
3. Set `role` to `"manager"` and keep `isActive = true`.
4. Save the document, relaunch the app, and sign in again.

All other users should keep `role = "employee"`.

---

## Troubleshooting
- **Missing plist / Firebase not configured**
  - Ensure `GoogleService-Info.plist` exists and is added to app target resources.
- **Bundle identifier mismatch**
  - Ensure Xcode bundle ID exactly matches Firebase iOS app registration.
- **Google sign-in returns to app but auth fails**
  - Verify URL Type contains the exact `REVERSED_CLIENT_ID`.
- **Apple sign-in fails**
  - Verify Sign in with Apple capability is enabled for target.
- **`kCLErrorDomain` / location unavailable**
  - Grant When In Use permission, enable Precise Location, retry outdoors.
- **Firestore index required error**
  - Deploy `firebase/firestore.indexes.json`.


## Migration Notes
1. Deploy updated Cloud Functions and Firestore rules before shipping the new client.
2. Backfill existing `stores` docs: copy `lat -> latitude`, `lng -> longitude`, set `managerId`, `joinCodeHash`, `joinCodeLast4`, `isActive`, `updatedAt`.
3. For existing manager-created employee links, create `storeMembers/{storeId}/members/{employeeUid}` docs and update each `users/{uid}.assignedStoreIds`.
4. Optionally run a one-time Admin script to disable legacy `managers/{managerId}/employees/*` documents after migration.
