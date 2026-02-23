// What changed:
// - Added employee deleteMyAccount cleanup endpoint to unlink memberships/mirrors before auth deletion.

import { HttpsError, onCall, onRequest } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';
import {
  extractDataPayload,
  generateJoinCode,
  normalizeCode,
  requireActiveManager,
  sha256,
  toErrorResponse,
  verifyBearerToken,
} from './helpers';

admin.initializeApp();
const db = admin.firestore();

function maskCode(code: string): string {
  if (!code) {
    return '';
  }
  const last4 = code.slice(-4);
  return `${'*'.repeat(Math.max(0, code.length - 4))}${last4}`;
}

export const joinStoreByCode = onRequest({ region: 'us-central1' }, async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: { message: 'Method not allowed' } });
    return;
  }

  try {
    const decodedToken = await verifyBearerToken(req as { headers: Record<string, unknown> });
    const uid = decodedToken.uid;
    console.log(`[JOIN] auth uid=${uid}`);

    const userSnap = await db.collection('users').doc(uid).get();
    const userData = userSnap.data();
    const profileName =
      (typeof userData?.displayName === 'string' && userData.displayName.trim().length > 0
        ? userData.displayName.trim()
        : null) ??
      (typeof userData?.name === 'string' && userData.name.trim().length > 0 ? userData.name.trim() : null) ??
      (typeof decodedToken.name === 'string' && decodedToken.name.trim().length > 0 ? decodedToken.name.trim() : null) ??
      `Employee ${uid.slice(0, 6)}`;
    const profileEmail =
      (typeof userData?.email === 'string' && userData.email.trim().length > 0 ? userData.email.trim() : null) ??
      (typeof decodedToken.email === 'string' && decodedToken.email.trim().length > 0 ? decodedToken.email.trim() : null) ??
      '';
    const role = typeof userData?.role === 'string' ? userData.role : null;
    const isActive = userData?.isActive === true;
    console.log(`[JOIN] role lookup uid=${uid} userDocExists=${userSnap.exists} role=${role ?? 'null'} isActive=${isActive}`);

    const data = extractDataPayload(req.body);
    const code = normalizeCode(data.code);
    const joinCodeLast4 = code.slice(-4);
    console.log(`[JOIN] code received masked=${maskCode(code)} joinCodeLast4=${joinCodeLast4}`);

    if (!code) {
      throw new HttpsError('invalid-argument', 'code is required');
    }

    const plainCodeQuery = await db.collection('stores').where('joinCode', '==', code).limit(1).get();
    let storeDoc = plainCodeQuery.docs[0];
    let hashMatched = false;

    if (!storeDoc) {
      const hashedCode = sha256(code);
      const hashQuery = await db.collection('stores').where('joinCodeHash', '==', hashedCode).limit(1).get();
      hashMatched = hashQuery.docs.length > 0;
      storeDoc = hashQuery.docs[0];
    }

    console.log(`[JOIN] hash comparison result hashMatched=${hashMatched}`);

    if (!storeDoc) {
      throw new HttpsError('not-found', 'Invalid join code');
    }

    const store = storeDoc.data();
    const storeId = storeDoc.id;
    console.log(`[JOIN] resolved uid=${uid} storeId=${storeId} joinCodeLast4=${joinCodeLast4}`);

    const memberPath = `stores/${storeId}/members/${uid}`;
    const userPath = `users/${uid}`;
    const employeeStorePath = `employeeStores/${uid}/stores/${storeId}`;
    const memberRef = db.doc(memberPath);
    const userRef = db.doc(userPath);
    const employeeStoreRef = db.doc(employeeStorePath);
    console.log(`[JOIN] firestore write paths membershipDocPath=${memberPath} userDocPath=${userPath} employeeStoreDocPath=${employeeStorePath}`);

    const existingMember = await memberRef.get();
    const existingUser = await userRef.get();
    const beforeAssignedStoreIds = (existingUser.data()?.assignedStoreIds as string[] | undefined) ?? [];
    const beforeContains = beforeAssignedStoreIds.includes(storeId);
    console.log(
      `[JOIN] before uid=${uid} storeId=${storeId} assignedStoreIdsLength=${beforeAssignedStoreIds.length} containsStore=${beforeContains}`,
    );

    try {
      await db.runTransaction(async (transaction) => {
        const userBefore = await transaction.get(userRef);

        transaction.set(
          memberRef,
          {
            userId: uid,
            employeeId: uid,
            storeId,
            role: 'employee',
            joinedAt: admin.firestore.FieldValue.serverTimestamp(),
            isActive: true,
            storeName: String(store.name ?? 'Store'),
            employeeName: profileName,
            employeeEmail: profileEmail,
          },
          { merge: true },
        );

        transaction.set(
          employeeStoreRef,
          {
            storeId,
            employeeId: uid,
            managerId: typeof store.managerId === 'string' ? store.managerId : null,
            name: String(store.name ?? 'Store'),
            address: String(store.address ?? ''),
            latitude: typeof store.latitude === 'number' ? store.latitude : null,
            longitude: typeof store.longitude === 'number' ? store.longitude : null,
            radiusMeters: typeof store.radiusMeters === 'number' ? store.radiusMeters : 150,
            isActive: store.isActive === true,
            joinedAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );

        if (!userBefore.exists) {
          transaction.set(
            userRef,
            {
              role: 'employee',
              isActive: true,
              assignedStoreIds: [storeId],
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
              lastLoginAt: admin.firestore.FieldValue.serverTimestamp(),
              lastJoinAt: admin.firestore.FieldValue.serverTimestamp(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true },
          );
          return;
        }

        transaction.set(
          userRef,
          {
            role: 'employee',
            isActive: true,
            assignedStoreIds: admin.firestore.FieldValue.arrayUnion(storeId),
            lastLoginAt: admin.firestore.FieldValue.serverTimestamp(),
            lastJoinAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      });
      console.log(`[JOIN] atomic commit success uid=${uid} storeId=${storeId}`);
    } catch (error) {
      console.error(`[JOIN] atomic commit failure uid=${uid} storeId=${storeId}`, error);
      throw new HttpsError('internal', 'Join failed: atomic membership + user profile update failed');
    }

    const [memberAfter, userAfter] = await Promise.all([memberRef.get(), userRef.get()]);
    const assignedStoreIdsAfter = (userAfter.data()?.assignedStoreIds as string[] | undefined) ?? [];
    const assignedStoreIdsContainsStoreId = assignedStoreIdsAfter.includes(storeId);
    const membershipExists = memberAfter.exists;
    console.log(
      `[JOIN] after uid=${uid} storeId=${storeId} assignedStoreIdsLength=${assignedStoreIdsAfter.length} containsStore=${assignedStoreIdsContainsStoreId} membershipExists=${membershipExists}`,
    );

    if (membershipExists && !assignedStoreIdsContainsStoreId) {
      throw new HttpsError(
        'internal',
        'Join membership write succeeded but user profile assignedStoreIds update failed',
      );
    }

    const membershipSaved = membershipExists;
    const assignedSaved = assignedStoreIdsContainsStoreId;

    const payload = {
      result: {
        storeId,
        storeName: String(store.name ?? 'Store'),
        alreadyJoined: existingMember.exists,
        membershipSaved,
        assignedSaved,
        debug: {
          membershipExists: membershipSaved,
          assignedStoreIdsContainsStoreId: assignedSaved,
        },
      },
    };

    console.log(`[JOIN] final response payload=${JSON.stringify(payload)}`);
    res.status(200).json(payload);
  } catch (error) {
    const errorWithStack = error as { stack?: string };
    console.error('[JOIN] request failed', error);
    if (errorWithStack?.stack) {
      console.error('[JOIN] request failed stack', errorWithStack.stack);
    }
    const err = toErrorResponse(error);
    res.status(err.status).json(err.body);
  }
});

export const rotateStoreCode = onRequest({ region: 'us-central1' }, async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: { message: 'Method not allowed' } });
    return;
  }

  try {
    const decodedToken = await verifyBearerToken(req as { headers: Record<string, unknown> });
    const uid = decodedToken.uid;
    console.log(`[ROTATE] auth uid=${uid}`);

    const managerLookup = await requireActiveManager(db, uid);
    console.log(
      `[ROTATE] role lookup uid=${uid} managerDocExists=${managerLookup.managerDocExists} managerDocActive=${managerLookup.managerDocActive} userDocExists=${managerLookup.userDocExists} role=${managerLookup.userRole ?? 'null'} isActive=${managerLookup.userIsActive}`,
    );

    const data = extractDataPayload(req.body);
    const storeId = String(data.storeId ?? '');
    console.log(`[ROTATE] resolved storeId=${storeId || '<missing>'}`);
    if (!storeId) {
      throw new HttpsError('invalid-argument', 'storeId is required');
    }

    const storeRef = db.collection('stores').doc(storeId);
    const storeSnap = await storeRef.get();
    if (!storeSnap.exists) {
      throw new HttpsError('not-found', 'Store not found');
    }

    const storeData = storeSnap.data() ?? {};
    if (storeData.managerId !== uid) {
      throw new HttpsError('permission-denied', 'You can only rotate code for your own store');
    }

    const joinCode = generateJoinCode(8);
    const writePath = `stores/${storeId}`;
    console.log(`[ROTATE] firestore write attempt path=${writePath}`);
    try {
      await storeRef.set(
        {
          joinCode,
          joinCodeHash: sha256(joinCode),
          joinCodeLast4: joinCode.slice(-4),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      console.log(`[ROTATE] firestore write success path=${writePath}`);
    } catch (error) {
      console.error(`[ROTATE] firestore write failure path=${writePath}`, error);
      throw new HttpsError('internal', `Rotate failed: write to ${writePath} failed`);
    }

    const payload = { result: { joinCode } };
    console.log(`[ROTATE] final response payload=${JSON.stringify(payload)}`);
    res.status(200).json(payload);
  } catch (error) {
    console.error('[ROTATE] request failed', error);
    const err = toErrorResponse(error);
    res.status(err.status).json(err.body);
  }
});

export const getStoreJoinCode = onRequest({ region: 'us-central1' }, async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: { message: 'Method not allowed' } });
    return;
  }

  try {
    const decodedToken = await verifyBearerToken(req as { headers: Record<string, unknown> });
    const uid = decodedToken.uid;
    console.log(`[CODE] auth uid=${uid}`);

    const managerLookup = await requireActiveManager(db, uid);
    console.log(
      `[CODE] role lookup uid=${uid} managerDocExists=${managerLookup.managerDocExists} managerDocActive=${managerLookup.managerDocActive} userDocExists=${managerLookup.userDocExists} role=${managerLookup.userRole ?? 'null'} isActive=${managerLookup.userIsActive}`,
    );

    const data = extractDataPayload(req.body);
    const storeId = String(data.storeId ?? '');
    console.log(`[CODE] resolved storeId=${storeId || '<missing>'}`);
    if (!storeId) {
      throw new HttpsError('invalid-argument', 'storeId is required');
    }

    const storeSnap = await db.collection('stores').doc(storeId).get();
    if (!storeSnap.exists) {
      throw new HttpsError('not-found', 'Store not found');
    }

    const store = storeSnap.data() ?? {};
    if (store.managerId !== uid) {
      throw new HttpsError('permission-denied', 'You can only access code for your own store');
    }
    const joinCode = typeof store.joinCode === 'string' ? store.joinCode : '';

    if (!joinCode) {
      throw new HttpsError('failed-precondition', 'joinCode not stored; only last4 available');
    }

    console.log(`[CODE] code loaded masked=${maskCode(joinCode)}`);
    const payload = { result: { joinCode } };
    console.log(`[CODE] final response payload=${JSON.stringify(payload)}`);
    res.status(200).json(payload);
  } catch (error) {
    console.error('[CODE] request failed', error);
    const err = toErrorResponse(error);
    res.status(err.status).json(err.body);
  }
});

export const setUserRole = onRequest({ region: 'us-central1' }, async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: { message: 'Method not allowed' } });
    return;
  }

  try {
    const decodedToken = await verifyBearerToken(req as { headers: Record<string, unknown> });
    const uid = decodedToken.uid;
    const data = extractDataPayload(req.body);
    const requestedRoleRaw = String(data.requestedRole ?? '').toLowerCase();
    const requestedRole = requestedRoleRaw === 'manager' ? 'manager' : requestedRoleRaw === 'employee' ? 'employee' : null;
    const name = String(data.name ?? 'StorePass User');
    const email = typeof data.email === 'string' ? data.email : null;
    const provider = String(data.provider ?? 'unknown');

    if (!requestedRole) {
      throw new HttpsError('invalid-argument', 'requestedRole must be manager or employee');
    }

    const userRef = db.collection('users').doc(uid);

    const result = await db.runTransaction(async (transaction) => {
      const userSnap = await transaction.get(userRef);
      const existingRole = typeof userSnap.data()?.role === 'string' ? String(userSnap.data()?.role).toLowerCase() : null;

      if (existingRole === 'manager' || existingRole === 'employee') {
        return { created: false, role: existingRole, changed: false };
      }

      if (!userSnap.exists) {
        transaction.set(
          userRef,
          {
            name,
            email,
            role: requestedRole,
            isActive: true,
            provider,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            lastLoginAt: admin.firestore.FieldValue.serverTimestamp(),
            assignedStoreIds: [],
          },
          { merge: true },
        );
        return { created: true, role: requestedRole, changed: true };
      }

      transaction.set(
        userRef,
        {
          name,
          email,
          provider,
          role: requestedRole,
          isActive: true,
          lastLoginAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return { created: false, role: requestedRole, changed: true };
    });

    console.log(`[SET_ROLE] uid=${uid} requestedRole=${requestedRole} created=${result.created} changed=${result.changed} role=${result.role}`);
    res.status(200).json({ result });
  } catch (error) {
    console.error('[SET_ROLE] request failed', error);
    const err = toErrorResponse(error);
    res.status(err.status).json(err.body);
  }
});

export const leaveStore = onCall({ region: 'us-central1' }, async (request) => {
  const uid = request.auth?.uid;
  const storeId = String(request.data?.storeId ?? '');

  if (!uid) {
    throw new HttpsError('permission-denied', 'Authentication required');
  }
  if (!storeId) {
    throw new HttpsError('failed-precondition', 'storeId is required');
  }

  try {
    console.log(`[LEAVE_STORE][START] uid=${uid} storeId=${storeId}`);
    const storeRef = db.collection('stores').doc(storeId);
    const memberRef = storeRef.collection('members').doc(uid);
    const employeeStoreRef = db.collection('employeeStores').doc(uid).collection('stores').doc(storeId);
    const userRef = db.collection('users').doc(uid);

    const [storeSnap, memberSnap, employeeStoreSnap, userSnap] = await Promise.all([
      storeRef.get(),
      memberRef.get(),
      employeeStoreRef.get(),
      userRef.get(),
    ]);

    if (!storeSnap.exists) {
      console.log(`[LEAVE_STORE] storeMissing storeId=${storeId}`);
    }

    const assignedStoreIds = (userSnap.data()?.assignedStoreIds as string[] | undefined) ?? [];
    const beforeCount = assignedStoreIds.length;
    console.log(`[LEAVE_STORE] memberExists=${memberSnap.exists} employeeStoreExists=${employeeStoreSnap.exists} assignedBeforeCount=${beforeCount}`);

    const batch = db.batch();
    if (memberSnap.exists) {
      batch.delete(memberRef);
    }
    if (employeeStoreSnap.exists) {
      batch.delete(employeeStoreRef);
    }

    batch.set(
      userRef,
      {
        assignedStoreIds: admin.firestore.FieldValue.arrayRemove(storeId),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    await batch.commit();
    console.log(`[LEAVE_STORE][END] ok=true uid=${uid} storeId=${storeId} assignedAfterCount=${Math.max(0, beforeCount - (assignedStoreIds.includes(storeId) ? 1 : 0))}`);
    return { ok: true, storeId, uid };
  } catch (error) {
    console.error('[LEAVE_STORE] callable failed', error);
    if (error instanceof HttpsError) {
      throw error;
    }
    throw new HttpsError('internal', 'Failed to leave store');
  }
});

export const removeEmployeeFromStore = onCall({ region: 'us-central1' }, async (request) => {
  const managerId = request.auth?.uid;
  const storeId = String(request.data?.storeId ?? '');
  const employeeId = String(request.data?.employeeId ?? '');

  if (!managerId) {
    throw new HttpsError('permission-denied', 'Authentication required');
  }
  if (!storeId || !employeeId) {
    throw new HttpsError('failed-precondition', 'storeId and employeeId are required');
  }

  try {
    console.log(`[REMOVE_EMPLOYEE_FROM_STORE][START] managerId=${managerId} storeId=${storeId} employeeId=${employeeId}`);
    const managerLookup = await requireActiveManager(db, managerId);
    console.log(`[REMOVE_EMPLOYEE_FROM_STORE] managerLookup role=${managerLookup.userRole} userIsActive=${managerLookup.userIsActive} managerDocActive=${managerLookup.managerDocActive}`);
    if (!managerLookup.managerDocActive || managerLookup.userRole !== 'manager' || managerLookup.userIsActive !== true) {
      throw new HttpsError('failed-precondition', 'This action can’t be completed right now.');
    }

    const storeRef = db.collection('stores').doc(storeId);
    const memberRef = storeRef.collection('members').doc(employeeId);
    const employeeStoreRef = db.collection('employeeStores').doc(employeeId).collection('stores').doc(storeId);
    const userRef = db.collection('users').doc(employeeId);

    const [storeSnap, memberSnap, employeeStoreSnap, userSnap] = await Promise.all([
      storeRef.get(),
      memberRef.get(),
      employeeStoreRef.get(),
      userRef.get(),
    ]);

    if (!storeSnap.exists) {
      throw new HttpsError('not-found', 'Store not found');
    }

    const storeData = storeSnap.data() ?? {};
    console.log(`[REMOVE_EMPLOYEE_FROM_STORE] storeSnapshot managerId=${String(storeData.managerId ?? 'nil')} isActive=${String(storeData.isActive ?? 'nil')}`);
    if (storeData.managerId !== managerId) {
      throw new HttpsError('permission-denied', 'You don’t have permission.');
    }
    if (storeData.isActive !== true) {
      throw new HttpsError('failed-precondition', 'This action can’t be completed right now.');
    }

    const assignedStoreIds = (userSnap.data()?.assignedStoreIds as string[] | undefined) ?? [];
    const beforeCount = assignedStoreIds.length;
    console.log(`[REMOVE_EMPLOYEE_FROM_STORE] memberExists=${memberSnap.exists} employeeStoreExists=${employeeStoreSnap.exists} assignedBeforeCount=${beforeCount}`);

    const batch = db.batch();
    if (memberSnap.exists) {
      batch.delete(memberRef);
    }
    if (employeeStoreSnap.exists) {
      batch.delete(employeeStoreRef);
    }
    batch.set(
      userRef,
      {
        assignedStoreIds: admin.firestore.FieldValue.arrayRemove(storeId),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    await batch.commit();
    console.log(`[REMOVE_EMPLOYEE_FROM_STORE][END] ok=true managerId=${managerId} storeId=${storeId} employeeId=${employeeId}`);
    return { ok: true, storeId, employeeId, managerId };
  } catch (error) {
    console.error('[REMOVE_EMPLOYEE_FROM_STORE] callable failed', error);
    if (error instanceof HttpsError) {
      throw error;
    }
    throw new HttpsError('internal', 'Failed to remove employee from store');
  }
});

async function commitDeleteBatch(
  refs: FirebaseFirestore.DocumentReference[],
  context: { prefix: string; uid: string; stage: string },
): Promise<number> {
  if (refs.length === 0) {
    return 0;
  }

  const chunkSize = 350;
  let deleted = 0;
  for (let i = 0; i < refs.length; i += chunkSize) {
    const chunk = refs.slice(i, i + chunkSize);
    const batch = db.batch();
    for (const ref of chunk) {
      batch.delete(ref);
    }
    console.log(`[${context.prefix}] stage=${context.stage} uid=${context.uid} batchIndex=${Math.floor(i / chunkSize)} batchSize=${chunk.length}`);
    await batch.commit();
    deleted += chunk.length;
    console.log(`[${context.prefix}] stage=${context.stage} uid=${context.uid} batchCommitted=${chunk.length}`);
  }

  return deleted;
}

export const deleteMyAccount = onCall({ region: 'us-central1' }, async (request) => {
  const uid = request.auth?.uid;
  const mode = typeof request.data?.mode === 'string' ? String(request.data.mode) : 'default';
  const requestedRole = typeof request.data?.role === 'string' ? String(request.data.role).toLowerCase() : undefined;

  if (!uid) {
    throw new HttpsError('failed-precondition', 'Authentication required.', { stage: 'start', mode });
  }

  const deletedCounts = {
    userDoc: 0,
    employeeStoreMirrors: 0,
    storeMembers: 0,
    employeeCheckins: 0,
    globalCheckins: 0,
    employeeProfileDoc: 0,
    employeeStoresRootDoc: 0,
    employeeCheckinsRootDoc: 0,
    authUser: 0,
  };

  try {
    console.log(`[deleteMyAccount] stage=start uid=${uid} mode=${mode} roleHint=${requestedRole ?? 'none'} payload=${JSON.stringify(request.data ?? {})}`);
    const userRef = db.collection('users').doc(uid);
    const userSnap = await userRef.get();
    const userData = userSnap.data() ?? {};
    const role = typeof userData.role === 'string' ? String(userData.role).toLowerCase() : requestedRole ?? 'employee';

    if (userSnap.exists && userData.isActive === false) {
      throw new HttpsError('failed-precondition', 'Inactive accounts cannot self-delete.', { stage: 'resolveRole', uid, role });
    }
    if (role !== 'employee') {
      throw new HttpsError('permission-denied', 'Only employees can call deleteMyAccount.', { stage: 'resolveRole', uid, role });
    }

    console.log(`[deleteMyAccount] stage=resolveRole uid=${uid} role=${role} userDocExists=${userSnap.exists}`);

    const assignedStoreIds = Array.isArray(userData.assignedStoreIds)
      ? userData.assignedStoreIds.filter((value): value is string => typeof value === 'string' && value.length > 0)
      : [];

    const employeeStoreSnap = await db.collection('employeeStores').doc(uid).collection('stores').get();
    const mirroredStoreIds = employeeStoreSnap.docs.map((doc) => doc.id).filter((value) => value.length > 0);

    const membersByEmployeeIdSnap = await db.collectionGroup('members').where('employeeId', '==', uid).get();
    const membersByUserIdSnap = await db.collectionGroup('members').where('userId', '==', uid).get();
    const employeeCheckinsSnap = await db.collection('employeeCheckins').doc(uid).collection('checkins').get();
    const globalCheckinsByEmployee = await db.collection('checkins').where('employeeId', '==', uid).get();

    const storeIds = new Set<string>([...assignedStoreIds, ...mirroredStoreIds]);
    const membershipRefsByPath = new Map<string, FirebaseFirestore.DocumentReference>();

    for (const memberDoc of [...membersByEmployeeIdSnap.docs, ...membersByUserIdSnap.docs]) {
      const storeId = memberDoc.ref.parent.parent?.id;
      if (storeId) {
        storeIds.add(storeId);
      }
      membershipRefsByPath.set(memberDoc.ref.path, memberDoc.ref);
    }

    console.log(`[deleteMyAccount] stage=collectRefs uid=${uid} stores=${storeIds.size} memberRefs=${membershipRefsByPath.size} employeeCheckins=${employeeCheckinsSnap.size} globalCheckins=${globalCheckinsByEmployee.size}`);

    const refsToDelete: FirebaseFirestore.DocumentReference[] = [];
    for (const storeId of storeIds) {
      const memberRef = db.collection('stores').doc(storeId).collection('members').doc(uid);
      const employeeStoreRef = db.collection('employeeStores').doc(uid).collection('stores').doc(storeId);
      refsToDelete.push(memberRef);
      refsToDelete.push(employeeStoreRef);
    }

    for (const ref of membershipRefsByPath.values()) {
      refsToDelete.push(ref);
    }

    for (const checkinDoc of employeeCheckinsSnap.docs) {
      refsToDelete.push(checkinDoc.ref);
    }

    for (const checkinDoc of globalCheckinsByEmployee.docs) {
      refsToDelete.push(checkinDoc.ref);
    }

    const employeeCheckinsRootRef = db.collection('employeeCheckins').doc(uid);
    const employeeStoresRootRef = db.collection('employeeStores').doc(uid);
    const employeeProfileRef = db.collection('employees').doc(uid);

    refsToDelete.push(employeeCheckinsRootRef, employeeStoresRootRef, employeeProfileRef, userRef);

    console.log(`[deleteMyAccount] stage=deleteBatches uid=${uid} refs=${refsToDelete.length}`);
    const deletedDocs = await commitDeleteBatch(refsToDelete, { prefix: 'deleteMyAccount', uid, stage: 'deleteBatches' });

    deletedCounts.employeeStoreMirrors = employeeStoreSnap.size;
    deletedCounts.storeMembers = membershipRefsByPath.size;
    deletedCounts.employeeCheckins = employeeCheckinsSnap.size;
    deletedCounts.globalCheckins = globalCheckinsByEmployee.size;
    deletedCounts.employeeProfileDoc = 1;
    deletedCounts.employeeStoresRootDoc = 1;
    deletedCounts.employeeCheckinsRootDoc = 1;
    deletedCounts.userDoc = 1;

    let deletedAuth = false;
    try {
      console.log(`[deleteMyAccount] stage=deleteAuthUser uid=${uid}`);
      await admin.auth().deleteUser(uid);
      deletedAuth = true;
      deletedCounts.authUser = 1;
    } catch (error: any) {
      const code = typeof error?.code === 'string' ? error.code : 'unknown';
      if (code === 'auth/user-not-found') {
        console.log(`[deleteMyAccount] stage=deleteAuthUser uid=${uid} alreadyDeleted=true`);
      } else {
        throw error;
      }
    }

    const cleanedMemberships = membershipRefsByPath.size + storeIds.size;
    console.log(`[deleteMyAccount] stage=done uid=${uid} cleanedMemberships=${cleanedMemberships} deletedDocs=${deletedDocs} deletedAuth=${deletedAuth}`);
    return { ok: true, deletedAuth, cleanedMemberships, deletedDocs, deletedCounts };
  } catch (error) {
    if (error instanceof HttpsError) {
      console.error(`[deleteMyAccount][ERROR] uid=${uid} code=${error.code} message=${error.message} payload=${JSON.stringify(request.data ?? {})} stack=${error.stack ?? '<none>'} details=${JSON.stringify(error.details ?? {})}`);
      throw error;
    }

    const message = error instanceof Error ? error.message : 'Unknown error';
    const stack = error instanceof Error ? error.stack ?? '<none>' : '<none>';
    console.error(`[deleteMyAccount][ERROR] uid=${uid} message=${message} payload=${JSON.stringify(request.data ?? {})} stack=${stack}`);
    throw new HttpsError('internal', 'delete_account_failed', { stage: 'unknown', uid, message, mode });
  }
});

export const deleteManagerAccount = onCall({ region: 'us-central1' }, async (request) => {
  const managerUid = request.auth?.uid;
  const mode = typeof request.data?.mode === 'string' ? String(request.data.mode) : 'default';

  if (!managerUid) {
    throw new HttpsError('failed-precondition', 'Authentication required.', { stage: 'start', mode });
  }

  const providedManagerId = typeof request.data?.managerId === 'string' ? request.data.managerId : managerUid;
  if (providedManagerId !== managerUid) {
    throw new HttpsError('permission-denied', 'managerId must match authenticated user.', { stage: 'start', managerUid, providedManagerId });
  }

  const deletedCounts = {
    stores: 0,
    storeMembers: 0,
    employeeStoreMirrors: 0,
    managerStoreMirrors: 0,
    managerCheckinStores: 0,
    managerCheckins: 0,
    rootCheckins: 0,
    employeeUnlinks: 0,
    userDoc: 0,
    managerDoc: 0,
    authUser: 0,
  };

  try {
    console.log(`[deleteManagerAccount] stage=start uid=${managerUid} mode=${mode} payload=${JSON.stringify(request.data ?? {})}`);
    const userRef = db.collection('users').doc(managerUid);
    const userSnap = await userRef.get();
    const userData = userSnap.data() ?? {};
    const role = typeof userData.role === 'string' ? String(userData.role).toLowerCase() : '';

    if (userSnap.exists && userData.isActive === false) {
      throw new HttpsError('failed-precondition', 'Inactive accounts cannot self-delete.', {
        stage: 'resolveRole',
        uid: managerUid,
        role,
      });
    }
    if (role && role !== 'manager') {
      throw new HttpsError('permission-denied', 'Only managers can call deleteManagerAccount.', {
        stage: 'resolveRole',
        uid: managerUid,
        role,
      });
    }

    console.log(`[deleteManagerAccount] stage=resolveRole uid=${managerUid} role=${role || 'unknown'} userDocExists=${userSnap.exists}`);

    const storesSnap = await db.collection('stores').where('managerId', '==', managerUid).get();
    const storeDocs = storesSnap.docs;
    const storeIds = storeDocs.map((doc) => doc.id);
    const unlinkedEmployees = new Set<string>();
    let deletedDocs = 0;

    console.log(`[deleteManagerAccount] stage=collectStores uid=${managerUid} storeCount=${storeDocs.length}`);

    for (const storeDoc of storeDocs) {
      const storeId = storeDoc.id;
      const membersSnap = await db.collection('stores').doc(storeId).collection('members').get();
      const refsToDelete: FirebaseFirestore.DocumentReference[] = [];
      const storeEmployeeUids = new Set<string>();

      console.log(`[deleteManagerAccount] stage=collectMembers uid=${managerUid} storeId=${storeId} memberCount=${membersSnap.size}`);

      for (const memberDoc of membersSnap.docs) {
        const memberData = memberDoc.data();
        const employeeUid =
          typeof memberData.employeeId === 'string'
            ? memberData.employeeId
            : typeof memberData.userId === 'string'
            ? memberData.userId
            : memberDoc.id;
        const memberRole = typeof memberData.role === 'string' ? memberData.role : 'employee';

        refsToDelete.push(memberDoc.ref);
        deletedCounts.storeMembers += 1;

        if (memberRole !== 'manager' && employeeUid && employeeUid !== managerUid) {
          refsToDelete.push(db.collection('employeeStores').doc(employeeUid).collection('stores').doc(storeId));
          deletedCounts.employeeStoreMirrors += 1;
          unlinkedEmployees.add(employeeUid);
          storeEmployeeUids.add(employeeUid);
        }
      }

      const managerCheckinsStoreRef = db.collection('managerCheckins').doc(managerUid).collection('stores').doc(storeId);
      const managerCheckinsSnap = await managerCheckinsStoreRef.collection('checkins').get();
      console.log(`[deleteManagerAccount] stage=collectManagerCheckins uid=${managerUid} storeId=${storeId} checkins=${managerCheckinsSnap.size}`);
      for (const checkinDoc of managerCheckinsSnap.docs) {
        refsToDelete.push(checkinDoc.ref);
        deletedCounts.managerCheckins += 1;
      }
      refsToDelete.push(managerCheckinsStoreRef);
      deletedCounts.managerCheckinStores += 1;

      const rootCheckinsSnap = await db.collection('checkins').where('storeId', '==', storeId).get();
      console.log(`[deleteManagerAccount] stage=collectRootCheckins uid=${managerUid} storeId=${storeId} checkins=${rootCheckinsSnap.size}`);
      for (const checkinDoc of rootCheckinsSnap.docs) {
        refsToDelete.push(checkinDoc.ref);
        deletedCounts.rootCheckins += 1;

        const checkinData = checkinDoc.data();
        const employeeUid = typeof checkinData.employeeId === 'string' ? checkinData.employeeId : undefined;
        if (employeeUid) {
          refsToDelete.push(db.collection('employeeCheckins').doc(employeeUid).collection('checkins').doc(checkinDoc.id));
        }
      }

      refsToDelete.push(db.collection('stores').doc(storeId));
      deletedDocs += await commitDeleteBatch(refsToDelete, { prefix: 'deleteManagerAccount', uid: managerUid, stage: `store:${storeId}` });

      for (const employeeUid of storeEmployeeUids) {
        console.log(`[deleteManagerAccount] stage=unlinkEmployee uid=${managerUid} employeeUid=${employeeUid} storeId=${storeId}`);
        await db
          .collection('users')
          .doc(employeeUid)
          .set(
            {
              assignedStoreIds: admin.firestore.FieldValue.arrayRemove(storeId),
              currentStoreId: admin.firestore.FieldValue.delete(),
              currentStore: admin.firestore.FieldValue.delete(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true },
          );
        await db
          .collection('employees')
          .doc(employeeUid)
          .set(
            {
              assignedStoreIds: admin.firestore.FieldValue.arrayRemove(storeId),
              currentStoreId: admin.firestore.FieldValue.delete(),
              currentStore: admin.firestore.FieldValue.delete(),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true },
          )
          .catch(() => undefined);
      }

      await db.collection('managerStores').doc(managerUid).collection('stores').doc(storeId).delete().catch(() => undefined);
      deletedCounts.managerStoreMirrors += 1;
      deletedCounts.stores += 1;
    }

    await db.collection('managerStores').doc(managerUid).delete().catch(() => undefined);
    await db.collection('managerCheckins').doc(managerUid).delete().catch(() => undefined);

    console.log(`[deleteManagerAccount] stage=deleteProfile uid=${managerUid}`);
    deletedDocs += await commitDeleteBatch([db.collection('managers').doc(managerUid), db.collection('users').doc(managerUid)], {
      prefix: 'deleteManagerAccount',
      uid: managerUid,
      stage: 'profile',
    });
    deletedCounts.managerDoc = 1;
    deletedCounts.userDoc = 1;
    deletedCounts.employeeUnlinks = unlinkedEmployees.size;

    let deletedAuth = false;
    try {
      console.log(`[deleteManagerAccount] stage=deleteAuthUser uid=${managerUid}`);
      await admin.auth().deleteUser(managerUid);
      deletedAuth = true;
      deletedCounts.authUser = 1;
    } catch (error: any) {
      const code = typeof error?.code === 'string' ? error.code : 'unknown';
      if (code === 'auth/user-not-found') {
        console.log(`[deleteManagerAccount] stage=deleteAuthUser uid=${managerUid} alreadyDeleted=true`);
      } else {
        throw error;
      }
    }

    const cleanedMemberships = deletedCounts.storeMembers + deletedCounts.employeeStoreMirrors;
    console.log(`[deleteManagerAccount] stage=done uid=${managerUid} cleanedMemberships=${cleanedMemberships} deletedDocs=${deletedDocs} deletedAuth=${deletedAuth} storeIds=${storeIds.join(',')}`);
    return {
      ok: true,
      deletedAuth,
      cleanedMemberships,
      deletedDocs,
      deletedCounts,
      storeIds,
    };
  } catch (error) {
    if (error instanceof HttpsError) {
      console.error(`[deleteManagerAccount][ERROR] uid=${managerUid} code=${error.code} message=${error.message} payload=${JSON.stringify(request.data ?? {})} stack=${error.stack ?? '<none>'} details=${JSON.stringify(error.details ?? {})}`);
      throw error;
    }

    const message = error instanceof Error ? error.message : 'Unknown error';
    const stack = error instanceof Error ? error.stack ?? '<none>' : '<none>';
    console.error(`[deleteManagerAccount][ERROR] uid=${managerUid} message=${message} payload=${JSON.stringify(request.data ?? {})} stack=${stack}`);
    throw new HttpsError('internal', 'delete_manager_account_failed', {
      stage: 'unknown',
      uid: managerUid,
      message,
      mode,
    });
  }
});
