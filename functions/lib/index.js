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
exports.joinStoreByCode = (0, https_1.onRequest)({ region: 'us-central1' }, async (req, res) => {
    if (req.method !== 'POST') {
        res.status(405).json({ error: { message: 'Method not allowed' } });
        return;
    }
    try {
        const decodedToken = await (0, helpers_1.verifyBearerToken)(req);
        const data = (0, helpers_1.extractDataPayload)(req.body);
        const code = (0, helpers_1.normalizeCode)(data.code);
        if (!code) {
            throw new https_1.HttpsError('invalid-argument', 'code is required');
        }
        let storeDoc = (await db.collection('stores').where('joinCode', '==', code).limit(1).get()).docs[0];
        if (!storeDoc) {
            const hashedCode = (0, helpers_1.sha256)(code);
            storeDoc = (await db.collection('stores').where('joinCodeHash', '==', hashedCode).limit(1).get()).docs[0];
        }
        if (!storeDoc) {
            throw new https_1.HttpsError('not-found', 'Invalid join code');
        }
        const store = storeDoc.data();
        const storeId = storeDoc.id;
        const memberRef = db.collection('storeMembers').doc(storeId).collection('members').doc(decodedToken.uid);
        const existingMember = await memberRef.get();
        await memberRef.set({
            memberId: decodedToken.uid,
            storeId,
            storeName: String(store.name ?? 'Store'),
            joinedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        res.status(200).json({
            result: {
                storeId,
                storeName: String(store.name ?? 'Store'),
                alreadyJoined: existingMember.exists,
            },
        });
    }
    catch (error) {
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
        await (0, helpers_1.requireActiveManager)(db, decodedToken.uid);
        const data = (0, helpers_1.extractDataPayload)(req.body);
        const storeId = String(data.storeId ?? '');
        if (!storeId) {
            throw new https_1.HttpsError('invalid-argument', 'storeId is required');
        }
        const storeRef = db.collection('stores').doc(storeId);
        const storeSnap = await storeRef.get();
        if (!storeSnap.exists) {
            throw new https_1.HttpsError('not-found', 'Store not found');
        }
        const joinCode = (0, helpers_1.generateJoinCode)(8);
        await storeRef.set({
            joinCode,
            joinCodeHash: (0, helpers_1.sha256)(joinCode),
            joinCodeLast4: joinCode.slice(-4),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        res.status(200).json({ result: { joinCode } });
    }
    catch (error) {
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
        await (0, helpers_1.requireActiveManager)(db, decodedToken.uid);
        const data = (0, helpers_1.extractDataPayload)(req.body);
        const storeId = String(data.storeId ?? '');
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
        res.status(200).json({ result: { joinCode } });
    }
    catch (error) {
        const err = (0, helpers_1.toErrorResponse)(error);
        res.status(err.status).json(err.body);
    }
});
