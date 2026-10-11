// Native push: APNs (Apple) + FCM v1 (Android) fan-out using WebCrypto
// only — no dependencies. Best-effort: callers wrap sends in try/catch
// and prune tokens reported dead ("gone").
//
// Registration stores even when the provider secrets are unset; sends
// then skip silently (same pattern as VAPID-unset in webpush.ts).
//
// Env secrets (all optional):
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (PKCS8 EC P-256, PEM or
//   base64/DER), APNS_BUNDLE_ID, APNS_SANDBOX ("1"/"true" for sandbox)
//   FCM_PROJECT_ID, FCM_CLIENT_EMAIL, FCM_PRIVATE_KEY (PKCS8 RSA, PEM or
//   base64/DER; literal "\n" escapes are tolerated in both keys).
//
// See docs/push.md.

import type { Env } from "./env";
import type { PushResult } from "./webpush";

export interface NativePushRegistration {
  platform: "apns" | "fcm";
  /** APNs device token (64 hex chars) or FCM registration token. */
  token: string;
}

export interface NativePushPayload {
  title: string;
  body: string;
  taskId: string;
}

const encoder = new TextEncoder();

function bytesToB64url(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlOfJson(value: unknown): string {
  return bytesToB64url(encoder.encode(JSON.stringify(value)));
}

/** Validate an untrusted `POST /push/native/register` body. Pure. */
export function validateNativePushRegistration(
  body: unknown,
): { ok: true; value: NativePushRegistration } | { ok: false; error: string } {
  if (typeof body !== "object" || body === null) {
    return { ok: false, error: "body must be a JSON object" };
  }
  const { platform, token } = body as Record<string, unknown>;
  if (platform !== "apns" && platform !== "fcm") {
    return { ok: false, error: 'platform must be "apns" or "fcm"' };
  }
  if (typeof token !== "string" || token.length === 0) {
    return { ok: false, error: "token is required" };
  }
  if (platform === "apns") {
    if (!/^[0-9a-fA-F]{64}$/.test(token)) {
      return { ok: false, error: "apns token must be 64 hex characters" };
    }
  } else if (token.length < 10 || token.length > 4096 || /\s/.test(token)) {
    return { ok: false, error: "fcm token looks malformed" };
  }
  return { ok: true, value: { platform, token } };
}

/** Decode a PEM-armored or raw base64/base64url key into DER bytes. */
function keyToDer(privateKey: string): Uint8Array {
  let text = privateKey.trim();
  // `wrangler secret put` payloads often carry literal "\n" escapes.
  if (!text.includes("\n") && text.includes("\\n")) {
    text = text.replace(/\\n/g, "\n");
  }
  const armor = text.match(/-----BEGIN [^-]+-----([\s\S]*?)-----END [^-]+-----/);
  const b64 = (armor ? armor[1] : text).replace(/\s+/g, "");
  const padded = b64.replace(/-/g, "+").replace(/_/g, "/");
  const pad = padded.length % 4 === 0 ? "" : "=".repeat(4 - (padded.length % 4));
  const binary = atob(padded + pad);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

// ---------------------------------------------------------------------------
// APNs (Apple Push Notification service, HTTP/2 provider API, token auth)
// ---------------------------------------------------------------------------

export function apnsConfigured(env: Env): boolean {
  return Boolean(
    env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_PRIVATE_KEY && env.APNS_BUNDLE_ID,
  );
}

type ApnsEnv = Pick<Env, "APNS_KEY_ID" | "APNS_TEAM_ID" | "APNS_PRIVATE_KEY">;

/** Provider (ES256 JWT) token, cached ~50 min per key/team. */
let cachedApnsToken: { key: string; token: string; exp: number } | null = null;

/** Exported for tests: `header.{alg,kid}`, `claims.{iss,iat}` per Apple. */
export async function apnsProviderToken(
  env: ApnsEnv,
  nowSec = Math.floor(Date.now() / 1000),
): Promise<string> {
  const cacheKey = `${env.APNS_KEY_ID}:${env.APNS_TEAM_ID}`;
  if (cachedApnsToken && cachedApnsToken.key === cacheKey && cachedApnsToken.exp - 300 > nowSec) {
    return cachedApnsToken.token;
  }
  const header = b64urlOfJson({ alg: "ES256", kid: env.APNS_KEY_ID });
  const claims = b64urlOfJson({ iss: env.APNS_TEAM_ID, iat: nowSec });
  const signingInput = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyToDer(env.APNS_PRIVATE_KEY as string),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      encoder.encode(signingInput),
    ),
  );
  const token = `${signingInput}.${bytesToB64url(signature)}`;
  cachedApnsToken = { key: cacheKey, token, exp: nowSec + 50 * 60 };
  return token;
}

export interface ApnsRequest {
  url: string;
  headers: Record<string, string>;
  body: string;
}

/** Fully-built APNs request, or null when APNs is not configured (skip). */
export async function buildApnsRequest(
  env: Env,
  reg: NativePushRegistration,
  payload: NativePushPayload,
): Promise<ApnsRequest | null> {
  if (!apnsConfigured(env)) return null;
  const sandbox = env.APNS_SANDBOX === "1" || env.APNS_SANDBOX?.toLowerCase() === "true";
  const host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const providerToken = await apnsProviderToken(env as ApnsEnv);
  return {
    url: `https://${host}/3/device/${reg.token}`,
    headers: {
      authorization: `bearer ${providerToken}`,
      "apns-topic": env.APNS_BUNDLE_ID as string,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: { alert: { title: payload.title, body: payload.body }, sound: "default" },
      taskId: payload.taskId,
    }),
  };
}

export async function sendApnsPush(
  env: Env,
  reg: NativePushRegistration,
  payload: NativePushPayload,
): Promise<PushResult> {
  const req = await buildApnsRequest(env, reg, payload);
  if (!req) return "skip";
  const res = await fetch(req.url, { method: "POST", headers: req.headers, body: req.body });
  if (res.ok) return "ok";
  // 400 (BadDeviceToken) / 410 (Unregistered): prune the token.
  if (res.status === 400 || res.status === 410) return "gone";
  return "error";
}

// ---------------------------------------------------------------------------
// FCM v1 (Android; iOS-via-Firebase is intentionally unsupported — the app
// uses raw APNs instead so no google-services.json is ever needed)
// ---------------------------------------------------------------------------

export function fcmConfigured(env: Env): boolean {
  return Boolean(env.FCM_PROJECT_ID && env.FCM_CLIENT_EMAIL && env.FCM_PRIVATE_KEY);
}

type FcmEnv = Pick<Env, "FCM_CLIENT_EMAIL" | "FCM_PRIVATE_KEY">;

/** Service-account JWT for the OAuth2 token exchange. Exported for tests. */
export async function fcmServiceJwt(
  env: FcmEnv,
  nowSec = Math.floor(Date.now() / 1000),
): Promise<string> {
  const header = b64urlOfJson({ alg: "RS256", typ: "JWT" });
  const claims = b64urlOfJson({
    iss: env.FCM_CLIENT_EMAIL,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    exp: nowSec + 3600,
    iat: nowSec,
  });
  const signingInput = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyToDer(env.FCM_PRIVATE_KEY as string),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, encoder.encode(signingInput)),
  );
  return `${signingInput}.${bytesToB64url(signature)}`;
}

/** OAuth2 access token for the Firebase Messaging scope, cached ~55 min. */
let cachedFcmToken: { key: string; token: string; exp: number } | null = null;

export async function fcmAccessToken(
  env: FcmEnv,
  nowSec = Math.floor(Date.now() / 1000),
): Promise<string> {
  const cacheKey = `${env.FCM_CLIENT_EMAIL}`;
  if (cachedFcmToken && cachedFcmToken.key === cacheKey && cachedFcmToken.exp - 300 > nowSec) {
    return cachedFcmToken.token;
  }
  const assertion = await fcmServiceJwt(env, nowSec);
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body:
      `grant_type=${encodeURIComponent("urn:ietf:params:oauth:grant-type:jwt-bearer")}` +
      `&assertion=${encodeURIComponent(assertion)}`,
  });
  if (!res.ok) throw new Error(`oauth token exchange failed: ${res.status}`);
  const data = (await res.json()) as { access_token?: unknown };
  if (typeof data.access_token !== "string" || data.access_token.length === 0) {
    throw new Error("oauth exchange returned no access_token");
  }
  cachedFcmToken = { key: cacheKey, token: data.access_token, exp: nowSec + 55 * 60 };
  return data.access_token;
}

export interface FcmRequest {
  url: string;
  headers: Record<string, string>;
  body: string;
}

/** Fully-built FCM v1 request (pure — takes the already-minted token). */
export function buildFcmRequest(
  projectId: string,
  accessToken: string,
  reg: NativePushRegistration,
  payload: NativePushPayload,
): FcmRequest {
  return {
    url: `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    headers: {
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      message: {
        token: reg.token,
        notification: { title: payload.title, body: payload.body },
        data: { taskId: payload.taskId },
      },
    }),
  };
}

export async function sendFcmPush(
  env: Env,
  reg: NativePushRegistration,
  payload: NativePushPayload,
): Promise<PushResult> {
  if (!fcmConfigured(env)) return "skip";
  const accessToken = await fcmAccessToken(env as FcmEnv);
  const req = buildFcmRequest(env.FCM_PROJECT_ID as string, accessToken, reg, payload);
  const res = await fetch(req.url, { method: "POST", headers: req.headers, body: req.body });
  if (res.ok) return "ok";
  if (res.status === 404) return "gone";
  try {
    const data = (await res.json()) as { error?: { status?: unknown } };
    if (data.error?.status === "NOT_FOUND" || data.error?.status === "UNREGISTERED") {
      return "gone";
    }
  } catch {
    // Non-JSON error body: fall through to "error".
  }
  return "error";
}

/** Dispatch to APNs or FCM by registration platform. */
export async function sendNativePush(
  env: Env,
  reg: NativePushRegistration,
  payload: NativePushPayload,
): Promise<PushResult> {
  if (reg.platform === "apns") return sendApnsPush(env, reg, payload);
  return sendFcmPush(env, reg, payload);
}
