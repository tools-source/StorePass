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
exports.normalizeCode = normalizeCode;
exports.sha256 = sha256;
exports.generateJoinCode = generateJoinCode;
exports.extractDataPayload = extractDataPayload;
exports.verifyBearerToken = verifyBearerToken;
exports.toErrorResponse = toErrorResponse;
exports.requireActiveManager = requireActiveManager;
const admin = __importStar(require("firebase-admin"));
const crypto = __importStar(require("crypto"));
const https_1 = require("firebase-functions/v2/https");
const HTTPS_STATUS_BY_ERROR_CODE = {
    'invalid-argument': 400,
    unauthenticated: 401,
    'permission-denied': 403,
    'not-found': 404,
    'failed-precondition': 412,
};
function normalizeCode(code) {
    return String(code ?? '').trim().toUpperCase();
}
function sha256(value) {
    return crypto.createHash('sha256').update(value).digest('hex');
}
function generateJoinCode(length = 8) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    const randomBytes = crypto.randomBytes(length);
    let code = '';
    for (let i = 0; i < length; i += 1) {
        code += alphabet[randomBytes[i] % alphabet.length];
    }
    return code;
}
function extractDataPayload(body) {
    if (!body || typeof body !== 'object') {
        throw new https_1.HttpsError('invalid-argument', 'Body must be JSON object with a data field');
    }
    const parsedBody = body;
    if (!('data' in parsedBody) || !parsedBody.data || typeof parsedBody.data !== 'object') {
        throw new https_1.HttpsError('invalid-argument', 'Body must contain data object');
    }
    return parsedBody.data;
}
async function verifyBearerToken(req) {
    const authHeader = String(req.headers.authorization ?? '');
    if (!authHeader.startsWith('Bearer ')) {
        throw new https_1.HttpsError('unauthenticated', 'Unauthorized');
    }
    const idToken = authHeader.slice('Bearer '.length).trim();
    if (!idToken) {
        throw new https_1.HttpsError('unauthenticated', 'Unauthorized');
    }
    try {
        return await admin.auth().verifyIdToken(idToken);
    }
    catch {
        throw new https_1.HttpsError('unauthenticated', 'Unauthorized');
    }
}
function toErrorResponse(error) {
    if (error instanceof https_1.HttpsError) {
        const status = HTTPS_STATUS_BY_ERROR_CODE[error.code] ?? 500;
        return { status, body: { error: { message: error.message } } };
    }
    console.error('[functions] Unexpected error', error);
    return {
        status: 500,
        body: { error: { message: 'Internal server error' } },
    };
}
async function requireActiveManager(db, uid) {
    const [managerSnap, userSnap] = await Promise.all([
        db.collection('managers').doc(uid).get(),
        db.collection('users').doc(uid).get(),
    ]);
    const managerDocExists = managerSnap.exists;
    const managerDocActive = managerSnap.exists && managerSnap.data()?.isActive === true;
    const userData = userSnap.data();
    const userDocExists = userSnap.exists;
    const userRole = typeof userData?.role === 'string' ? userData.role : null;
    const userIsActive = userData?.isActive === true;
    const activeManagerUser = userDocExists && userRole === 'manager' && userIsActive;
    if (!managerDocActive && !activeManagerUser) {
        throw new https_1.HttpsError('permission-denied', 'Manager access required');
    }
    return {
        managerDocExists,
        managerDocActive,
        userDocExists,
        userRole,
        userIsActive,
    };
}
