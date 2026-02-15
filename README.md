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
  - Create stores (coordinates + radius)
  - Create/disable employees
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
  "lat": 0.0,
  "lng": 0.0,
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

## Production Role Bootstrap (Manual)
StoreCheck does **not** auto-assign manager privileges.

After first sign-in for the intended manager account:
1. Open **Firestore Console → users → {uid}**.
2. Set `role` to `"manager"`.
3. Save the document and sign in again.

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
