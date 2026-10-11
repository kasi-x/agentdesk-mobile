export interface Env {
  TASK_HUB: DurableObjectNamespace;
  /** Static assets served from ../web (Phase 2 web triage UI). */
  ASSETS: Fetcher;
  /** Agents → hub. Secret. */
  AGENT_TOKEN?: string;
  /** Clients (mobile / web) → hub. Secret. */
  CLIENT_TOKEN?: string;
  /** Comma-separated CORS allowlist; "*" allows any origin (dev only). */
  ALLOWED_ORIGINS?: string;
  /** Undo grace window in ms (I-104). Parsed as integer; defaults to
   *  `UNDO_GRACE_MS` (5000) when absent or unparsable. */
  UNDO_GRACE_MS?: string;
  /** HMAC key for replyUrl signatures (I-801); falls back to
   *  `AGENT_TOKEN` when unset. */
  REPLY_SIGNING_SECRET?: string;
  /** Web Push / VAPID (I-701). All optional: when the key pair is unset
   *  the hub skips push delivery silently. `VAPID_PRIVATE_KEY` is the
   *  base64url-encoded P-256 private key (or a base64url JWK);
   *  `VAPID_PUBLIC_KEY` is the base64url uncompressed public key. */
  VAPID_PUBLIC_KEY?: string;
  VAPID_PRIVATE_KEY?: string;
  /** VAPID `sub` claim; defaults to "mailto:admin@localhost". */
  VAPID_SUBJECT?: string;
  /** Native push via APNs (I-701 follow-up). All optional: when any of
   *  the four is unset the hub stores APNs registrations but skips APNs
   *  delivery silently. `APNS_PRIVATE_KEY` is the P-256 .p8 key (PEM or
   *  base64/DER); `APNS_SANDBOX` ("1"/"true") selects the sandbox host. */
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_BUNDLE_ID?: string;
  APNS_SANDBOX?: string;
  /** Native push via FCM v1 (I-701 follow-up). Same skip-when-unset
   *  pattern; `FCM_PRIVATE_KEY` is the service-account RSA key (PEM or
   *  base64/DER; literal "\n" escapes tolerated). */
  FCM_PROJECT_ID?: string;
  FCM_CLIENT_EMAIL?: string;
  FCM_PRIVATE_KEY?: string;
}
