# StoreCheck (Employee Geo-Fenced Check-In)

StoreCheck is a SwiftUI + MVVM iOS app for store employee attendance with geo-fencing and role-based access.

## Auth Stack
- Firebase Authentication
- Google Sign-In (GoogleSignIn SDK)
- Sign in with Apple (`AuthenticationServices`)
- Firestore profile document at `users/{uid}`

## User Profile Model (`users/{uid}`)
```json
{
  "id": "<uid>",
  "name": "Jane Doe",
  "email": "jane@company.com",
  "role": "employee",
  "createdAt": "<timestamp>",
  "lastLoginAt": "<timestamp>",
  "provider": "google",
  "assignedStoreIds": [],
  "isActive": true
}
```

## iOS Setup (Google + Apple)
1. Add `GoogleService-Info.plist` to the **StoreCheck** target.
2. In **Xcode > Project > Package Dependencies**, add:
   - `https://github.com/firebase/firebase-ios-sdk`
   - `https://github.com/google/GoogleSignIn-iOS`
3. Add URL Type in target settings using `REVERSED_CLIENT_ID` from `GoogleService-Info.plist`.
4. In Firebase Console > Authentication, enable:
   - Google
   - Apple
5. In Xcode target **Signing & Capabilities**, add **Sign in with Apple** capability.
6. Ensure `FirebaseApp.configure()` runs in `AppDelegate`.
7. Ensure `onOpenURL` and `application(_:open:options:)` both forward URL callbacks to `GIDSignIn`.

## Firestore Rules
Deploy rules from `firebase/firestore.rules`:
```bash
firebase deploy --only firestore:rules
```

Rules enforce:
- Users can read/write only their own user document.
- Users cannot self-escalate role.
- Managers can read/write manager-only collections.

## Run
1. Open `StoreCheck.xcodeproj`.
2. Build and run on iOS 15+.
3. Use Login screen:
   - Continue with Google
   - Continue with Apple
4. After sign-in, app routes by role:
   - `employee` -> Employee dashboard
   - `manager` -> Manager dashboard
