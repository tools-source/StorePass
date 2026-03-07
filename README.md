# StorePass / StoreCheck

StorePass is a SwiftUI + MVVM attendance app for two production roles:
- **Manager app**: create/manage stores, memberships, and review employee check-ins.
- **Employee app**: authenticate, receive memberships, and check in/out with front-camera photo verification.

## Backend
- **CloudKit only** (no Firebase, no external backend).
- Record types used:
  - `User`
  - `Store`
  - `StoreMember`
  - `CheckInSession`

## Authentication
- Manager: Sign in with Apple.
- Employee:
  - Sign in with Apple, or
  - Email + password (local credential stored securely in Keychain), or
  - Quick email access for test/ops fallback flows.

## Core behaviors
- Manager account deletion cascades through manager-owned stores, memberships, and check-in records.
- Store deletion cascades through memberships and check-in records.
- Employee membership updates sync to assigned stores.
- Check-in/out requires a front-camera capture; CloudKit stores photo asset references.

## Platform
- iOS 17+
