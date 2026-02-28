const { onCall, onRequest, HttpsError } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const crypto = require('crypto');

admin.initializeApp();
const db = admin.firestore();

// README snippet: deploy all Cloud Functions with `firebase deploy --only functions`

function normalizeCode(code) {
  return String(code || '').trim().toUpperCase();
}

function hashCode(normalizedCode) {
  return crypto.createHash('sha256').update(normalizedCode).digest('hex');
}

function generateJoinCode(length = 8) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  const bytes = crypto.randomBytes(length);
  let code = '';
  for (let i = 0; i < length; i += 1) {
    code += alphabet[bytes[i] % alphabet.length];
  }
  return code;
}

async function requireActiveUser(uid) {
  const snap = await db.collection('users').doc(uid).get();
  if (!snap.exists) throw new HttpsError('permission-denied', 'User profile not found.');
  const user = snap.data();
  if (user.isActive !== true) throw new HttpsError('permission-denied', 'Account inactive.');
  return user;
}

async function requireManager(uid) {
  const user = await requireActiveUser(uid);
  if (user.role !== 'manager') throw new HttpsError('permission-denied', 'Manager access required.');
  return user;
}

async function requireActiveManagerProfile(uid) {
  const managerSnap = await db.collection('managers').doc(uid).get();
  if (!managerSnap.exists) throw new HttpsError('permission-denied', 'Manager profile not found.');
  const manager = managerSnap.data() || {};
  if (manager.isActive !== true) throw new HttpsError('permission-denied', 'Manager account is inactive.');
  return manager;
}

async function authenticateRequest(req) {
  const authHeader = req.headers.authorization || '';
  if (!authHeader.startsWith('Bearer ')) {
    throw new HttpsError('unauthenticated', 'Missing Authorization bearer token.');
  }

  const idToken = authHeader.slice('Bearer '.length).trim();
  if (!idToken) {
    throw new HttpsError('unauthenticated', 'Missing Firebase ID token.');
  }

  try {
    return await admin.auth().verifyIdToken(idToken);
  } catch (error) {
    throw new HttpsError('unauthenticated', 'Invalid Firebase ID token.');
  }
}

function extractDataPayload(req) {
  if (req.body && typeof req.body === 'object') {
    if (req.body.data && typeof req.body.data === 'object') {
      return req.body.data;
    }
    return req.body;
  }
  return {};
}

function sendHttpsError(res, error) {
  const statusMap = {
    'invalid-argument': 400,
    unauthenticated: 401,
    'permission-denied': 403,
    'not-found': 404,
    'failed-precondition': 412,
  };

  if (error instanceof HttpsError) {
    res.status(statusMap[error.code] || 500).json({ error: { message: error.message, status: error.code } });
    return;
  }

  console.error('[Functions] Unexpected error:', error);
  res.status(500).json({ error: { message: 'Internal server error.', status: 'internal' } });
}

exports.createStore = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Must be signed in.');
  await requireManager(request.auth.uid);

  const { name, address, latitude, longitude, radiusMeters } = request.data;
  if (!name || !address) throw new HttpsError('invalid-argument', 'name and address are required.');

  const joinCode = generateJoinCode();
  const storeRef = db.collection('stores').doc();
  const now = admin.firestore.FieldValue.serverTimestamp();

  await storeRef.set({
    name: String(name).trim(),
    address: String(address).trim(),
    latitude: Number(latitude),
    longitude: Number(longitude),
    radiusMeters: Number(radiusMeters) || 150,
    managerId: request.auth.uid,
    joinCode,
    joinCodeHash: hashCode(normalizeCode(joinCode)),
    joinCodeLast4: joinCode.slice(-4),
    joinCodeCiphertext: joinCode,
    isActive: true,
    createdAt: now,
    updatedAt: now,
  });

  await db.collection('storeMembers').doc(storeRef.id).collection('members').doc(request.auth.uid).set({
    userId: request.auth.uid,
    role: 'manager',
    joinedAt: now,
    isActive: true,
    addedBy: 'manager_action',
  }, { merge: true });

  return { storeId: storeRef.id, joinCode, joinCodeLast4: joinCode.slice(-4) };
});

exports.joinStoreByCode = onRequest({ region: 'us-central1' }, async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: { message: 'Method not allowed.' } });
    return;
  }

  try {
    const decodedToken = await authenticateRequest(req);
    const data = extractDataPayload(req);
    const code = normalizeCode(data.code);
    if (!code) {
      throw new HttpsError('invalid-argument', 'code is required.');
    }

    let storeDoc;
    const byJoinCode = await db.collection('stores').where('joinCode', '==', code).limit(1).get();
    if (!byJoinCode.empty) {
      storeDoc = byJoinCode.docs[0];
    } else {
      const byJoinCodeCiphertext = await db.collection('stores').where('joinCodeCiphertext', '==', code).limit(1).get();
      if (byJoinCodeCiphertext.empty) throw new HttpsError('not-found', 'Invalid join code');
      storeDoc = byJoinCodeCiphertext.docs[0];
    }

    const storeId = storeDoc.id;
    const employeeUid = decodedToken.uid;
    const memberRef = db.collection('storeMembers').doc(storeId).collection('members').doc(employeeUid);
    const existingMembership = await memberRef.get();
    const alreadyJoined = existingMembership.exists;

    await memberRef.set({
      userId: employeeUid,
      role: 'employee',
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
      isActive: true,
      addedBy: 'join_code',
      storeId,
      storeName: storeDoc.data().name || 'Store',
    }, { merge: true });

    res.status(200).json({ result: { storeId, storeName: storeDoc.data().name || 'Store', alreadyJoined } });
  } catch (error) {
    sendHttpsError(res, error);
  }
});

exports.rotateStoreCode = onRequest({ region: 'us-central1' }, async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: { message: 'Method not allowed.' } });
    return;
  }

  try {
    const decodedToken = await authenticateRequest(req);
    await requireActiveManagerProfile(decodedToken.uid);

    const data = extractDataPayload(req);
    const { storeId } = data;
    if (!storeId || typeof storeId !== 'string') throw new HttpsError('invalid-argument', 'storeId is required.');

    const storeRef = db.collection('stores').doc(storeId);
    const storeSnap = await storeRef.get();
    if (!storeSnap.exists) throw new HttpsError('not-found', 'Store not found.');
    if (storeSnap.data().managerId !== decodedToken.uid) throw new HttpsError('permission-denied', 'Not store owner.');

    const joinCode = generateJoinCode();
    await storeRef.set({
      joinCode,
      joinCodeHash: hashCode(normalizeCode(joinCode)),
      joinCodeLast4: joinCode.slice(-4),
      joinCodeCiphertext: joinCode,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    res.status(200).json({ result: { joinCode } });
  } catch (error) {
    sendHttpsError(res, error);
  }
});

exports.getStoreJoinCode = onRequest({ region: 'us-central1' }, async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: { message: 'Method not allowed.' } });
    return;
  }

  try {
    const decodedToken = await authenticateRequest(req);
    await requireActiveManagerProfile(decodedToken.uid);

    const data = extractDataPayload(req);
    const { storeId } = data;
    if (!storeId || typeof storeId !== 'string') throw new HttpsError('invalid-argument', 'storeId is required.');

    const snap = await db.collection('stores').doc(storeId).get();
    if (!snap.exists) throw new HttpsError('not-found', 'Store not found.');
    const store = snap.data();
    if (store.managerId !== decodedToken.uid) throw new HttpsError('permission-denied', 'Not store owner.');

    const joinCode = store.joinCodeCiphertext || store.joinCode;
    if (!joinCode) throw new HttpsError('failed-precondition', 'Rotate code to reveal latest code.');

    res.status(200).json({ result: { joinCode } });
  } catch (error) {
    sendHttpsError(res, error);
  }
});

exports.removeEmployeeFromStore = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'You must be signed in.');
  await requireManager(request.auth.uid);

  const { storeId, employeeId } = request.data;
  const storeSnap = await db.collection('stores').doc(storeId).get();
  if (!storeSnap.exists) throw new HttpsError('not-found', 'Store not found.');
  if (storeSnap.data().managerId !== request.auth.uid) throw new HttpsError('permission-denied', 'Not store owner.');

  await db.collection('storeMembers').doc(storeId).collection('members').doc(employeeId).delete();
  await db.collection('users').doc(employeeId).set({
    assignedStoreIds: admin.firestore.FieldValue.arrayRemove(storeId),
  }, { merge: true });
  return { ok: true };
});

exports.removeEmployeeFromAllManagerStores = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'You must be signed in.');
  await requireManager(request.auth.uid);
  const { employeeId, managerId } = request.data;
  if (managerId !== request.auth.uid) throw new HttpsError('permission-denied', 'managerId mismatch.');

  const stores = await db.collection('stores').where('managerId', '==', request.auth.uid).get();
  const batch = db.batch();
  const removedIds = [];

  stores.docs.forEach((doc) => {
    removedIds.push(doc.id);
    batch.delete(db.collection('storeMembers').doc(doc.id).collection('members').doc(employeeId));
  });

  if (removedIds.length > 0) {
    batch.set(db.collection('users').doc(employeeId), {
      assignedStoreIds: admin.firestore.FieldValue.arrayRemove(...removedIds),
    }, { merge: true });
  }
  await batch.commit();
  return { removedStoreIds: removedIds };
});

exports.setEmployeeStoresForManager = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'You must be signed in.');
  await requireManager(request.auth.uid);

  const { employeeId, storeIds } = request.data;
  const targetStoreIds = Array.isArray(storeIds) ? [...new Set(storeIds)] : [];

  const ownedStoresSnap = await db.collection('stores').where('managerId', '==', request.auth.uid).get();
  const owned = new Set(ownedStoresSnap.docs.map((d) => d.id));

  for (const storeId of targetStoreIds) {
    if (!owned.has(storeId)) throw new HttpsError('permission-denied', 'Cannot assign unowned store.');
  }

  const memberStores = [];
  for (const store of ownedStoresSnap.docs) {
    const memberSnap = await db.collection('storeMembers').doc(store.id).collection('members').doc(employeeId).get();
    if (memberSnap.exists) memberStores.push(store.id);
  }

  const toAdd = targetStoreIds.filter((id) => !memberStores.includes(id));
  const toRemove = memberStores.filter((id) => !targetStoreIds.includes(id));

  const batch = db.batch();
  toAdd.forEach((storeId) => {
    batch.set(db.collection('storeMembers').doc(storeId).collection('members').doc(employeeId), {
      userId: employeeId,
      role: 'employee',
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
      isActive: true,
      addedBy: 'manager_action',
    }, { merge: true });
  });
  toRemove.forEach((storeId) => {
    batch.delete(db.collection('storeMembers').doc(storeId).collection('members').doc(employeeId));
  });

  if (toAdd.length) {
    batch.set(db.collection('users').doc(employeeId), { assignedStoreIds: admin.firestore.FieldValue.arrayUnion(...toAdd) }, { merge: true });
  }
  if (toRemove.length) {
    batch.set(db.collection('users').doc(employeeId), { assignedStoreIds: admin.firestore.FieldValue.arrayRemove(...toRemove) }, { merge: true });
  }

  await batch.commit();
  return { assignedStoreIds: targetStoreIds };
});

exports.setEmployeeActive = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'You must be signed in.');
  await requireManager(request.auth.uid);

  const { employeeId, isActive } = request.data;

  const memberStoreQuery = await db.collectionGroup('members')
    .where(admin.firestore.FieldPath.documentId(), '==', employeeId)
    .where('role', '==', 'employee')
    .get();

  const managerOwnsAny = await Promise.all(memberStoreQuery.docs.map(async (memberDoc) => {
    const storeId = memberDoc.ref.parent.parent.id;
    const store = await db.collection('stores').doc(storeId).get();
    return store.exists && store.data().managerId === request.auth.uid;
  }));

  if (!managerOwnsAny.some(Boolean)) throw new HttpsError('permission-denied', 'Employee not in your stores.');

  await db.collection('users').doc(employeeId).set({ isActive: !!isActive }, { merge: true });
  return { employeeId, isActive: !!isActive };
});

async function cleanupMemberships(uid, correlationId) {
  const memberDocs = await db.collectionGroup('members')
    .where(admin.firestore.FieldPath.documentId(), '==', uid)
    .get();

  const membershipCount = memberDocs.size;
  const storeIds = new Set();
  const membershipRefs = [];

  memberDocs.docs.forEach((doc) => {
    const parentDoc = doc.ref.parent && doc.ref.parent.parent;
    const storeId = parentDoc && typeof parentDoc.id === 'string' ? parentDoc.id : null;
    if (storeId) {
      storeIds.add(storeId);
    } else {
      console.warn(`[cleanupMemberships] uid=${uid} correlationId=${correlationId} skippedMembershipWithoutStorePath ref=${doc.ref.path}`);
    }
    membershipRefs.push(doc.ref);
  });

  const storeIdsList = [...storeIds];
  const storeUpdateRefs = storeIdsList.map((storeId) => db.collection('stores').doc(storeId));
  const userRef = db.collection('users').doc(uid);

  console.log(`[cleanupMemberships] uid=${uid} correlationId=${correlationId} memberDocsFound=${membershipCount}`);
  console.log(`[cleanupMemberships] uid=${uid} correlationId=${correlationId} storeIdsDerived=${JSON.stringify(storeIdsList)}`);

  const maxOpsPerBatch = 450;
  const now = admin.firestore.FieldValue.serverTimestamp();
  const userSnap = await userRef.get();
  const deletedUserDoc = userSnap.exists;

  const writeOperations = [
    ...membershipRefs.map((ref) => ({ type: 'delete', ref })),
    ...storeUpdateRefs.map((ref) => ({ type: 'set', ref })),
    { type: 'delete', ref: userRef },
  ];

  let operationCount = 0;
  for (let i = 0; i < writeOperations.length; i += maxOpsPerBatch) {
    const chunk = writeOperations.slice(i, i + maxOpsPerBatch);
    const batch = db.batch();

    chunk.forEach((operation) => {
      if (operation.type === 'delete') {
        batch.delete(operation.ref);
      } else {
        batch.set(operation.ref, { updatedAt: now }, { merge: true });
      }
    });

    await batch.commit();
    operationCount += chunk.length;
    console.log(`[cleanupMemberships] uid=${uid} correlationId=${correlationId} batchCommit chunkSize=${chunk.length} totalCommittedOps=${operationCount}`);
  }

  let employeeStoresCount = 0;
  let employeeCheckinsCount = 0;

  const deleteCollectionInChunks = async (refs, label) => {
    for (let i = 0; i < refs.length; i += maxOpsPerBatch) {
      const chunk = refs.slice(i, i + maxOpsPerBatch);
      const batch = db.batch();
      chunk.forEach((ref) => batch.delete(ref));
      await batch.commit();
      console.log(`[cleanupMemberships] uid=${uid} correlationId=${correlationId} committed ${label} chunkSize=${chunk.length}`);
    }
  };

  const employeeStoresSnap = await db.collection('employeeStores').doc(uid).collection('stores').get();
  employeeStoresCount = employeeStoresSnap.size;
  console.log(`[cleanupMemberships] uid=${uid} correlationId=${correlationId} employeeStoresDocsFound=${employeeStoresCount}`);
  await deleteCollectionInChunks(employeeStoresSnap.docs.map((doc) => doc.ref), 'employeeStores');

  const employeeCheckinsSnap = await db.collection('employeeCheckins').doc(uid).collection('checkins').get();
  employeeCheckinsCount = employeeCheckinsSnap.size;
  console.log(`[cleanupMemberships] uid=${uid} correlationId=${correlationId} employeeCheckinsDocsFound=${employeeCheckinsCount}`);
  await deleteCollectionInChunks(employeeCheckinsSnap.docs.map((doc) => doc.ref), 'employeeCheckins');

  console.log(`[cleanupMemberships] uid=${uid} correlationId=${correlationId} batchOperationsCount=${operationCount}`);

  return {
    deletedMembershipCount: membershipCount,
    storeCount: storeIdsList.length,
    deletedUserDoc,
    employeeStoresCount,
    employeeCheckinsCount,
    batchOperationsCount: operationCount,
  };
}

function mapDeleteMyAccountError(error) {
  if (error instanceof HttpsError) {
    return error;
  }

  const code = error && typeof error.code !== 'undefined' ? String(error.code) : '';
  const loweredCode = code.toLowerCase();
  const message = error?.message || String(error);

  if (loweredCode.includes('permission') || loweredCode === '7') {
    return new HttpsError('permission-denied', message);
  }

  if (loweredCode.includes('not-found') || loweredCode === '5') {
    return new HttpsError('not-found', message);
  }

  if (loweredCode.includes('failed-precondition') || loweredCode === '9') {
    return new HttpsError('failed-precondition', message);
  }

  return new HttpsError('internal', message);
}

exports.deleteMyAccount = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'You must be signed in.');
  const uid = request.auth.uid;
  const mode = typeof request.data.mode === 'string' ? request.data.mode : 'cleanup_memberships';
  const role = typeof request.data.role === 'string' ? request.data.role : 'none';
  const correlationId = typeof request.data.correlationId === 'string' && request.data.correlationId ? request.data.correlationId : 'none';
  console.log(`[deleteMyAccount] VERSION=2026-02-28b uid=${uid} mode=${mode} role=${role} correlationId=${correlationId}`);

  try {
    await requireActiveUser(uid);
    console.log(`[deleteMyAccount] start uid=${uid} mode=${mode} role=${role} correlationId=${correlationId}`);

    if (mode === 'cleanup_memberships') {
      const cleanupSummary = await cleanupMemberships(uid, correlationId);
      console.log(`[deleteMyAccount] uid=${uid} mode=${mode} role=${role} correlationId=${correlationId} deletedMembershipCount=${cleanupSummary.deletedMembershipCount} storeCount=${cleanupSummary.storeCount} batchOperationsCount=${cleanupSummary.batchOperationsCount}`);
      return {
        ok: true,
        mode,
        deletedUserDoc: cleanupSummary.deletedUserDoc,
        deletedMembershipCount: cleanupSummary.deletedMembershipCount,
        storeCount: cleanupSummary.storeCount,
      };
    }

    if (mode === 'delete_auth') {
      await admin.auth().deleteUser(uid);
      return { ok: true, mode, deletedUserDoc: false, deletedMembershipCount: 0, storeCount: 0 };
    }

    throw new HttpsError('invalid-argument', `Unsupported deleteMyAccount mode: ${mode}`);
  } catch (error) {
    console.error(`[deleteMyAccount] fail uid=${uid} mode=${mode} role=${role} correlationId=${correlationId} stack=${error?.stack || 'n/a'}`, error);
    throw mapDeleteMyAccountError(error);
  }
});
