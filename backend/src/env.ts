export interface Env {
  TASK_HUB: DurableObjectNamespace;
  /** Agents → hub. Secret. */
  AGENT_TOKEN?: string;
  /** Clients (mobile / web) → hub. Secret. */
  CLIENT_TOKEN?: string;
  /** Comma-separated CORS allowlist; "*" allows any origin (dev only). */
  ALLOWED_ORIGINS?: string;
}
