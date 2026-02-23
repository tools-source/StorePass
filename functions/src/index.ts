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

async function commitDeleteBatch(paths: FirebaseFirestore.DocumentReference[]): Promise<void> {
  if (paths.length === 0) {
    return;
  }

  const chunkSize = 350;
  for (let i = 0; i < paths.length; i += chunkSize) {
    const chunk = paths.slice(i, i + chunkSize);
    const batch = db.batch();
    for (const ref of chunk) {
      batch.delete(ref);
    }
    await batch.commit();
  }
}

export const deleteManagerAccount = onCall({ region: 'us-central1' }, async (request) => {
  const managerUid = request.auth?.uid;
  const requestedManagerId = typeof request.data?.managerId === 'string' ? request.data.managerId : undefined;

  if (!managerUid) {
    throw new HttpsError('unauthenticated', 'Authentication required.');
  }
  if (requestedManagerId && requestedManagerId !== managerUid) {
    throw new HttpsError('permission-denied', 'managerId must match authenticated user.');
  }

  console.log(`[deleteManagerAccount] managerUid=${managerUid}`);

  let deletedStoresCount = 0;
  let unlinkedEmployeesCount = 0;
  let deletedCheckinsCount = 0;

  try {
    const storesSnap = await db.collection('stores').where('managerId', '==', managerUid).get();
    const storeDocs = storesSnap.docs;
    const storeIds = storeDocs.map((doc) => doc.id);
    const unlinkedEmployees = new Set<string>();
    const checkinIds = new Set<string>();

    console.log(`[deleteManagerAccount] storesFound=${storeDocs.length}`);

    for (const storeDoc of storeDocs) {
      const storeId = storeDoc.id;

      try {
        const membersSnap = await db.collection('stores').doc(storeId).collection('members').get();
        const refsToDelete: FirebaseFirestore.DocumentReference[] = [];
        const storeEmployeeUids = new Set<string>();
        let employeesUnlinkedForStore = 0;

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

          if (memberRole !== 'manager' && employeeUid && employeeUid !== managerUid) {
            refsToDelete.push(db.collection('employeeStores').doc(employeeUid).collection('stores').doc(storeId));
            employeesUnlinkedForStore += 1;
            unlinkedEmployees.add(employeeUid);
            storeEmployeeUids.add(employeeUid);
          }
        }

        refsToDelete.push(db.collection('stores').doc(storeId));
        await commitDeleteBatch(refsToDelete);

        for (const employeeUid of storeEmployeeUids) {
          await db
            .collection('users')
            .doc(employeeUid)
            .set(
              {
                assignedStoreIds: admin.firestore.FieldValue.arrayRemove(storeId),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              },
              { merge: true },
            );
        }

        const rootCheckinsSnap = await db.collection('checkins').where('storeId', '==', storeId).get();
        const checkinDeleteRefs: FirebaseFirestore.DocumentReference[] = [];

        for (const checkinDoc of rootCheckinsSnap.docs) {
          checkinIds.add(checkinDoc.id);
          checkinDeleteRefs.push(checkinDoc.ref);
          const checkinData = checkinDoc.data();
          const employeeUid = typeof checkinData.employeeId === 'string' ? checkinData.employeeId : undefined;
          if (employeeUid) {
            checkinDeleteRefs.push(db.collection('employeeCheckins').doc(employeeUid).collection('checkins').doc(checkinDoc.id));
          }
        }

        await commitDeleteBatch(checkinDeleteRefs);

        deletedStoresCount += 1;
        deletedCheckinsCount += rootCheckinsSnap.size;
        console.log(
          `[deleteManagerAccount] storeId=${storeId} membersDeleted=${membersSnap.size} employeesUnlinked=${employeesUnlinkedForStore}`,
        );
      } catch (error) {
        console.error('[deleteManagerAccount] cleanup failed for store', { storeId, error });
        throw new HttpsError('internal', 'cleanup_failed', { step: 'store_cleanup', storeId });
      }
    }

    try {
      const managerStoresSnap = await db.collection('managerStores').doc(managerUid).collection('stores').get();
      const managerStoresRefs = managerStoresSnap.docs.map((doc) => doc.ref);
      managerStoresRefs.push(db.collection('managerStores').doc(managerUid));
      await commitDeleteBatch(managerStoresRefs);

      const managerCheckinStoresSnap = await db.collection('managerCheckins').doc(managerUid).collection('stores').get();
      for (const storeMirrorDoc of managerCheckinStoresSnap.docs) {
        const checkinsSnap = await storeMirrorDoc.ref.collection('checkins').get();
        await commitDeleteBatch(checkinsSnap.docs.map((doc) => doc.ref));
      }
      const managerCheckinStoreRefs = managerCheckinStoresSnap.docs.map((doc) => doc.ref);
      managerCheckinStoreRefs.push(db.collection('managerCheckins').doc(managerUid));
      await commitDeleteBatch(managerCheckinStoreRefs);

      console.log(
        `[deleteManagerAccount] mirrorsDeleted=managerStores:${managerStoresSnap.size},managerCheckinsStores:${managerCheckinStoresSnap.size}`,
      );
    } catch (error) {
      console.error('[deleteManagerAccount] mirror cleanup failed', error);
      throw new HttpsError('internal', 'cleanup_failed', { step: 'manager_mirrors' });
    }

    try {
      await commitDeleteBatch([
        db.collection('managers').doc(managerUid),
        db.collection('users').doc(managerUid),
      ]);
    } catch (error) {
      console.error('[deleteManagerAccount] manager profile cleanup failed', error);
      throw new HttpsError('internal', 'cleanup_failed', { step: 'manager_profile' });
    }

    unlinkedEmployeesCount = unlinkedEmployees.size;
    console.log('[deleteManagerAccount] done');
    return {
      ok: true,
      deletedStoresCount,
      unlinkedEmployeesCount,
      deletedCheckinsCount,
      deletedCheckinMirrorCount: checkinIds.size,
      managerUid,
      storeIds,
    };
  } catch (error) {
    if (error instanceof HttpsError) {
      throw error;
    }
    console.error('[deleteManagerAccount] unexpected failure', error);
    throw new HttpsError('internal', 'cleanup_failed', { step: 'unknown' });
  }
});
