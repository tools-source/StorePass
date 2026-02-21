import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import { HttpsError } from 'firebase-functions/v2/https';

const HTTPS_STATUS_BY_ERROR_CODE: Record<string, number> = {
  'invalid-argument': 400,
  unauthenticated: 401,
  'permission-denied': 403,
  'not-found': 404,
  'failed-precondition': 412,
};

export function normalizeCode(code: unknown): string {
  return String(code ?? '').trim().toUpperCase();
}

export function sha256(value: string): string {
  return crypto.createHash('sha256').update(value).digest('hex');
}

export function generateJoinCode(length = 8): string {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  const randomBytes = crypto.randomBytes(length);
  let code = '';

  for (let i = 0; i < length; i += 1) {
    code += alphabet[randomBytes[i] % alphabet.length];
  }

  return code;
}

export function extractDataPayload(body: unknown): Record<string, unknown> {
  if (!body || typeof body !== 'object') {
    throw new HttpsError('invalid-argument', 'Body must be JSON object with a data field');
  }

  const parsedBody = body as Record<string, unknown>;
  if (!('data' in parsedBody) || !parsedBody.data || typeof parsedBody.data !== 'object') {
    throw new HttpsError('invalid-argument', 'Body must contain data object');
  }

  return parsedBody.data as Record<string, unknown>;
}

export async function verifyBearerToken(req: { headers: Record<string, unknown> }): Promise<admin.auth.DecodedIdToken> {
  const authHeader = String(req.headers.authorization ?? '');
  if (!authHeader.startsWith('Bearer ')) {
    throw new HttpsError('unauthenticated', 'Unauthorized');
  }

  const idToken = authHeader.slice('Bearer '.length).trim();
  if (!idToken) {
    throw new HttpsError('unauthenticated', 'Unauthorized');
  }

  try {
    return await admin.auth().verifyIdToken(idToken);
  } catch {
    throw new HttpsError('unauthenticated', 'Unauthorized');
  }
}

export function toErrorResponse(error: unknown): { status: number; body: { error: { message: string } } } {
  if (error instanceof HttpsError) {
    const status = HTTPS_STATUS_BY_ERROR_CODE[error.code] ?? 500;
    return { status, body: { error: { message: error.message } } };
  }

  console.error('[functions] Unexpected error', error);
  return {
    status: 500,
    body: { error: { message: 'Internal server error' } },
  };
}

export async function requireActiveManager(db: admin.firestore.Firestore, uid: string): Promise<void> {
  const [managerSnap, userSnap] = await Promise.all([
    db.collection('managers').doc(uid).get(),
    db.collection('users').doc(uid).get(),
  ]);

  const managerActive = managerSnap.exists && managerSnap.data()?.isActive === true;
  const userData = userSnap.data();
  const activeManagerUser = userSnap.exists && userData?.role === 'manager' && userData?.isActive === true;

  if (!managerActive && !activeManagerUser) {
    throw new HttpsError('permission-denied', 'Manager access required');
  }
}
