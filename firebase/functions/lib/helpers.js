"use strict";
const admin = require("firebase-admin");
const crypto = require("crypto");
const { HttpsError } = require("firebase-functions/v2/https");

function normalizeCode(code) {
  return String(code ?? "").trim().toUpperCase();
}

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function generateJoinCode(length = 8) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  const bytes = crypto.randomBytes(length);
  let code = "";
  for (let i = 0; i < length; i += 1) {
    code += alphabet[bytes[i] % alphabet.length];
  }
  return code;
}

async function verifyBearerToken(req) {
  const authHeader = String(req.headers.authorization ?? "");
  if (!authHeader.startsWith("Bearer ")) {
    throw new HttpsError("unauthenticated", "Unauthorized");
  }
  const token = authHeader.slice("Bearer ".length).trim();
  if (!token) {
    throw new HttpsError("unauthenticated", "Unauthorized");
  }
  try {
    return await admin.auth().verifyIdToken(token);
  } catch {
    throw new HttpsError("unauthenticated", "Unauthorized");
  }
}

function extractDataPayload(body) {
  if (!body || typeof body !== "object") return {};
  const nested = body.data;
  if (nested && typeof nested === "object") return nested;
  return body;
}

function toErrorResponse(error) {
  if (error instanceof HttpsError) {
    if (error.code === "unauthenticated") {
      return { status: 401, body: { error: { message: "Unauthorized" } } };
    }
    const statusMap = {
      "invalid-argument": 400,
      "permission-denied": 403,
      "not-found": 404,
      "failed-precondition": 412,
    };
    return { status: statusMap[error.code] ?? 500, body: { error: { message: error.message } } };
  }
  console.error("[functions] Unexpected error", error);
  return { status: 500, body: { error: { message: "Internal server error" } } };
}

async function requireActiveManager(db, uid) {
  const [managerSnap, userSnap] = await Promise.all([
    db.collection("managers").doc(uid).get(),
    db.collection("users").doc(uid).get(),
  ]);
  const managerActive = managerSnap.exists && managerSnap.data()?.isActive === true;
  const userData = userSnap.data();
  const userManagerActive = userSnap.exists && userData?.role === "manager" && userData?.isActive === true;
  if (!managerActive && !userManagerActive) {
    throw new HttpsError("permission-denied", "Manager access required");
  }
}

module.exports = {
  normalizeCode,
  sha256,
  generateJoinCode,
  verifyBearerToken,
  extractDataPayload,
  toErrorResponse,
  requireActiveManager,
};
