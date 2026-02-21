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
    const role = typeof userData?.role === 'string' ? userData.role : null;
    const isActive = userData?.isActive === true;
    console.log(`[JOIN] role lookup uid=${uid} userDocExists=${userSnap.exists} role=${role ?? 'null'} isActive=${isActive}`);

    const data = extractDataPayload(req.body);
    const code = normalizeCode(data.code);
    console.log(`[JOIN] code received masked=${maskCode(code)}`);

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
    console.log(`[JOIN] resolved storeId=${storeId}`);

    const memberPath = `storeMembers/${storeId}/members/${uid}`;
    const userPath = `users/${uid}`;
    const memberRef = db.doc(memberPath);
    const userRef = db.doc(userPath);
    const existingMember = await memberRef.get();

    console.log(`[JOIN] firestore write attempt path=${memberPath}`);
    try {
      await memberRef.set(
        {
          employeeId: uid,
          storeId,
          joinedAt: admin.firestore.FieldValue.serverTimestamp(),
          storeName: String(store.name ?? 'Store'),
        },
        { merge: true },
      );
      console.log(`[JOIN] firestore write success path=${memberPath}`);
    } catch (error) {
      console.error(`[JOIN] firestore write failure path=${memberPath}`, error);
      throw new HttpsError('internal', `Join failed: write to ${memberPath} failed`);
    }

    console.log(`[JOIN] firestore write attempt path=${userPath}`);
    try {
      await userRef.set(
        {
          assignedStoreIds: admin.firestore.FieldValue.arrayUnion(storeId),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      console.log(`[JOIN] firestore write success path=${userPath}`);
    } catch (error) {
      console.error(`[JOIN] firestore write failure path=${userPath}`, error);
      throw new HttpsError('internal', `Join failed: write to ${userPath} failed`);
    }

    const payload = {
      result: {
        storeId,
        storeName: String(store.name ?? 'Store'),
        alreadyJoined: existingMember.exists,
      },
    };

    console.log(`[JOIN] final response payload=${JSON.stringify(payload)}`);
    res.status(200).json(payload);
  } catch (error) {
    console.error('[JOIN] request failed', error);
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
