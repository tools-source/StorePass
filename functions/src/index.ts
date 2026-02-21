import { HttpsError, onRequest } from 'firebase-functions/v2/https';
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

export const joinStoreByCode = onRequest({ region: 'us-central1' }, async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: { message: 'Method not allowed' } });
    return;
  }

  try {
    const decodedToken = await verifyBearerToken(req as { headers: Record<string, unknown> });
    const data = extractDataPayload(req.body);
    const code = normalizeCode(data.code);

    if (!code) {
      throw new HttpsError('invalid-argument', 'code is required');
    }

    let storeDoc = (await db.collection('stores').where('joinCode', '==', code).limit(1).get()).docs[0];
    if (!storeDoc) {
      const hashedCode = sha256(code);
      storeDoc = (await db.collection('stores').where('joinCodeHash', '==', hashedCode).limit(1).get()).docs[0];
    }

    if (!storeDoc) {
      throw new HttpsError('not-found', 'Invalid join code');
    }

    const store = storeDoc.data();
    const storeId = storeDoc.id;
    const memberRef = db.collection('storeMembers').doc(storeId).collection('members').doc(decodedToken.uid);
    const existingMember = await memberRef.get();

    await memberRef.set(
      {
        memberId: decodedToken.uid,
        storeId,
        storeName: String(store.name ?? 'Store'),
        joinedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    res.status(200).json({
      result: {
        storeId,
        storeName: String(store.name ?? 'Store'),
        alreadyJoined: existingMember.exists,
      },
    });
  } catch (error) {
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
    await requireActiveManager(db, decodedToken.uid);

    const data = extractDataPayload(req.body);
    const storeId = String(data.storeId ?? '');
    if (!storeId) {
      throw new HttpsError('invalid-argument', 'storeId is required');
    }

    const storeRef = db.collection('stores').doc(storeId);
    const storeSnap = await storeRef.get();
    if (!storeSnap.exists) {
      throw new HttpsError('not-found', 'Store not found');
    }

    const joinCode = generateJoinCode(8);
    await storeRef.set(
      {
        joinCode,
        joinCodeHash: sha256(joinCode),
        joinCodeLast4: joinCode.slice(-4),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    res.status(200).json({ result: { joinCode } });
  } catch (error) {
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
    await requireActiveManager(db, decodedToken.uid);

    const data = extractDataPayload(req.body);
    const storeId = String(data.storeId ?? '');
    if (!storeId) {
      throw new HttpsError('invalid-argument', 'storeId is required');
    }

    const storeSnap = await db.collection('stores').doc(storeId).get();
    if (!storeSnap.exists) {
      throw new HttpsError('not-found', 'Store not found');
    }

    const store = storeSnap.data() ?? {};
    const joinCode = typeof store.joinCode === 'string' ? store.joinCode : '';

    if (!joinCode) {
      throw new HttpsError('failed-precondition', 'joinCode not stored; only last4 available');
    }

    res.status(200).json({ result: { joinCode } });
  } catch (error) {
    const err = toErrorResponse(error);
    res.status(err.status).json(err.body);
  }
});
