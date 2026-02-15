# StoreCheck (Employee Geo-Fenced Check-In)

StoreCheck is a SwiftUI + MVVM iOS app for store employee attendance with strict geo-fencing and role-based access.

## Stack
- SwiftUI + MVVM
- Firebase Authentication (email/password)
- Firestore (users, stores, checkins)
- CoreLocation + MapKit for in-range verification
- Cloud Functions (recommended): authoritative server-side check-in validation

## Folder Structure
```
StoreCheck/
  App/
  Auth/
  Models/
  Services/
  Repositories/
  Views/
  ViewModels/
  DesignSystem/
  SupportingFiles/
firebase/
  firestore.rules
  functions/
StoreCheckCore/ (unit-testable core distance logic)
```

## Implemented Features

### Auth + Roles
- Role selector (Employee Login / Manager Login)
- Email/password login for both roles
- Role is read from Firestore `users/{uid}.role`
- Route to Employee app area vs Manager app area after login

### Employee
- Assigned stores (picker)
- Live location validation status:
  - In range ✅ / Out of range ❌ with live distance
  - Permission denied
  - Precise location required
  - Low accuracy blocked
- Check-in button disabled until location state is `inRange`
- Today status + history (last 30)
- Offline queue fallback (check-in payload persisted locally)

### Manager
- Today check-ins dashboard
- CSV export/share
- Store CRUD basics (name/address/lat/lng/radius)
- Employee create + activate/deactivate

### Security
- Firestore security rules enforce role-based reads/writes
- Cloud Function (`validateCheckIn`) recalculates distance server-side and writes approved/rejected result

## Firestore Data Model
- `users/{uid}`: `name, email, role, assignedStoreIds, isActive, createdAt`
- `stores/{storeId}`: `name, address, lat, lng, radiusMeters, isActive, createdAt`
- `checkins/{checkinId}`: `employeeId, storeId, storeName, employeeName, checkInTime, clientLat, clientLng, serverValidated, distanceMeters, accuracyMeters, status, rejectReason, deviceInfo`

## Setup
1. Create Firebase project and iOS app.
2. Add `GoogleService-Info.plist` to Xcode target.
3. Enable Firebase Auth Email/Password.
4. Create Firestore database.
5. Deploy rules:
   ```bash
   firebase deploy --only firestore:rules
   ```
6. (Recommended) Deploy cloud function:
   ```bash
   cd firebase/functions
   npm install
   firebase deploy --only functions:validateCheckIn
   ```
7. Add Info.plist location keys:
   - `NSLocationWhenInUseUsageDescription`
   - Temporary precise location usage description (if requested)

## Admin Bootstrap (First Manager)
1. Create account with Firebase Auth console.
2. Create Firestore doc `users/{uid}` with:
   ```json
   {
     "name": "Admin Manager",
     "email": "manager@company.com",
     "role": "manager",
     "assignedStoreIds": [],
     "isActive": true,
     "createdAt": "<server timestamp>"
   }
   ```
3. Login via Manager Login path.

## Testing (Simulated Location)
1. Run app in Xcode simulator.
2. Choose a custom location matching a store coordinate.
3. Validate check-in button enables only within radius.
4. Turn off Precise Location / deny location to validate anti-cheat blocking.

## Notes / Production Hardening
- Current app writes client check-in directly when Cloud Function is not wired; production should invoke function exclusively.
- Add App Check, Remote Config thresholds, and tamper telemetry.
- Expand manager filters (date range, employee, store) with server-side querying/indexes.
