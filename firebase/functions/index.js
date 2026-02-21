const { onCall, HttpsError } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const crypto = require('crypto');

admin.initializeApp();
const db = admin.firestore();

function normalizeCode(code) {
  return String(code || '').trim().toUpperCase();
}

function hashCode(normalizedCode) {
  return crypto.createHash('sha256').update(normalizedCode).digest('hex');
}

function generateJoinCode(length = 8) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
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

exports.joinStoreByCode = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'You must be signed in.');

  const code = normalizeCode(request.data.code);
  if (!code || code.length < 6) {
    throw new HttpsError('invalid-argument', 'Please enter a valid join code.');
  }

  const user = await requireActiveUser(request.auth.uid);
  if (user.role !== 'employee') throw new HttpsError('permission-denied', 'Only employees can join by code.');

  const storeQuery = await db.collection('stores')
    .where('joinCodeHash', '==', hashCode(code))
    .where('isActive', '==', true)
    .limit(1)
    .get();
  if (storeQuery.empty) throw new HttpsError('not-found', 'Invalid join code.');

  const storeDoc = storeQuery.docs[0];
  const storeId = storeDoc.id;
  const employeeUid = request.auth.uid;
  const memberRef = db.collection('storeMembers').doc(storeId).collection('members').doc(employeeUid);
  const existingMembership = await memberRef.get();
  const alreadyJoined = existingMembership.exists;

  await memberRef.set({
    userId: employeeUid,
    memberId: employeeUid,
    role: 'employee',
    joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    isActive: true,
    addedBy: 'self_join',
  }, { merge: true });

  return {
    storeId,
    storeName: storeDoc.data().name || 'Store',
    alreadyJoined,
  };
});

exports.rotateStoreCode = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'You must be signed in.');
  await requireManager(request.auth.uid);

  const { storeId } = request.data;
  const storeRef = db.collection('stores').doc(storeId);
  const storeSnap = await storeRef.get();
  if (!storeSnap.exists) throw new HttpsError('not-found', 'Store not found.');
  if (storeSnap.data().managerId !== request.auth.uid) throw new HttpsError('permission-denied', 'Not store owner.');

  const joinCode = generateJoinCode();
  await storeRef.set({
    joinCodeHash: hashCode(normalizeCode(joinCode)),
    joinCodeLast4: joinCode.slice(-4),
    joinCodeCiphertext: joinCode,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  return { storeId, joinCode, joinCodeLast4: joinCode.slice(-4) };
});

exports.getStoreJoinCode = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'You must be signed in.');
  await requireManager(request.auth.uid);

  const { storeId } = request.data;
  const snap = await db.collection('stores').doc(storeId).get();
  if (!snap.exists) throw new HttpsError('not-found', 'Store not found.');
  const store = snap.data();
  if (store.managerId !== request.auth.uid) throw new HttpsError('permission-denied', 'Not store owner.');
  if (!store.joinCodeCiphertext) throw new HttpsError('failed-precondition', 'Rotate code to reveal latest code.');

  return { storeId, joinCode: store.joinCodeCiphertext };
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

exports.deleteMyAccount = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'You must be signed in.');
  const uid = request.auth.uid;
  const mode = request.data.mode;
  const user = await requireActiveUser(uid);

  if (user.role === 'manager' && mode !== 'manager_delete_all') {
    throw new HttpsError('failed-precondition', 'Managers must use manager_delete_all or keep stores mode (not enabled).');
  }

  const memberDocs = await db.collectionGroup('members')
    .where(admin.firestore.FieldPath.documentId(), '==', uid)
    .get();

  const batch = db.batch();
  memberDocs.docs.forEach((doc) => batch.delete(doc.ref));

  if (user.role === 'manager') {
    const stores = await db.collection('stores').where('managerId', '==', uid).get();
    for (const store of stores.docs) {
      const members = await db.collection('storeMembers').doc(store.id).collection('members').get();
      members.docs.forEach((m) => batch.delete(m.ref));
      batch.delete(db.collection('storeMembers').doc(store.id));
      batch.delete(store.ref);
    }
  }

  batch.delete(db.collection('users').doc(uid));
  await batch.commit();
  await admin.auth().deleteUser(uid);

  return { ok: true };
});
