# Firestore Rules Sanity Test Plan

## Scope and assumptions
- Rules audited against the provided ruleset (users as source of truth, `stores/{storeId}/members/{employeeUid}`, `checkins/{checkinId}`, and legacy `managers` / `employees` self-only).
- Goal: align client behavior with current rules and avoid permission-denied dead-ends.

## Findings (security + sanity)
1. **`employees/{uid}` used as profile source in client** caused role/isActive reads to bypass `users/{uid}` source-of-truth model.
2. **Manager employee-listing used `storeMembers/{storeId}/members` path** while rules protect `stores/{storeId}/members/{employeeUid}`.
3. **Join verification used `storeMembers/...` in app after function call**, creating false negatives in client verification.
4. **Account deletion attempted direct deletes on `managers/{uid}` and `employees/{uid}`**, but provided rules deny delete there.
5. **Check-in create path did not guard `employeeId == current uid` client-side**, causing avoidable permission-denied writes.
6. **User upsert payload included immutable/trusted fields (`isActive`, `createdAt`) in parts of code**; not allowed by the provided `userUpdateAllowed()`.
7. **Manager querying/employee reads rely on document-level read predicates**; queries can fail if any candidate document is unauthorized.
8. **Store create must include `managerId == uid` and `isActive == true`**; client already mostly did this but lacked strict shape validation around radius.
9. **Employee membership create must be exact path and self uid**; app relies on Cloud Functions join path (good), but direct client path mismatches were present.
10. **Bootstrap risk in provided rules**: first `users/{uid}` create is self-authorized and can set `role` / `isActive`; this is a rule-level hardening gap.

## Path / operation matrix (repo sanity check)
| Code location | Firestore path used | Operation | Allowed by provided rules? | Fix |
|---|---|---|---|---|
| `StoreCheck/Repositories/RoleProfileRepository.swift` | `users/{uid}` | get/set(merge) self profile | Yes (self create/read/update on allowed keys) | Keep; no role/isActive writes after create. |
| `StoreCheck/Repositories/UserRepository.swift` | `employees/{uid}` (old) | read/write profile | Legacy only; conflicts with users source-of-truth | **Changed to `users/{uid}`** and limited update payload keys. |
| `StoreCheck/Repositories/UserRepository.swift` | `storeMembers/{storeId}/members` (old) | manager reads members | No (wrong collection path) | **Changed to `stores/{storeId}/members`**. |
| `StoreCheck/Repositories/UserRepository.swift` | `users` by documentID IN | manager reads employee profile docs | No (manager cannot read arbitrary `users/{uid}` in provided rules) | Keep as known rule limitation; use CF/admin path for full manager employee profiles if needed. |
| `StoreCheck/Repositories/FirestoreStoreRepository.swift` | `stores` | manager create/query/update/delete | Yes for active manager that manages store | Added stronger input guard for `radiusMeters > 0`. |
| `StoreCheck/Repositories/FirestoreStoreRepository.swift` | `storeMembers/{storeId}/members/{uid}` (old verify) | read membership after join | No (wrong path) | **Changed verify read to `stores/{storeId}/members/{uid}`**. |
| `StoreCheck/Repositories/CheckInRepository.swift` | `checkins/{checkinId}` | create | Yes only when `employeeId == auth.uid` | Added client guard before write + debug logs. |
| `StoreCheck/Views/Employee/EmployeeSettingsView.swift` | `managers/{uid}` / `employees/{uid}` delete (old) | delete | No (`delete: false`) | Removed direct Firestore deletes; rely on backend cleanup + auth delete. |

## Top 10 causes of “Missing or insufficient permissions” for these rules
1. Signed-out user making any request.
2. `users/{uid}` missing when role/active-dependent rule helpers execute.
3. Client trying to read another user’s `users/{uid}` doc.
4. Employee trying to create/update/delete `stores/{storeId}`.
5. Manager trying to read a store they don’t own/manage (`managerId`/`ownerId` mismatch).
6. Employee trying to read a store not present in `assignedStoreIds`.
7. Membership doc write to wrong path (`storeMembers/...` vs `stores/.../members/...`).
8. Membership doc create where document id != auth uid.
9. Check-in create with `employeeId` not matching auth uid.
10. User update attempts that include disallowed keys (`role`, `isActive`, `createdAt`, etc.).

---

## Manual test checklist

### A) Manager happy path
- Sign in as active manager (`users/{uid}.role=manager`, `isActive=true`).
- Create store with payload containing `managerId == uid`, `isActive == true`.
- Query manager stores by `managerId == uid` and (if used) `ownerId == uid`.
- Read check-ins filtered by a managed `storeId`.

Expected: All allow.

### B) Employee happy path
- Sign in as active employee with assigned store id in `users/{uid}.assignedStoreIds`.
- Read assigned stores by doc IDs.
- Join store via callable (server-side membership + assignedStoreIds update).
- Create check-in where `employeeId == uid`.
- Read own check-ins.

Expected: All allow.

### C) Negative tests
- Employee attempts store create/update/delete → deny.
- Manager tries reading another manager’s non-owned store → deny.
- Employee tries check-in with `employeeId != uid` → deny.
- Employee tries reading unassigned store → deny.
- Client attempts `users/{uid}` update including `role` or `isActive` → deny.
- Direct delete on `managers/{uid}` or `employees/{uid}` from client → deny.

Expected: Deny with permission error.

---

## Emulator test steps (lightweight)
1. Start emulator:
   ```bash
   firebase emulators:start --only firestore
   ```
2. Seed test users/stores with Admin SDK script (or emulator UI):
   - manager user doc, employee user doc, active flags, store doc with managerId/ownerId.
3. Run client/emulator scenario calls:
   - manager create store (allow)
   - employee create store (deny)
   - employee create own membership doc at `stores/{storeId}/members/{uid}` (allow if store active)
   - employee create checkin with mismatched employeeId (deny)
   - manager read checkins for managed store (allow)
4. Verify emulator logs show allow/deny matching expected outcomes.

## Minimal rule improvement recommendation (optional)
Provided rules currently allow self-create on `users/{uid}` with arbitrary initial fields. Minimal hardening:
- Restrict create so `role == "employee"` and `isActive == true` unless creation is performed by trusted server/Admin SDK.
- Risk if unchanged: a malicious client could self-bootstrap as manager on first profile write.

