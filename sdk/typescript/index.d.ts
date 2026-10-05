/**
 * AgentDesk agent SDK — type declarations for `@agentdesk/sdk`.
 *
 * Wire contract: docs/protocol.md, docs/sdk.md.
 */

/** Wire protocol version this SDK speaks (sent on every card). */
export const PROTOCOL_VERSION: 1;

/** Server-side cap for a single `?wait` long-poll, in seconds. */
export const MAX_WAIT_SECONDS: 60;

/** Result statuses that mean the task will not change again. */
export const TERMINAL_STATUSES: readonly [
  "approved",
  "rejected",
  "withdrawn",
  "expired",
];

/** Default `ask()` timeout: 5 minutes. */
export const DEFAULT_TIMEOUT_MS: 300_000;

export class DeskError extends Error {
  name: "DeskError";
  status?: number;
  code?: string;
  body?: unknown;
}

export class DeskTimeoutError extends DeskError {
  name: "DeskTimeoutError";
  taskId: string;
  timeoutMs: number;
}

export interface DeskClientOptions {
  /** hub origin, e.g. "https://desk.example.com" */
  hubUrl?: string;
  /** bearer token (`AGENT_TOKEN`) */
  agentToken?: string;
}

export interface DeskAskOptions {
  /** overall budget in ms (default 5 min; `Infinity` waits forever) */
  timeout?: number;
}

export interface DeskReply {
  taskId: string;
  nonce: string;
  actionName: string;
  timestamp: string;
  source: string;
  data?: unknown;
}

export interface DeskActionResult {
  taskId: string;
  status: string;
  actionName: string | null;
  data: unknown;
  source: string | null;
  action: { name: string; data: unknown; source: string; at: string } | null;
  delivery?: unknown;
}

export interface DeskReplyHandler {
  secret: string | undefined;
  /** `X-AgentDesk-Event` header value, or null */
  event(headers: unknown): string | null;
  /** HMAC check over `t.body`; false on any mismatch */
  verify(headers: unknown, body: string | Buffer | Uint8Array): boolean;
  /** verify + JSON.parse; throws DeskError on bad signature / non-JSON */
  handle(
    headers: unknown,
    body: string | Buffer | Uint8Array,
  ): { event: string; reply: DeskReply };
}

export interface DeskClient {
  hubUrl: string;
  /** POST a card to `/api/v1/tasks`; resolves with the hub echo (taskId, nonce). */
  enqueue(card: Record<string, unknown>): Promise<Record<string, unknown> | null>;
  /** GET `/api/v1/tasks/{id}/result?wait=N` (long-poll up to 60s). */
  result(taskId: string, wait?: number): Promise<Record<string, unknown> | null>;
  /** Enqueue a card and block until the human decides. */
  ask(
    card: Record<string, unknown>,
    options?: DeskAskOptions,
  ): Promise<DeskActionResult>;
  /** Replace a still-pending card (rotates nonce; rebroadcasts `revised:true`). */
  update(
    taskId: string,
    card: Record<string, unknown>,
  ): Promise<Record<string, unknown> | null>;
  /** Withdraw a still-pending card (broadcasts `withdrawTask`). */
  withdraw(taskId: string): Promise<Record<string, unknown> | null>;
  /** Express-free HMAC verification for `replyUrl` callbacks. */
  replyHandler(options?: {
    secret?: string;
    maxSkew?: number;
  }): DeskReplyHandler;
}

export function createClient(options?: DeskClientOptions): DeskClient;

/** Parse `t=<ts>,v1=<hex>` into `{ t, v1 }`. */
export function parseSignatureHeader(value: string): { t?: string; v1?: string };

/** Build the signature header value: `t=<ts>,v1=<hex>`. `ts` in seconds. */
export function signBody(
  secret: string,
  body: string | Buffer | Uint8Array,
  options?: { ts?: number },
): string;

/** Verify an inbound hub callback signature (HMAC-SHA256 over `t.body`). */
export function verifySignature(
  headers: unknown,
  body: string | Buffer | Uint8Array,
  secret: string | undefined,
  options?: { maxSkew?: number; now?: number },
): boolean;

export default createClient;