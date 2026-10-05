// Web Push (RFC 8291 `aes128gcm` + VAPID RFC 8292) using WebCrypto only
// — no dependencies. Best-effort: every caller wraps this in try/catch.
//
// See docs/protocol.md §Web Push (I-701).

import type { Env } from "./env";

export interface PushSubscription {
  endpoint: string;
  keys: { p256dh: string; auth: string };
}

export interface PushPayload {
  title: string;
  body: string;
  taskId: string;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function b64urlToBytes(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  const pad = padded.length % 4 === 0 ? "" : "=".repeat(4 - (padded.length % 4));
  const binary = atob(padded + pad);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function bytesToB64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/** HKDF-Expand with a single output block: `HMAC(prk, info || 0x01)`. */
async function hkdfExpand(
  prk: Uint8Array,
  info: Uint8Array,
  length: number,
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    prk,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, concat(info, new Uint8Array([1]))),
  );
  return mac.slice(0, length);
}

async function hmacSha256(keyBytes: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, data));
}

/** RFC 8291 §3.4 encryption of a single-record `aes128gcm` body. */
async function encryptWebPush(
  p256dh: Uint8Array,
  authSecret: Uint8Array,
  plaintext: Uint8Array,
): Promise<Uint8Array> {
  const uaPublic = p256dh;
  const asKeys = (await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  )) as CryptoKeyPair;
  const asPublic = new Uint8Array(
    (await crypto.subtle.exportKey("raw", asKeys.publicKey)) as ArrayBuffer,
  );
  const uaKey = await crypto.subtle.importKey(
    "raw",
    uaPublic,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
  // workers-types exposes the ECDH peer key as `$public`; the runtime
  // accepts the spec spelling `public`, so cast through the alias.
  const ecdhSecret = new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "ECDH", $public: uaKey } satisfies SubtleCryptoDeriveKeyAlgorithm,
      asKeys.privateKey,
      256,
    ),
  );
  const salt = crypto.getRandomValues(new Uint8Array(16));

  // IKM = HKDF-Expand(HMAC(auth, ecdh), "WebPush: info" || 0x00 || ua || as, 32)
  const prkKey = await hmacSha256(authSecret, ecdhSecret);
  const keyInfo = concat(
    encoder.encode("WebPush: info"),
    new Uint8Array([0]),
    uaPublic,
    asPublic,
  );
  const ikm = await hkdfExpand(prkKey, keyInfo, 32);

  // PRK = HMAC(salt, IKM); CEK / NONCE = HKDF-Expand(PRK, label, n)
  const prk = await hmacSha256(salt, ikm);
  const cek = await hkdfExpand(
    prk,
    concat(encoder.encode("Content-Encoding: aes128gcm"), new Uint8Array([0])),
    16,
  );
  const nonce = await hkdfExpand(
    prk,
    concat(encoder.encode("Content-Encoding: nonce"), new Uint8Array([0])),
    12,
  );

  // Last (only) record: payload || 0x02 padding delimiter, AES-128-GCM.
  const aesKey = await crypto.subtle.importKey(
    "raw",
    cek,
    { name: "AES-GCM" },
    false,
    ["encrypt"],
  );
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce },
      aesKey,
      concat(plaintext, new Uint8Array([2])),
    ),
  );

  const rs = new Uint8Array([0, 0, 0x10, 0x00]); // record size 4096
  const header = concat(salt, rs, new Uint8Array([asPublic.length]), asPublic);
  return concat(header, ciphertext);
}

/** Import the VAPID P-256 signing key. `privateKey` is the base64url of
 *  a JWK (JSON) or of the raw 32-byte scalar `d`; when it is a raw
 *  scalar, `x`/`y` are taken from the base64url uncompressed public key. */
async function importVapidPrivate(
  privateKey: string,
  publicKey: string,
): Promise<CryptoKey> {
  if (privateKey.trimStart().startsWith("{")) {
    return crypto.subtle.importKey(
      "jwk",
      JSON.parse(privateKey),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
  }
  const raw = b64urlToBytes(privateKey);
  const asText = decoder.decode(raw);
  if (asText.trimStart().startsWith("{")) {
    return crypto.subtle.importKey(
      "jwk",
      JSON.parse(asText),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
  }
  const pub = b64urlToBytes(publicKey);
  const jwk = {
    kty: "EC",
    crv: "P-256",
    d: bytesToB64url(raw),
    x: bytesToB64url(pub.slice(1, 33)),
    y: bytesToB64url(pub.slice(33, 65)),
  };
  return crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, [
    "sign",
  ]);
}

/** `Authorization: vapid t=<jwt>, k=<publicBase64url>`, or null when the
 *  VAPID key pair is not configured. */
async function vapidAuthorization(
  env: Env,
  endpoint: string,
): Promise<string | null> {
  const publicKey = env.VAPID_PUBLIC_KEY;
  const privateKey = env.VAPID_PRIVATE_KEY;
  if (!publicKey || !privateKey) return null;
  const header = bytesToB64url(
    encoder.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })),
  );
  const claims = bytesToB64url(
    encoder.encode(
      JSON.stringify({
        aud: new URL(endpoint).origin,
        exp: Math.floor(Date.now() / 1000) + 12 * 60 * 60,
        sub: env.VAPID_SUBJECT ?? "mailto:admin@localhost",
      }),
    ),
  );
  const signingInput = `${header}.${claims}`;
  const key = await importVapidPrivate(privateKey, publicKey);
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      encoder.encode(signingInput),
    ),
  );
  return `vapid t=${signingInput}.${bytesToB64url(signature)}, k=${publicKey}`;
}

export type PushResult = "ok" | "gone" | "skip" | "error";

/** Deliver one notification. "gone" means the subscription is dead and
 *  the caller should delete it (404/410 from the push service). */
export async function sendWebPush(
  env: Env,
  subscription: PushSubscription,
  payload: PushPayload,
): Promise<PushResult> {
  const authorization = await vapidAuthorization(env, subscription.endpoint);
  if (!authorization) return "skip";
  const body = await encryptWebPush(
    b64urlToBytes(subscription.keys.p256dh),
    b64urlToBytes(subscription.keys.auth),
    encoder.encode(JSON.stringify(payload)),
  );
  const res = await fetch(subscription.endpoint, {
    method: "POST",
    headers: {
      authorization,
      "content-encoding": "aes128gcm",
      "content-type": "application/octet-stream",
      ttl: "3600",
    },
    body,
  });
  if (res.status === 404 || res.status === 410) return "gone";
  return res.ok ? "ok" : "error";
}
