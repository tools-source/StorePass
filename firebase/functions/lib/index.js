"use strict";
const { onRequest, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const {
  extractDataPayload,
  generateJoinCode,
  normalizeCode,
  requireActiveManager,
  sha256,
  toErrorResponse,
  verifyBearerToken,
} = require("./helpers");

admin.initializeApp();
const db = admin.firestore();

exports.joinStoreByCode = onRequest({ region: "us-central1" }, async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ error: { message: "Method not allowed" } });
    return;
  }
  try {
    const decoded = await verifyBearerToken(req);
    const data = extractDataPayload(req.body);
    const code = normalizeCode(data.code);
    if (!code) throw new HttpsError("invalid-argument", "code is required");

    let storeDoc = (await db.collection("stores").where("joinCode", "==", code).limit(1).get()).docs[0];
    if (!storeDoc) {
      storeDoc = (await db.collection("stores").where("joinCodeHash", "==", sha256(code)).limit(1).get()).docs[0];
    }
    if (!storeDoc) {
      res.status(404).json({ error: { message: "Invalid join code" } });
      return;
    }

    const store = storeDoc.data();
    const storeId = storeDoc.id;
    const memberRef = db.collection("storeMembers").doc(storeId).collection("members").doc(decoded.uid);
    const existingMember = await memberRef.get();

    await memberRef.set({
      memberId: decoded.uid,
      storeId,
      storeName: String(store.name ?? "Store"),
      joinedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    res.status(200).json({
      result: {
        storeId,
        storeName: String(store.name ?? "Store"),
        alreadyJoined: existingMember.exists,
      },
    });
  } catch (error) {
    const err = toErrorResponse(error);
    res.status(err.status).json(err.body);
  }
});

exports.getStoreJoinCode = onRequest({ region: "us-central1" }, async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ error: { message: "Method not allowed" } });
    return;
  }
  try {
    const decoded = await verifyBearerToken(req);
    await requireActiveManager(db, decoded.uid);
    const data = extractDataPayload(req.body);
    const storeId = String(data.storeId ?? "");
    if (!storeId) throw new HttpsError("invalid-argument", "storeId is required");

    const storeSnap = await db.collection("stores").doc(storeId).get();
    if (!storeSnap.exists) throw new HttpsError("not-found", "Store not found");

    const store = storeSnap.data() ?? {};
    const joinCode = typeof store.joinCode === "string" ? store.joinCode : "";
    if (joinCode) {
      res.status(200).json({ result: { joinCode } });
      return;
    }

    res.status(412).json({
      error: {
        message: "joinCode not stored; only last4 available",
        joinCodeLast4: store.joinCodeLast4 ?? null,
      },
    });
  } catch (error) {
    const err = toErrorResponse(error);
    res.status(err.status).json(err.body);
  }
});

exports.rotateStoreCode = onRequest({ region: "us-central1" }, async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ error: { message: "Method not allowed" } });
    return;
  }
  try {
    const decoded = await verifyBearerToken(req);
    await requireActiveManager(db, decoded.uid);
    const data = extractDataPayload(req.body);
    const storeId = String(data.storeId ?? "");
    if (!storeId) throw new HttpsError("invalid-argument", "storeId is required");

    const storeRef = db.collection("stores").doc(storeId);
    const storeSnap = await storeRef.get();
    if (!storeSnap.exists) throw new HttpsError("not-found", "Store not found");

    const joinCode = generateJoinCode(8);
    await storeRef.set({
      joinCode,
      joinCodeHash: sha256(joinCode),
      joinCodeLast4: joinCode.slice(-4),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    res.status(200).json({ result: { joinCode } });
  } catch (error) {
    const err = toErrorResponse(error);
    res.status(err.status).json(err.body);
  }
});
