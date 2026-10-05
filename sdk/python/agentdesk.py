"""AgentDesk hub SDK for Python agents — standard library only.

    from agentdesk import Desk

    desk = Desk("https://desk.example.com", agent_token=os.environ["AGENT_TOKEN"])
    decision = desk.ask({...card...}, timeout=600)
    print(decision["actionName"], decision["data"])

Uses ``urllib`` (no ``requests``), so it runs anywhere Python 3.8+ runs.
Wire contract: ``docs/protocol.md`` and ``docs/sdk.md``.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Mapping, Optional

__all__ = [
    "Desk",
    "DeskError",
    "DeskTimeoutError",
    "PROTOCOL_VERSION",
    "MAX_WAIT_SECONDS",
    "TERMINAL_STATUSES",
    "verify_signature",
    "sign_body",
    "parse_signature_header",
]

#: Wire protocol version this SDK speaks (sent on every card).
PROTOCOL_VERSION = 1

#: Server-side cap for a single ``?wait`` long-poll, in seconds.
MAX_WAIT_SECONDS = 60

#: Result statuses that mean the task will not change again.
TERMINAL_STATUSES = frozenset({"approved", "rejected", "withdrawn", "expired"})


class DeskError(Exception):
    """Non-2xx hub response, or malformed input."""

    def __init__(
        self,
        message: str,
        status: Optional[int] = None,
        code: Optional[str] = None,
        body: Any = None,
    ) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.body = body


class DeskTimeoutError(DeskError):
    """``ask()`` gave up before the task reached a terminal status."""

    def __init__(self, task_id: str, timeout: float) -> None:
        super().__init__(
            "task %s did not reach a terminal state within %ss" % (task_id, timeout)
        )
        self.task_id = task_id
        self.timeout = timeout


def _get_header(headers: Any, name: str) -> Optional[str]:
    """Case-insensitive header lookup for dicts and ``email.message.Message``."""
    if headers is None:
        return None
    target = name.lower()
    getter = getattr(headers, "get", None)
    if getter is not None:
        value = getter(name)
        if value is None:
            value = getter(target)
        if value is not None:
            return value if isinstance(value, str) else str(value)
    try:
        items = headers.items()
    except AttributeError:
        return None
    for key, value in items:
        if str(key).lower() == target:
            return value if isinstance(value, str) else str(value)
    return None


def _body_bytes(body: Any) -> bytes:
    if body is None:
        return b""
    if isinstance(body, bytes):
        return body
    if isinstance(body, bytearray):
        return bytes(body)
    if isinstance(body, str):
        return body.encode("utf-8")
    return json.dumps(body).encode("utf-8")


def parse_signature_header(value: Any) -> dict:
    """Parse ``t=<ts>,v1=<hex>`` into ``{"t": ..., "v1": ...}``."""
    out: dict = {}
    for part in str(value or "").split(","):
        if "=" not in part:
            continue
        key, _, val = part.partition("=")
        out[key.strip()] = val.strip()
    return out


def _hmac_hex(secret: Any, ts: str, body: Any) -> str:
    message = ts.encode("utf-8") + b"." + _body_bytes(body)
    return hmac.new(str(secret).encode("utf-8"), message, hashlib.sha256).hexdigest()


def sign_body(secret: str, body: Any, ts: Optional[int] = None) -> str:
    """Build the hub's header value: ``t=<ts>,v1=<hex>``. ``ts`` in seconds."""
    if ts is None:
        ts = int(time.time())
    return "t=%s,v1=%s" % (ts, _hmac_hex(secret, str(ts), body))


def verify_signature(
    headers: Any,
    body: Any,
    secret: Optional[str],
    max_skew: Optional[float] = None,
    now: Optional[float] = None,
) -> bool:
    """Verify an inbound hub callback signature (HMAC-SHA256 over ``t.body``).

    ``headers`` may be a dict or an ``http.server`` message. ``body`` must be
    the raw request body exactly as received (``bytes`` or ``str``) — passing a
    re-serialized dict changes the bytes and fails verification. ``max_skew``
    (seconds) is optional; when set, a stale timestamp fails.
    """
    if not secret:
        return False
    header = _get_header(headers, "X-AgentDesk-Signature")
    parsed = parse_signature_header(header)
    ts = parsed.get("t")
    provided = parsed.get("v1")
    if not ts or not provided:
        return False
    if max_skew is not None:
        try:
            ts_sec = float(ts)
        except ValueError:
            return False
        current = time.time() if now is None else now
        if abs(current - ts_sec) > max_skew:
            return False
    expected = _hmac_hex(secret, ts, body)
    return hmac.compare_digest(expected, provided)


class Desk:
    """Agent-side client for the AgentDesk hub.

    :param hub_url: hub origin, e.g. ``"https://desk.example.com"``
    :param agent_token: bearer token (``AGENT_TOKEN``)
    :param timeout: default ``ask()`` budget in seconds (default 300)
    """

    def __init__(self, hub_url: str, agent_token: str, timeout: float = 300.0) -> None:
        if not hub_url:
            raise DeskError("hub_url is required")
        if not agent_token:
            raise DeskError("agent_token is required")
        self.hub_url = str(hub_url).rstrip("/")
        self.agent_token = agent_token
        self.timeout = timeout

    # -- transport ---------------------------------------------------------

    def _request(
        self,
        method: str,
        path: str,
        body: Any = None,
        timeout: float = 30.0,
    ) -> Any:
        headers = {
            "Authorization": "Bearer %s" % self.agent_token,
            "Accept": "application/json",
        }
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(
            self.hub_url + path, data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as err:
            raw = err.read()
            parsed = None
            if raw:
                try:
                    parsed = json.loads(raw.decode("utf-8"))
                except (ValueError, UnicodeDecodeError):
                    parsed = None
            code = None
            if isinstance(parsed, dict):
                code = parsed.get("error") or parsed.get("code")
            raise DeskError(
                "%s %s failed: %s%s"
                % (method, path, err.code, " %s" % code if code else ""),
                status=err.code,
                code=code,
                body=parsed if parsed is not None else raw.decode("utf-8", "replace"),
            ) from None
        except urllib.error.URLError as err:
            raise DeskError("%s %s failed: %s" % (method, path, err.reason)) from None
        if not raw:
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as err:
            raise DeskError("%s %s returned invalid JSON" % (method, path)) from err

    # -- API ---------------------------------------------------------------

    def enqueue(self, card: Mapping[str, Any]) -> Any:
        """POST a card to ``/api/v1/tasks``; returns the hub echo (taskId, nonce)."""
        payload = {"protocolVersion": PROTOCOL_VERSION, **dict(card)}
        return self._request("POST", "/api/v1/tasks", payload)

    def result(self, task_id: str, wait: float = MAX_WAIT_SECONDS) -> Any:
        """GET ``/api/v1/tasks/{id}/result?wait=N`` (long-poll up to 60s)."""
        wait_s = max(0, int(wait))
        path = "/api/v1/tasks/%s/result?%s" % (
            urllib.parse.quote(str(task_id), safe=""),
            urllib.parse.urlencode({"wait": wait_s}),
        )
        # long-poll request must outlive the server-side wait
        return self._request("GET", path, timeout=wait_s + 30.0 if wait_s else 30.0)

    def ask(
        self,
        card: Mapping[str, Any],
        timeout: Optional[float] = None,
    ) -> dict:
        """Enqueue a card and block until the human decides.

        Returns ``{"taskId", "status", "actionName", "data", "source", "action",
        "delivery"}``. ``timeout`` is the overall budget in seconds (defaults to
        the client's ``timeout``); raises :class:`DeskTimeoutError` on expiry.
        """
        budget = self.timeout if timeout is None else timeout
        created = self.enqueue(card)
        task_id = None
        if isinstance(created, dict):
            task_id = created.get("taskId")
        if not task_id:
            task_id = dict(card).get("taskId")
        if not task_id:
            raise DeskError("ask: hub response did not include a taskId")

        deadline = time.monotonic() + max(0.0, float(budget))
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                wait_s = 0
            else:
                wait_s = max(1, min(MAX_WAIT_SECONDS, int(remaining + 0.999)))
            state = self.result(task_id, wait=wait_s)
            if isinstance(state, dict) and state.get("status") in TERMINAL_STATUSES:
                action = state.get("action") or {}
                return {
                    "taskId": task_id,
                    "status": state.get("status"),
                    "actionName": action.get("name"),
                    "data": action.get("data"),
                    "source": action.get("source"),
                    "action": state.get("action"),
                    "delivery": state.get("delivery"),
                }
            if time.monotonic() >= deadline:
                raise DeskTimeoutError(task_id, budget)

    def update(self, task_id: str, card: Mapping[str, Any]) -> Any:
        """Replace a still-pending card (rotates the nonce, ``revised: true``)."""
        payload = {"protocolVersion": PROTOCOL_VERSION, **dict(card)}
        return self._request(
            "POST",
            "/api/v1/tasks/%s/update" % urllib.parse.quote(str(task_id), safe=""),
            payload,
        )

    def withdraw(self, task_id: str) -> Any:
        """Withdraw a still-pending card (broadcasts ``withdrawTask``)."""
        return self._request(
            "POST",
            "/api/v1/tasks/%s/withdraw" % urllib.parse.quote(str(task_id), safe=""),
        )

    def verify_signature(
        self,
        headers: Any,
        body: Any,
        secret: Optional[str] = None,
        max_skew: Optional[float] = None,
    ) -> bool:
        """Instance helper; ``secret`` defaults to the agent token."""
        return verify_signature(
            headers, body, secret if secret is not None else self.agent_token, max_skew
        )
