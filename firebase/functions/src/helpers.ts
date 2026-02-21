import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import { HttpsError } from 'firebase-functions/v2/https';

export function normalizeCode(code: unknown): string {
  return String(code ?? '').trim().toUpperCase();
}

export function sha256(value: string): string {
  return crypto.createHash('sha256').update(value).digest('hex');
}

export function generateJoinCode(length = 8): string {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  const bytes = crypto.randomBytes(length);
  let code = '';
  for (let i = 0; i < length; i += 1) {
    code += alphabet[bytes[i] % alphabet.length];
  }
  return code;
}

export async function verifyBearerToken(req: { headers: Record<string, unknown> }): Promise<admin.auth.DecodedIdToken> {
  const authHeader = String(req.headers.authorization ?? '');
  if (!authHeader.startsWith('Bearer ')) {
    throw new HttpsError('unauthenticated', 'Unauthorized');
  }

  const token = authHeader.slice('Bearer '.length).trim();
  if (!token) {
    throw new HttpsError('unauthenticated', 'Unauthorized');
  }

  try {
    return await admin.auth().verifyIdToken(token);
  } catch {
    throw new HttpsError('unauthenticated', 'Unauthorized');
  }
}

export function extractDataPayload(body: unknown): Record<string, unknown> {
  if (!body || typeof body !== 'object') return {};
  const obj = body as Record<string, unknown>;
  const nested = obj.data;
  if (nested && typeof nested === 'object') {
    return nested as Record<string, unknown>;
  }
  return obj;
}

export function toErrorResponse(error: unknown): { status: number; body: Record<string, unknown> } {
  if (error instanceof HttpsError) {
    if (error.code === 'unauthenticated') {
      return { status: 401, body: { error: { message: 'Unauthorized' } } };
    }

    const statusMap: Record<string, number> = {
      'invalid-argument': 400,
      'permission-denied': 403,
      'not-found': 404,
      'failed-precondition': 412,
    };
    const status = statusMap[error.code] ?? 500;
    return { status, body: { error: { message: error.message } } };
  }

  console.error('[functions] Unexpected error', error);
  return { status: 500, body: { error: { message: 'Internal server error' } } };
}

export async function requireActiveManager(db: admin.firestore.Firestore, uid: string): Promise<void> {
  const [managerSnap, userSnap] = await Promise.all([
    db.collection('managers').doc(uid).get(),
    db.collection('users').doc(uid).get(),
  ]);

  const managerActive = managerSnap.exists && managerSnap.data()?.isActive === true;
  const userData = userSnap.data();
  const userManagerActive =
    userSnap.exists &&
    userData?.role === 'manager' &&
    userData?.isActive === true;

  if (!managerActive && !userManagerActive) {
    throw new HttpsError('permission-denied', 'Manager access required');
  }
}
