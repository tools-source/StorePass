const { onCall, HttpsError } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');

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
