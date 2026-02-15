const { onCall, HttpsError } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const crypto = require('crypto');

admin.initializeApp();

function haversineMeters(lat1, lon1, lat2, lon2) {
  const toRad = (v) => (v * Math.PI) / 180;
  const R = 6371000;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

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

exports.validateCheckIn = onCall(async (request) => {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Must be signed in');

  const { employeeId, storeId, clientLat, clientLng, timestamp, accuracyMeters } = request.data;
  if (employeeId !== request.auth.uid) {
    throw new HttpsError('permission-denied', 'employeeId mismatch');
  }

  const db = admin.firestore();
  const [userSnap, storeSnap] = await Promise.all([
    db.collection('users').doc(employeeId).get(),
    db.collection('stores').doc(storeId).get(),
  ]);

  if (!userSnap.exists || !storeSnap.exists) {
    throw new HttpsError('not-found', 'User/store missing');
  }

  const user = userSnap.data();
  const store = storeSnap.data();
  const distance = haversineMeters(clientLat, clientLng, store.lat, store.lng);
  const approved = distance <= store.radiusMeters && accuracyMeters <= 50;

  const payload = {
    employeeId,
    employeeName: user.name,
    storeId,
    storeName: store.name,
    checkInTime: admin.firestore.FieldValue.serverTimestamp(),
    clientLat,
    clientLng,
    serverValidated: true,
    distanceMeters: distance,
    accuracyMeters,
    status: approved ? 'approved' : 'rejected',
    rejectReason: approved ? null : 'Out of range or poor accuracy',
    createdFromTimestamp: timestamp,
  };

  await db.collection('checkins').add(payload);
  return { approved, distanceMeters: distance };
});

exports.createEmployeeUnderManager = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Must be signed in');
  }

  const managerId = request.auth.uid;
  const { name, email, tempPassword, storeIds } = request.data;

  if (!name || !email || !tempPassword) {
    throw new HttpsError('invalid-argument', 'name, email and tempPassword are required.');
  }

  const db = admin.firestore();
  const managerSnap = await db.collection('users').doc(managerId).get();

  if (!managerSnap.exists) {
    throw new HttpsError('permission-denied', 'Manager profile does not exist.');
  }

  const manager = managerSnap.data();
  if (manager.role !== 'manager' || manager.isActive !== true) {
    throw new HttpsError('permission-denied', 'Only active managers can create employees.');
  }

  let employeeAuth;
  try {
    employeeAuth = await admin.auth().createUser({
      email,
      password: tempPassword,
      displayName: name,
      disabled: false,
    });
  } catch (error) {
    throw new HttpsError('already-exists', error.message || 'Unable to create employee user.');
  }

  const employeeId = employeeAuth.uid;
  const now = admin.firestore.FieldValue.serverTimestamp();
  const normalizedStores = Array.isArray(storeIds) ? storeIds.filter((v) => typeof v === 'string' && v.trim().length > 0) : [];

  const batch = db.batch();
  const userRef = db.collection('users').doc(employeeId);
  const linkRef = db.collection('managers').doc(managerId).collection('employees').doc(employeeId);

  batch.set(userRef, {
    name,
    email,
    role: 'employee',
    assignedStoreIds: normalizedStores,
    isActive: true,
    provider: 'password',
    createdByManagerId: managerId,
    createdAt: now,
    lastLoginAt: now,
  }, { merge: true });

  batch.set(linkRef, {
    employeeUserId: employeeId,
    stores: normalizedStores,
    isActive: true,
    createdAt: now,
  }, { merge: true });

  await batch.commit();

  return { employeeId };
});

exports.joinStoreByCode = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'You must be signed in.');
  }

  const code = normalizeCode(request.data.code);
  if (!code) {
    throw new HttpsError('invalid-argument', 'Please enter a join code.');
  }

  const db = admin.firestore();
  const userRef = db.collection('users').doc(request.auth.uid);
  const userSnap = await userRef.get();

  if (!userSnap.exists) {
    throw new HttpsError('permission-denied', 'User profile not found.');
  }

  const user = userSnap.data();
  if (user.role !== 'employee') {
    throw new HttpsError('permission-denied', 'Only employees can join by code.');
  }
  if (user.isActive !== true) {
    throw new HttpsError('permission-denied', 'Your account is inactive.');
  }

  const codeHash = hashCode(code);
  const storeQuery = await db.collection('stores')
    .where('joinCodeHash', '==', codeHash)
    .limit(1)
    .get();

  if (storeQuery.empty) {
    throw new HttpsError('not-found', 'Invalid join code.');
  }

  const storeDoc = storeQuery.docs[0];
  const store = storeDoc.data();
  if (store.isActive !== true) {
    throw new HttpsError('failed-precondition', 'This store is inactive.');
  }

  const storeId = storeDoc.id;
  const storeName = store.name || 'Store';
  const memberRef = db.collection('storeMembers').doc(storeId).collection('members').doc(request.auth.uid);
  const alreadyJoined = Array.isArray(user.assignedStoreIds) && user.assignedStoreIds.includes(storeId);

  await db.runTransaction(async (tx) => {
    const memberSnap = await tx.get(memberRef);
    if (!memberSnap.exists) {
      tx.set(memberRef, {
        userId: request.auth.uid,
        role: 'employee',
        joinedAt: admin.firestore.FieldValue.serverTimestamp(),
        isActive: true,
      }, { merge: true });
    }

    tx.set(userRef, {
      assignedStoreIds: admin.firestore.FieldValue.arrayUnion(storeId),
      lastLoginAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  });

  return { storeId, storeName, alreadyJoined };
});

exports.rotateJoinCode = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'You must be signed in.');
  }

  const storeId = request.data.storeId;
  if (!storeId || typeof storeId !== 'string') {
    throw new HttpsError('invalid-argument', 'storeId is required.');
  }

  const db = admin.firestore();
  const [managerSnap, storeSnap] = await Promise.all([
    db.collection('users').doc(request.auth.uid).get(),
    db.collection('stores').doc(storeId).get(),
  ]);

  if (!managerSnap.exists) {
    throw new HttpsError('permission-denied', 'Manager profile does not exist.');
  }

  const manager = managerSnap.data();
  if (manager.role !== 'manager' || manager.isActive !== true) {
    throw new HttpsError('permission-denied', 'Only active managers can rotate store codes.');
  }

  if (!storeSnap.exists) {
    throw new HttpsError('not-found', 'Store not found.');
  }

  const store = storeSnap.data();
  if (store.managerId !== request.auth.uid) {
    throw new HttpsError('permission-denied', 'You can only rotate codes for your stores.');
  }

  const newCode = generateJoinCode();
  const normalized = normalizeCode(newCode);

  await storeSnap.ref.set({
    joinCodeHash: hashCode(normalized),
    joinCodeLast4: newCode.slice(-4),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  return { storeId, joinCode: newCode, joinCodeLast4: newCode.slice(-4) };
});
