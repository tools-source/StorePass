"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.getStoreJoinCode = exports.rotateStoreCode = exports.joinStoreByCode = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = __importStar(require("firebase-admin"));
const helpers_1 = require("./helpers");
admin.initializeApp();
const db = admin.firestore();
function maskCode(code) {
    if (!code) {
        return '';
    }
    const last4 = code.slice(-4);
    return `${'*'.repeat(Math.max(0, code.length - 4))}${last4}`;
}
exports.joinStoreByCode = (0, https_1.onRequest)({ region: 'us-central1' }, async (req, res) => {
    if (req.method !== 'POST') {
        res.status(405).json({ error: { message: 'Method not allowed' } });
        return;
    }
    try {
        const decodedToken = await (0, helpers_1.verifyBearerToken)(req);
        const uid = decodedToken.uid;
        console.log(`[JOIN] auth uid=${uid}`);
        const userSnap = await db.collection('users').doc(uid).get();
        const userData = userSnap.data();
        const role = typeof userData?.role === 'string' ? userData.role : null;
        const isActive = userData?.isActive === true;
        console.log(`[JOIN] role lookup uid=${uid} userDocExists=${userSnap.exists} role=${role ?? 'null'} isActive=${isActive}`);
        const data = (0, helpers_1.extractDataPayload)(req.body);
        const code = (0, helpers_1.normalizeCode)(data.code);
        const joinCodeLast4 = code.slice(-4);
        console.log(`[JOIN] code received masked=${maskCode(code)} joinCodeLast4=${joinCodeLast4}`);
        if (!code) {
            throw new https_1.HttpsError('invalid-argument', 'code is required');
        }
        const plainCodeQuery = await db.collection('stores').where('joinCode', '==', code).limit(1).get();
        let storeDoc = plainCodeQuery.docs[0];
        let hashMatched = false;
        if (!storeDoc) {
            const hashedCode = (0, helpers_1.sha256)(code);
            const hashQuery = await db.collection('stores').where('joinCodeHash', '==', hashedCode).limit(1).get();
            hashMatched = hashQuery.docs.length > 0;
            storeDoc = hashQuery.docs[0];
        }
        console.log(`[JOIN] hash comparison result hashMatched=${hashMatched}`);
        if (!storeDoc) {
            throw new https_1.HttpsError('not-found', 'Invalid join code');
        }
        const store = storeDoc.data();
        const storeId = storeDoc.id;
        console.log(`[JOIN] resolved uid=${uid} storeId=${storeId} joinCodeLast4=${joinCodeLast4}`);
        const memberPath = `stores/${storeId}/members/${uid}`;
        const userPath = `users/${uid}`;
        const memberRef = db.doc(memberPath);
        const userRef = db.doc(userPath);
        console.log(`[JOIN] firestore write paths membershipDocPath=${memberPath} userDocPath=${userPath}`);
        const existingMember = await memberRef.get();
        const existingUser = await userRef.get();
        const beforeAssignedStoreIds = existingUser.data()?.assignedStoreIds ?? [];
        const beforeContains = beforeAssignedStoreIds.includes(storeId);
        console.log(`[JOIN] before uid=${uid} storeId=${storeId} assignedStoreIdsLength=${beforeAssignedStoreIds.length} containsStore=${beforeContains}`);
        try {
            await db.runTransaction(async (transaction) => {
                const userBefore = await transaction.get(userRef);
                transaction.set(memberRef, {
                    userId: uid,
                    employeeId: uid,
                    storeId,
                    role: 'employee',
                    joinedAt: admin.firestore.FieldValue.serverTimestamp(),
                    isActive: true,
                    storeName: String(store.name ?? 'Store'),
                }, { merge: true });
                if (!userBefore.exists) {
                    transaction.set(userRef, {
                        role: 'employee',
                        isActive: true,
                        assignedStoreIds: [storeId],
                        createdAt: admin.firestore.FieldValue.serverTimestamp(),
                        lastLoginAt: admin.firestore.FieldValue.serverTimestamp(),
                        lastJoinAt: admin.firestore.FieldValue.serverTimestamp(),
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    }, { merge: true });
                    return;
                }
                transaction.set(userRef, {
                    role: 'employee',
                    isActive: true,
                    assignedStoreIds: admin.firestore.FieldValue.arrayUnion(storeId),
                    lastLoginAt: admin.firestore.FieldValue.serverTimestamp(),
                    lastJoinAt: admin.firestore.FieldValue.serverTimestamp(),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                }, { merge: true });
            });
            console.log(`[JOIN] atomic commit success uid=${uid} storeId=${storeId}`);
        }
        catch (error) {
            console.error(`[JOIN] atomic commit failure uid=${uid} storeId=${storeId}`, error);
            throw new https_1.HttpsError('internal', 'Join failed: atomic membership + user profile update failed');
        }
        const [memberAfter, userAfter] = await Promise.all([memberRef.get(), userRef.get()]);
        const assignedStoreIdsAfter = userAfter.data()?.assignedStoreIds ?? [];
        const assignedStoreIdsContainsStoreId = assignedStoreIdsAfter.includes(storeId);
        const membershipExists = memberAfter.exists;
        console.log(`[JOIN] after uid=${uid} storeId=${storeId} assignedStoreIdsLength=${assignedStoreIdsAfter.length} containsStore=${assignedStoreIdsContainsStoreId} membershipExists=${membershipExists}`);
        if (membershipExists && !assignedStoreIdsContainsStoreId) {
            throw new https_1.HttpsError('internal', 'Join membership write succeeded but user profile assignedStoreIds update failed');
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
    }
    catch (error) {
        const errorWithStack = error;
        console.error('[JOIN] request failed', error);
        if (errorWithStack?.stack) {
            console.error('[JOIN] request failed stack', errorWithStack.stack);
        }
        const err = (0, helpers_1.toErrorResponse)(error);
        res.status(err.status).json(err.body);
    }
});
exports.rotateStoreCode = (0, https_1.onRequest)({ region: 'us-central1' }, async (req, res) => {
    if (req.method !== 'POST') {
        res.status(405).json({ error: { message: 'Method not allowed' } });
        return;
    }
    try {
        const decodedToken = await (0, helpers_1.verifyBearerToken)(req);
        const uid = decodedToken.uid;
        console.log(`[ROTATE] auth uid=${uid}`);
        const managerLookup = await (0, helpers_1.requireActiveManager)(db, uid);
        console.log(`[ROTATE] role lookup uid=${uid} managerDocExists=${managerLookup.managerDocExists} managerDocActive=${managerLookup.managerDocActive} userDocExists=${managerLookup.userDocExists} role=${managerLookup.userRole ?? 'null'} isActive=${managerLookup.userIsActive}`);
        const data = (0, helpers_1.extractDataPayload)(req.body);
        const storeId = String(data.storeId ?? '');
        console.log(`[ROTATE] resolved storeId=${storeId || '<missing>'}`);
        if (!storeId) {
            throw new https_1.HttpsError('invalid-argument', 'storeId is required');
        }
        const storeRef = db.collection('stores').doc(storeId);
        const storeSnap = await storeRef.get();
        if (!storeSnap.exists) {
            throw new https_1.HttpsError('not-found', 'Store not found');
        }
        const joinCode = (0, helpers_1.generateJoinCode)(8);
        const writePath = `stores/${storeId}`;
        console.log(`[ROTATE] firestore write attempt path=${writePath}`);
        try {
            await storeRef.set({
                joinCode,
                joinCodeHash: (0, helpers_1.sha256)(joinCode),
                joinCodeLast4: joinCode.slice(-4),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            console.log(`[ROTATE] firestore write success path=${writePath}`);
        }
        catch (error) {
            console.error(`[ROTATE] firestore write failure path=${writePath}`, error);
            throw new https_1.HttpsError('internal', `Rotate failed: write to ${writePath} failed`);
        }
        const payload = { result: { joinCode } };
        console.log(`[ROTATE] final response payload=${JSON.stringify(payload)}`);
        res.status(200).json(payload);
    }
    catch (error) {
        console.error('[ROTATE] request failed', error);
        const err = (0, helpers_1.toErrorResponse)(error);
        res.status(err.status).json(err.body);
    }
});
exports.getStoreJoinCode = (0, https_1.onRequest)({ region: 'us-central1' }, async (req, res) => {
    if (req.method !== 'POST') {
        res.status(405).json({ error: { message: 'Method not allowed' } });
        return;
    }
    try {
        const decodedToken = await (0, helpers_1.verifyBearerToken)(req);
        const uid = decodedToken.uid;
        console.log(`[CODE] auth uid=${uid}`);
        const managerLookup = await (0, helpers_1.requireActiveManager)(db, uid);
        console.log(`[CODE] role lookup uid=${uid} managerDocExists=${managerLookup.managerDocExists} managerDocActive=${managerLookup.managerDocActive} userDocExists=${managerLookup.userDocExists} role=${managerLookup.userRole ?? 'null'} isActive=${managerLookup.userIsActive}`);
        const data = (0, helpers_1.extractDataPayload)(req.body);
        const storeId = String(data.storeId ?? '');
        console.log(`[CODE] resolved storeId=${storeId || '<missing>'}`);
        if (!storeId) {
            throw new https_1.HttpsError('invalid-argument', 'storeId is required');
        }
        const storeSnap = await db.collection('stores').doc(storeId).get();
        if (!storeSnap.exists) {
            throw new https_1.HttpsError('not-found', 'Store not found');
        }
        const store = storeSnap.data() ?? {};
        const joinCode = typeof store.joinCode === 'string' ? store.joinCode : '';
        if (!joinCode) {
            throw new https_1.HttpsError('failed-precondition', 'joinCode not stored; only last4 available');
        }
        console.log(`[CODE] code loaded masked=${maskCode(joinCode)}`);
        const payload = { result: { joinCode } };
        console.log(`[CODE] final response payload=${JSON.stringify(payload)}`);
        res.status(200).json(payload);
    }
    catch (error) {
        console.error('[CODE] request failed', error);
        const err = (0, helpers_1.toErrorResponse)(error);
        res.status(err.status).json(err.body);
    }
});
