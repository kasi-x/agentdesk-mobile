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
}
