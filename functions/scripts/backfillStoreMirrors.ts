import * as admin from 'firebase-admin';

admin.initializeApp();
const db = admin.firestore();

async function backfill(): Promise<void> {
  const storesSnap = await db.collection('stores').get();
  console.log(`[MIGRATE] stores=${storesSnap.size}`);

  for (const storeDoc of storesSnap.docs) {
    const storeId = storeDoc.id;
    const store = storeDoc.data();
    const managerId = typeof store.managerId === 'string' ? store.managerId : null;

    if (managerId) {
      await db.collection('managerStores').doc(managerId).collection('stores').doc(storeId).set({
        ...store,
        storeId,
        id: storeId,
      }, { merge: true });
    }

    const membersSnap = await db.collection('stores').doc(storeId).collection('members').get();
    for (const memberDoc of membersSnap.docs) {
      const member = memberDoc.data();
      const employeeId = typeof member.userId === 'string' ? member.userId : memberDoc.id;
      await db.collection('employeeStores').doc(employeeId).collection('stores').doc(storeId).set({
        storeId,
        employeeId,
        managerId,
        name: typeof store.name === 'string' ? store.name : 'Store',
        address: typeof store.address === 'string' ? store.address : '',
        latitude: typeof store.latitude === 'number' ? store.latitude : null,
        longitude: typeof store.longitude === 'number' ? store.longitude : null,
        radiusMeters: typeof store.radiusMeters === 'number' ? store.radiusMeters : 150,
        isActive: store.isActive === true,
        joinedAt: member.joinedAt ?? admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    console.log(`[MIGRATE] mirrored store=${storeId} manager=${managerId ?? 'none'} members=${membersSnap.size}`);
  }
}

backfill()
  .then(() => {
    console.log('[MIGRATE] done');
    process.exit(0);
  })
  .catch((error) => {
    console.error('[MIGRATE] failed', error);
    process.exit(1);
  });
