#!/usr/bin/env python3
"""Opt-in Codex reset-credit automation. Default: read-only. Python 3.10+."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

BASE = "https://chatgpt.com/backend-api/wham/"
CREDITS = "rate-limit-reset-credits"
WEEK = 604800
STATE_DIR = Path.home() / "Library/Application Support/openai-autoreset"


class Refusal(Exception):
    """An unsafe or unknown condition. Never continue to redemption."""


def number(value):
    if type(value) not in (int, float):
        raise Refusal("Missing or invalid numeric API field.")
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite:
        raise Refusal("Missing or invalid numeric API field.")
    return value


def weekly(data, now):
    """Select by actual duration, never by primary/secondary position alone."""
    if not isinstance(data, dict) or not isinstance(data.get("rate_limit"), dict):
        raise Refusal("Unknown usage response schema.")
    candidates = []
    for name in ("primary_window", "secondary_window"):
        window = data["rate_limit"].get(name)
        if isinstance(window, dict) and window.get("limit_window_seconds") == WEEK:
            candidates.append(window)
    if len(candidates) != 1:
        raise Refusal("Expected exactly one general seven-day usage window.")
    window = candidates[0]
    used = number(window.get("used_percent"))
    resets_at = number(window.get("reset_at"))
    if not 0 <= used <= 100 or not now < resets_at <= now + WEEK + 300:
        raise Refusal("Invalid or expired weekly usage window.")
    return 100 - used, resets_at


def require_threshold(remaining):
    # Deliberately no rounding and no configurable override of this hard ceiling.
    if not 0 <= number(remaining) <= 1:
        raise Refusal(
            f"WARNING: weekly remaining is {remaining!r}%, above 1%. Reset refused."
        )


def available_credits(data, now):
    if not isinstance(data, dict) or not isinstance(data.get("credits"), list):
        raise Refusal("Unknown reset-credit response schema.")
    count = data.get("available_count")
    if type(count) is not int or count < 0:
        raise Refusal("Unknown reset-credit count.")
    result = []
    seen = set()
    for credit in data["credits"]:
        if not isinstance(credit, dict):
            raise Refusal("Malformed reset-credit entry.")
        if credit.get("status") != "available":
            continue
        cid = credit.get("id")
        if not isinstance(cid, str) or not cid or cid in seen:
            raise Refusal("Missing or duplicate available credit ID.")
        seen.add(cid)
        try:
            expiry = datetime.fromisoformat(credit["expires_at"].replace("Z", "+00:00"))
            if expiry.tzinfo is None:
                raise ValueError("Timezone required")
            expiry = expiry.timestamp()
        except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
            raise Refusal("Unknown reset-credit expiry.") from None
        if credit.get("reset_type") == "codex_rate_limits" and expiry > now + 60:
            result.append((expiry, cid))
    if len(seen) != count:
        raise Refusal("Reset-credit inventory and available count disagree.")
    return sorted(result)


def load_auth(path, expected):
    try:
        data = json.loads(path.read_text())
        tokens = data["tokens"]
        token, account = tokens["access_token"], tokens["account_id"]
    except (OSError, ValueError, KeyError, TypeError):
        raise Refusal("Cannot read Codex OAuth credentials. Sign in manually if needed.") from None
    if not isinstance(token, str) or not token or account != expected:
        raise Refusal("Missing OAuth token or account ID differs from --account-id.")
    if any(c in token + expected for c in "\r\n"):
        raise Refusal("Invalid credential header.")
    return token


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Refusal("HTTP redirect refused. No credentials forwarded.")


class API:
    def __init__(self, token, account):
        self.headers = {
            "Authorization": "Bearer " + token,
            "ChatGPT-Account-ID": account,
            "Accept": "application/json",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop",
            "User-Agent": "openai-autoreset/1.0",
            "Cache-Control": "no-cache, no-store",
        }
        # Do not inherit proxy settings and never follow authenticated redirects.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, path, body=None):
        if path not in ("usage", CREDITS, CREDITS + "/consume"):
            raise Refusal("Endpoint not allowlisted.")
        if (body is not None) != (path == CREDITS + "/consume"):
            raise Refusal("Invalid endpoint/method pairing.")
        headers = dict(self.headers)
        payload = None
        if body is not None:
            payload = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(BASE + path, data=payload, headers=headers,
                                     method="POST" if payload is not None else "GET")
        try:
            # No retries, including on POST timeout, HTTP error or malformed response.
            with self.opener.open(req, timeout=20) as response:
                if response.status != 200:
                    raise Refusal("Unexpected HTTP status. Stop and inspect manually.")
                age = response.headers.get("Age")
                if age is not None and age != "0":
                    raise Refusal("Cached API response refused.")
                raw = response.read(2_000_001)
                if len(raw) > 2_000_000:
                    raise Refusal("Oversized API response.")
                data = json.loads(raw)
                if not isinstance(data, dict):
                    raise Refusal("Expected a JSON object.")
                return data
        except urllib.error.HTTPError as exc:
            raise Refusal(f"HTTP {exc.code}. No retry. Check account manually.") from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            raise Refusal("Network or JSON error. No retry. Check account manually.") from None


@contextmanager
def locked_state():
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = STATE_DIR.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Refusal("State directory must be owned by you, private (0700), and not a symlink.")
    fd = os.open(STATE_DIR / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refusal("Another reset checker is running.") from None
        yield
    finally:
        os.close(fd)


def read_state(path, account_hash):
    if path.is_symlink():
        raise Refusal("State file must not be a symlink.")
    if not path.exists():
        return {"version": 1, "account": account_hash, "attempts": []}
    try:
        state = json.loads(path.read_text())
        if (not isinstance(state, dict) or type(state.get("version")) is not int
                or state["version"] != 1 or state.get("account") != account_hash
                or not isinstance(state.get("attempts"), list)):
            raise Refusal("Invalid state journal header.")
        for item in state["attempts"]:
            if (not isinstance(item, dict) or item.get("status") not in ("pending", "verified")
                    or not isinstance(item.get("credit_id"), str) or not item["credit_id"]
                    or not isinstance(item.get("request_id"), str) or not item["request_id"]):
                raise Refusal("Invalid state journal attempt.")
            if number(item.get("time")) <= 0:
                raise Refusal("Invalid state journal timestamp.")
    except (OSError, ValueError, KeyError, TypeError):
        raise Refusal("Invalid state journal. Refusing to forget previous attempts.") from None
    return state


def save_state(path, state):
    fd, name = tempfile.mkstemp(prefix="journal-", dir=STATE_DIR)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(state, handle, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
            # macOS asks the storage device to flush its write cache as well.
            fcntl.fcntl(handle.fileno(), 51)  # F_FULLFSYNC
        os.replace(name, path)
        directory_fd = os.open(STATE_DIR, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        # Request another device flush after the rename and directory sync.
        with path.open("rb") as published:
            fcntl.fcntl(published.fileno(), 51)  # F_FULLFSYNC
    finally:
        if os.path.exists(name):
            os.unlink(name)


def check(api, execute, max_resets, state=None, state_path=None):
    remaining, boundary = weekly(api.request("usage"), time.time())
    print(f"Weekly remaining: {remaining!r}%", flush=True)
    require_threshold(remaining)
    if boundary - time.time() <= 300:
        raise Refusal("Natural weekly reset is within five minutes. Save the reset credit.")
    if execute:
        attempts = state["attempts"]
        if any(item["status"] == "pending" for item in attempts):
            raise Refusal("Unresolved reset attempt. Check the dashboard and journal manually. No retry.")
        if len(attempts) >= max_resets:
            raise Refusal("Configured lifetime reset-attempt budget reached.")
        if attempts and time.time() - max(item["time"] for item in attempts) < 21600:
            raise Refusal("Six-hour reset cooldown is active.")
    credits = available_credits(api.request(CREDITS), time.time())
    if not credits:
        raise Refusal("No eligible, unexpired banked reset credit available.")
    _, credit_id = credits[0]
    if not execute:
        print("DRY RUN: eligible at 0%-1% remaining. No reset requested.", flush=True)
        return
    if any(item["credit_id"] == credit_id for item in state["attempts"]):
        raise Refusal("Selected credit has already been attempted. No retry.")
    # Re-fetch inventory, then usage last. Never redeem against the earlier reading.
    if credit_id not in {cid for _, cid in available_credits(api.request(CREDITS), time.time())}:
        raise Refusal("Selected credit is no longer available.")
    checked_at = time.monotonic()
    remaining, final_boundary = weekly(api.request("usage"), time.time())
    require_threshold(remaining)
    if boundary != final_boundary or final_boundary - time.time() <= 300:
        raise Refusal("Weekly window changed or is about to reset. No credit spent.")
    attempt = {"credit_id": credit_id, "request_id": str(uuid.uuid4()),
               "time": time.time(), "status": "pending"}
    state["attempts"].append(attempt)
    # Persist intent BEFORE sending. A crash or ambiguous POST leaves a blocking journal.
    save_state(state_path, state)
    if time.monotonic() - checked_at > 5 or final_boundary - time.time() <= 300:
        raise Refusal("Preflight reading became stale. Journal remains blocked for manual review.")
    require_threshold(remaining)  # hard guard immediately before the only POST call
    api.request(CREDITS + "/consume", {
        "credit_id": credit_id, "redeem_request_id": attempt["request_id"]
    })
    time.sleep(3)
    after_remaining, _ = weekly(api.request("usage"), time.time())
    after = api.request(CREDITS)
    available_credits(after, time.time())  # validate response before interpreting it
    entries = [c for c in after["credits"] if c.get("id") == credit_id]
    # Absence alone is not proof. Require an explicit consumed status and recovered quota.
    if after_remaining <= 1 or len(entries) != 1 or entries[0].get("status") != "consumed":
        raise Refusal("Reset outcome not verified. Journal remains blocked. Inspect dashboard, do not retry.")
    attempt["status"] = "verified"
    save_state(state_path, state)
    print("Reset verified by recovered weekly quota and consumed credit. One credit spent.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--execute", action="store_true", help="ALLOW spending a banked reset")
    modes.add_argument("--dry-run", action="store_true", help="Read only (the default)")
    parser.add_argument("--account-id", required=True, help="Pin the intended tokens.account_id")
    parser.add_argument("--auth", type=Path,
                        default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "auth.json")
    parser.add_argument("--max-resets", type=int, default=1,
                        help="Maximum lifetime attempts in this account journal (default 1)")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise Refusal("This automation is intended for macOS only.")
    if not args.account_id or not 1 <= args.max_resets <= 100:
        raise Refusal("Account ID and reset-attempt budget (1-100) required.")
    token = load_auth(args.auth.expanduser(), args.account_id)
    api = API(token, args.account_id)
    if not args.execute:
        check(api, False, args.max_resets)
        return
    account_hash = hashlib.sha256(args.account_id.encode()).hexdigest()
    with locked_state():
        path = STATE_DIR / (account_hash + ".json")
        state = read_state(path, account_hash)
        check(api, True, args.max_resets, state, path)


if __name__ == "__main__":
    try:
        main()
    except (Refusal, OSError) as exc:
        # Do not log raw HTTP bodies, headers, credentials, or OS error paths.
        message = str(exc) if isinstance(exc, Refusal) else "Local I/O failure. Reset automation stopped."
        print(message, file=sys.stderr, flush=True)
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(130)
