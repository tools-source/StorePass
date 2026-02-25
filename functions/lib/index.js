"use strict";
// What changed:
// - Added employee deleteMyAccount cleanup endpoint to unlink memberships/mirrors before auth deletion.
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
exports.notifyManagerOnCheckoutUpdate = exports.notifyManagerOnCheckinCreate = exports.deleteManagerAccount = exports.deleteMyAccount = exports.removeEmployeeFromStore = exports.leaveStore = exports.setUserRole = exports.getStoreJoinCode = exports.rotateStoreCode = exports.joinStoreByCode = void 0;
const https_1 = require("firebase-functions/v2/https");
const firestore_1 = require("firebase-functions/v2/firestore");
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
        const profileName = (typeof userData?.displayName === 'string' && userData.displayName.trim().length > 0
            ? userData.displayName.trim()
            : null) ??
            (typeof userData?.name === 'string' && userData.name.trim().length > 0 ? userData.name.trim() : null) ??
            (typeof decodedToken.name === 'string' && decodedToken.name.trim().length > 0 ? decodedToken.name.trim() : null) ??
            `Employee ${uid.slice(0, 6)}`;
        const profileEmail = (typeof userData?.email === 'string' && userData.email.trim().length > 0 ? userData.email.trim() : null) ??
            (typeof decodedToken.email === 'string' && decodedToken.email.trim().length > 0 ? decodedToken.email.trim() : null) ??
            '';
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
        const employeeStorePath = `employeeStores/${uid}/stores/${storeId}`;
        const memberRef = db.doc(memberPath);
        const userRef = db.doc(userPath);
        const employeeStoreRef = db.doc(employeeStorePath);
        console.log(`[JOIN] firestore write paths membershipDocPath=${memberPath} userDocPath=${userPath} employeeStoreDocPath=${employeeStorePath}`);
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
                    employeeName: profileName,
                    employeeEmail: profileEmail,
                }, { merge: true });
                transaction.set(employeeStoreRef, {
                    storeId,
                    employeeId: uid,
                    managerId: typeof store.managerId === 'string' ? store.managerId : null,
                    name: String(store.name ?? 'Store'),
                    address: String(store.address ?? ''),
                    latitude: typeof store.latitude === 'number' ? store.latitude : null,
                    longitude: typeof store.longitude === 'number' ? store.longitude : null,
                    radiusMeters: typeof store.radiusMeters === 'number' ? store.radiusMeters : 150,
                    isActive: store.isActive === true,
                    joinedAt: admin.firestore.FieldValue.serverTimestamp(),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
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
        const storeData = storeSnap.data() ?? {};
        if (storeData.managerId !== uid) {
            throw new https_1.HttpsError('permission-denied', 'You can only rotate code for your own store');
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
        if (store.managerId !== uid) {
            throw new https_1.HttpsError('permission-denied', 'You can only access code for your own store');
        }
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
exports.setUserRole = (0, https_1.onRequest)({ region: 'us-central1' }, async (req, res) => {
    if (req.method !== 'POST') {
        res.status(405).json({ error: { message: 'Method not allowed' } });
        return;
    }
    try {
        const decodedToken = await (0, helpers_1.verifyBearerToken)(req);
        const uid = decodedToken.uid;
        const data = (0, helpers_1.extractDataPayload)(req.body);
        const requestedRoleRaw = String(data.requestedRole ?? '').toLowerCase();
        const requestedRole = requestedRoleRaw === 'manager' ? 'manager' : requestedRoleRaw === 'employee' ? 'employee' : null;
        const name = String(data.name ?? 'StorePass User');
        const email = typeof data.email === 'string' ? data.email : null;
        const provider = String(data.provider ?? 'unknown');
        if (!requestedRole) {
            throw new https_1.HttpsError('invalid-argument', 'requestedRole must be manager or employee');
        }
        const userRef = db.collection('users').doc(uid);
        const result = await db.runTransaction(async (transaction) => {
            const userSnap = await transaction.get(userRef);
            const existingRole = typeof userSnap.data()?.role === 'string' ? String(userSnap.data()?.role).toLowerCase() : null;
            if (existingRole === 'manager' || existingRole === 'employee') {
                return { created: false, role: existingRole, changed: false };
            }
            if (!userSnap.exists) {
                transaction.set(userRef, {
                    name,
                    email,
                    role: requestedRole,
                    isActive: true,
                    provider,
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                    lastLoginAt: admin.firestore.FieldValue.serverTimestamp(),
                    assignedStoreIds: [],
                }, { merge: true });
                return { created: true, role: requestedRole, changed: true };
            }
            transaction.set(userRef, {
                name,
                email,
                provider,
                role: requestedRole,
                isActive: true,
                lastLoginAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            return { created: false, role: requestedRole, changed: true };
        });
        console.log(`[SET_ROLE] uid=${uid} requestedRole=${requestedRole} created=${result.created} changed=${result.changed} role=${result.role}`);
        res.status(200).json({ result });
    }
    catch (error) {
        console.error('[SET_ROLE] request failed', error);
        const err = (0, helpers_1.toErrorResponse)(error);
        res.status(err.status).json(err.body);
    }
});
exports.leaveStore = (0, https_1.onCall)({ region: 'us-central1' }, async (request) => {
    const uid = request.auth?.uid;
    const storeId = String(request.data?.storeId ?? '');
    if (!uid) {
        throw new https_1.HttpsError('permission-denied', 'Authentication required');
    }
    if (!storeId) {
        throw new https_1.HttpsError('failed-precondition', 'storeId is required');
    }
    try {
        console.log(`[LEAVE_STORE][START] uid=${uid} storeId=${storeId}`);
        const storeRef = db.collection('stores').doc(storeId);
        const memberRef = storeRef.collection('members').doc(uid);
        const employeeStoreRef = db.collection('employeeStores').doc(uid).collection('stores').doc(storeId);
        const userRef = db.collection('users').doc(uid);
        const [storeSnap, memberSnap, employeeStoreSnap, userSnap] = await Promise.all([
            storeRef.get(),
            memberRef.get(),
            employeeStoreRef.get(),
            userRef.get(),
        ]);
        if (!storeSnap.exists) {
            console.log(`[LEAVE_STORE] storeMissing storeId=${storeId}`);
        }
        const assignedStoreIds = userSnap.data()?.assignedStoreIds ?? [];
        const beforeCount = assignedStoreIds.length;
        console.log(`[LEAVE_STORE] memberExists=${memberSnap.exists} employeeStoreExists=${employeeStoreSnap.exists} assignedBeforeCount=${beforeCount}`);
        const batch = db.batch();
        if (memberSnap.exists) {
            batch.delete(memberRef);
        }
        if (employeeStoreSnap.exists) {
            batch.delete(employeeStoreRef);
        }
        batch.set(userRef, {
            assignedStoreIds: admin.firestore.FieldValue.arrayRemove(storeId),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        await batch.commit();
        console.log(`[LEAVE_STORE][END] ok=true uid=${uid} storeId=${storeId} assignedAfterCount=${Math.max(0, beforeCount - (assignedStoreIds.includes(storeId) ? 1 : 0))}`);
        return { ok: true, storeId, uid };
    }
    catch (error) {
        console.error('[LEAVE_STORE] callable failed', error);
        if (error instanceof https_1.HttpsError) {
            throw error;
        }
        throw new https_1.HttpsError('internal', 'Failed to leave store');
    }
});
exports.removeEmployeeFromStore = (0, https_1.onCall)({ region: 'us-central1' }, async (request) => {
    const managerId = request.auth?.uid;
    const storeId = String(request.data?.storeId ?? '');
    const employeeId = String(request.data?.employeeId ?? '');
    if (!managerId) {
        throw new https_1.HttpsError('permission-denied', 'Authentication required');
    }
    if (!storeId || !employeeId) {
        throw new https_1.HttpsError('failed-precondition', 'storeId and employeeId are required');
    }
    try {
        console.log(`[REMOVE_EMPLOYEE_FROM_STORE][START] managerId=${managerId} storeId=${storeId} employeeId=${employeeId}`);
        const managerLookup = await (0, helpers_1.requireActiveManager)(db, managerId);
        if (!managerLookup.managerDocActive || managerLookup.userRole !== 'manager' || managerLookup.userIsActive !== true) {
            throw new https_1.HttpsError('failed-precondition', 'This action can’t be completed right now.');
        }
        const storeRef = db.collection('stores').doc(storeId);
        const memberRef = storeRef.collection('members').doc(employeeId);
        const employeeStoreRef = db.collection('employeeStores').doc(employeeId).collection('stores').doc(storeId);
        const userRef = db.collection('users').doc(employeeId);
        const [storeSnap, memberSnap, employeeStoreSnap] = await Promise.all([storeRef.get(), memberRef.get(), employeeStoreRef.get()]);
        if (!storeSnap.exists) {
            throw new https_1.HttpsError('not-found', 'Store not found');
        }
        const storeData = storeSnap.data() ?? {};
        if (storeData.managerId !== managerId) {
            throw new https_1.HttpsError('permission-denied', 'You don’t have permission.');
        }
        const batch = db.batch();
        if (memberSnap.exists)
            batch.delete(memberRef);
        if (employeeStoreSnap.exists)
            batch.delete(employeeStoreRef);
        batch.set(userRef, { assignedStoreIds: admin.firestore.FieldValue.arrayRemove(storeId), updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
        await batch.commit();
        console.log(`[REMOVE_EMPLOYEE_FROM_STORE][END] ok=true managerId=${managerId} storeId=${storeId} employeeId=${employeeId} membershipDeleted=${memberSnap.exists} mirrorDeleted=${employeeStoreSnap.exists}`);
        return { ok: true, storeId, employeeId, managerId };
    }
    catch (error) {
        console.error('[REMOVE_EMPLOYEE_FROM_STORE] callable failed', error);
        if (error instanceof https_1.HttpsError)
            throw error;
        throw new https_1.HttpsError('internal', 'Failed to remove employee from store');
    }
});
function stepFailed(uid, mode, step, error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[AccountDelete] uid=${uid} mode=${mode} step=${step} failed message=${message}`);
    return new https_1.HttpsError('internal', 'step_failed', { ok: false, code: 'step_failed', step, message, uid, mode });
}
async function commitDeleteBatch(refs, context) {
    if (refs.length === 0)
        return 0;
    const chunkSize = 450;
    let deleted = 0;
    for (let i = 0; i < refs.length; i += chunkSize) {
        const chunk = refs.slice(i, i + chunkSize);
        const batch = db.batch();
        for (const ref of chunk)
            batch.delete(ref);
        console.log(`[${context.prefix}] stage=${context.stage} uid=${context.uid} chunk=${Math.floor(i / chunkSize)} size=${chunk.length}`);
        await batch.commit();
        deleted += chunk.length;
    }
    return deleted;
}
exports.deleteMyAccount = (0, https_1.onCall)({ region: 'us-central1' }, async (request) => {
    const uid = request.auth?.uid;
    const mode = typeof request.data?.mode === 'string' ? request.data.mode : 'cleanup_memberships';
    const role = typeof request.data?.role === 'string' ? request.data.role : 'employee';
    if (!uid)
        throw new https_1.HttpsError('unauthenticated', 'Must be signed in');
    console.log(`[deleteMyAccount] uid=${uid} role=${role} mode=${mode} stage=start`);
    const userRef = db.collection('users').doc(uid);
    try {
        const userSnap = await userRef.get();
        const userData = userSnap.data() ?? {};
        const assignedStoreIds = Array.isArray(userData.assignedStoreIds) ? userData.assignedStoreIds.filter((v) => typeof v === 'string') : [];
        const refs = new Map();
        const addRef = (ref) => refs.set(ref.path, ref);
        try {
            const employeeStoresSnap = await db.collection('employeeStores').doc(uid).collection('stores').get();
            employeeStoresSnap.docs.forEach((doc) => addRef(doc.ref));
            addRef(db.collection('employeeStores').doc(uid));
            console.log(`[deleteMyAccount] uid=${uid} stage=employeeStores count=${employeeStoresSnap.size}`);
        }
        catch (error) {
            throw stepFailed(uid, mode, 'employeeStores', error);
        }
        try {
            const employeeCheckinsSnap = await db.collection('employeeCheckins').doc(uid).collection('checkins').get();
            employeeCheckinsSnap.docs.forEach((doc) => addRef(doc.ref));
            addRef(db.collection('employeeCheckins').doc(uid));
            console.log(`[deleteMyAccount] uid=${uid} stage=employeeCheckins count=${employeeCheckinsSnap.size}`);
        }
        catch (error) {
            throw stepFailed(uid, mode, 'employeeCheckins', error);
        }
        try {
            const membershipsById = await db.collectionGroup('members').where('employeeId', '==', uid).get();
            const membershipsByDoc = await db.collectionGroup('members').where(admin.firestore.FieldPath.documentId(), '==', uid).get();
            for (const doc of [...membershipsById.docs, ...membershipsByDoc.docs])
                addRef(doc.ref);
            for (const storeId of assignedStoreIds)
                addRef(db.collection('stores').doc(storeId).collection('members').doc(uid));
            console.log(`[deleteMyAccount] uid=${uid} stage=memberships count=${membershipsById.size + membershipsByDoc.size}`);
        }
        catch (error) {
            throw stepFailed(uid, mode, 'memberships', error);
        }
        try {
            const managerCheckins = await db.collectionGroup('checkins').where('employeeId', '==', uid).get();
            managerCheckins.docs.filter((doc) => doc.ref.path.includes('/managerCheckins/')).forEach((doc) => addRef(doc.ref));
            console.log(`[deleteMyAccount] uid=${uid} stage=managerCheckinMirrors count=${managerCheckins.size}`);
        }
        catch (error) {
            throw stepFailed(uid, mode, 'managerCheckins', error);
        }
        addRef(db.collection('employees').doc(uid));
        addRef(db.collection('users').doc(uid));
        try {
            await commitDeleteBatch([...refs.values()], { prefix: 'deleteMyAccount', uid, stage: 'cleanupFirestore' });
        }
        catch (error) {
            throw stepFailed(uid, mode, 'cleanupFirestore', error);
        }
        console.log(`[deleteMyAccount] uid=${uid} role=${role} mode=${mode} stage=done`);
        return { ok: true };
    }
    catch (error) {
        if (error instanceof https_1.HttpsError)
            throw error;
        throw stepFailed(uid, mode, 'unknown', error);
    }
});
exports.deleteManagerAccount = (0, https_1.onCall)({ region: 'us-central1' }, async (request) => {
    const managerUid = request.auth?.uid;
    const mode = typeof request.data?.mode === 'string' ? request.data.mode : 'default';
    if (!managerUid)
        throw new https_1.HttpsError('unauthenticated', 'Authentication required');
    console.log(`[deleteManagerAccount] uid=${managerUid} mode=${mode} stage=start`);
    try {
        const userRef = db.collection('users').doc(managerUid);
        const userSnap = await userRef.get();
        const role = String(userSnap.data()?.role ?? '').toLowerCase();
        if (role && role !== 'manager') {
            throw new https_1.HttpsError('permission-denied', 'Only managers can call deleteManagerAccount.', { ok: false, code: 'step_failed', step: 'resolveRole', message: 'non_manager' });
        }
        const storesSnap = await db.collection('stores').where('managerId', '==', managerUid).get();
        const refs = [];
        for (const storeDoc of storesSnap.docs) {
            const storeId = storeDoc.id;
            const membersSnap = await storeDoc.ref.collection('members').get();
            for (const memberDoc of membersSnap.docs) {
                refs.push(memberDoc.ref);
                const memberData = memberDoc.data();
                const employeeUid = (typeof memberData.employeeId === 'string' ? memberData.employeeId : memberDoc.id);
                refs.push(db.collection('employeeStores').doc(employeeUid).collection('stores').doc(storeId));
                await db.collection('users').doc(employeeUid).set({ assignedStoreIds: admin.firestore.FieldValue.arrayRemove(storeId), updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
            }
            const managerCheckinsSnap = await db.collection('managerCheckins').doc(managerUid).collection('stores').doc(storeId).collection('checkins').get();
            managerCheckinsSnap.docs.forEach((doc) => refs.push(doc.ref));
            refs.push(db.collection('managerCheckins').doc(managerUid).collection('stores').doc(storeId));
            const rootCheckinsSnap = await db.collection('checkins').where('storeId', '==', storeId).get();
            for (const checkinDoc of rootCheckinsSnap.docs) {
                refs.push(checkinDoc.ref);
                const employeeId = checkinDoc.data().employeeId;
                if (typeof employeeId === 'string') {
                    refs.push(db.collection('employeeCheckins').doc(employeeId).collection('checkins').doc(checkinDoc.id));
                }
            }
            refs.push(db.collection('managerStores').doc(managerUid).collection('stores').doc(storeId));
            refs.push(storeDoc.ref);
        }
        refs.push(db.collection('managerStores').doc(managerUid));
        refs.push(db.collection('managerCheckins').doc(managerUid));
        refs.push(db.collection('managers').doc(managerUid));
        refs.push(db.collection('users').doc(managerUid));
        await commitDeleteBatch(refs, { prefix: 'deleteManagerAccount', uid: managerUid, stage: 'cleanupFirestore' });
        console.log(`[deleteManagerAccount] uid=${managerUid} mode=${mode} stage=done`);
        return { ok: true };
    }
    catch (error) {
        if (error instanceof https_1.HttpsError)
            throw error;
        throw stepFailed(managerUid, mode, 'cleanup', error);
    }
});
async function sendManagerPushForCheckin(data, checkinId, kind) {
    const storeId = typeof data.storeId === 'string' ? data.storeId : '';
    const employeeId = typeof data.employeeId === 'string' ? data.employeeId : '';
    if (!storeId || !employeeId)
        return;
    const storeSnap = await db.collection('stores').doc(storeId).get();
    const storeData = storeSnap.data() ?? {};
    const managerId = typeof storeData.managerId === 'string' ? storeData.managerId : '';
    if (!managerId)
        return;
    const tokensSnap = await db.collection('users').doc(managerId).collection('deviceTokens').where('appMode', '==', 'manager').get();
    const tokens = tokensSnap.docs.map((doc) => doc.id).filter(Boolean);
    if (tokens.length === 0)
        return;
    const employeeName = String(data.employeeName ?? 'Employee');
    const storeName = String(storeData.name ?? 'Store');
    const durationSeconds = typeof data.durationSeconds === 'number' ? String(data.durationSeconds) : '';
    const message = {
        tokens,
        notification: {
            title: kind === 'checkin' ? 'Employee Checked In' : 'Employee Checked Out',
            body: kind === 'checkin' ? `${employeeName} checked in at ${storeName}.` : `${employeeName} checked out at ${storeName}.`,
        },
        data: {
            eventType: kind,
            checkinId,
            employeeName,
            storeName,
            durationSeconds,
        },
    };
    await admin.messaging().sendEachForMulticast(message);
}
exports.notifyManagerOnCheckinCreate = (0, firestore_1.onDocumentCreated)({ region: 'us-central1', document: 'checkins/{checkinId}' }, async (event) => {
    const data = event.data?.data();
    if (!data)
        return;
    await sendManagerPushForCheckin(data, event.params.checkinId, 'checkin');
});
exports.notifyManagerOnCheckoutUpdate = (0, firestore_1.onDocumentUpdated)({ region: 'us-central1', document: 'checkins/{checkinId}' }, async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!after)
        return;
    const checkoutAdded = !before?.checkOutTime && !!after.checkOutTime;
    if (!checkoutAdded)
        return;
    // We intentionally map login/logout notifications to check-in/check-out to avoid risky auth-flow changes.
    await sendManagerPushForCheckin(after, event.params.checkinId, 'checkout');
});
