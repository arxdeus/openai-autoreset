"""Offline mock tests. Authored but NOT EXECUTED during implementation.

For a future authorized run from the repo root:
    python3 -m unittest discover -s tests -v
"""
import copy
import json
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path
import unittest
from unittest.mock import patch

import autoreset as ar

NOW = 1_800_000_000


def usage(remaining, boundary=NOW + 10000):
    return {"rate_limit": {
        "primary_window": {"limit_window_seconds": 18000, "used_percent": 100,
                           "reset_at": NOW + 1000},
        "secondary_window": {"limit_window_seconds": ar.WEEK,
                             "used_percent": 100 - remaining, "reset_at": boundary},
    }}


def inventory(status="available"):
    return {"available_count": 1 if status == "available" else 0, "credits": [{
        "id": "synthetic-credit", "status": status, "reset_type": "codex_rate_limits",
        "expires_at": datetime.fromtimestamp(NOW + 86400, timezone.utc).isoformat(),
    }]}


class FakeAPI:
    def __init__(self, readings=(0, 0, 100), fail_post=False, after_status="consumed"):
        self.readings = iter(readings)
        self.calls = []
        self.posted = False
        self.fail_post = fail_post
        self.after_status = after_status
        self.on_post = lambda: None

    def request(self, path, body=None):
        self.calls.append((path, body))
        if path == "usage":
            return usage(next(self.readings))
        if path == ar.CREDITS:
            return inventory(self.after_status if self.posted else "available")
        if path == ar.CREDITS + "/consume":
            self.on_post()
            self.posted = True
            if self.fail_post:
                raise ar.Refusal("Synthetic ambiguous timeout")
            return {"success": True}
        raise AssertionError("Unexpected path")


class AuthTests(unittest.TestCase):
    """Synthetic credential text only. Never reads a real auth file."""

    def load(self, data, expected="pinned-account"):
        with patch.object(Path, "read_text", return_value=json.dumps(data)):
            return ar.load_auth(Path("synthetic-auth.json"), expected)

    def test_jcode_default_path(self):
        self.assertEqual(ar.DEFAULT_AUTH, Path.home() / ".jcode/openai-auth.json")

    def test_jcode_selects_pinned_not_active_account(self):
        data = {"active_openai_account": "other-label", "openai_accounts": [
            {"label": "other-label", "account_id": "other-account", "access_token": "fake-other"},
            {"label": "pinned-label", "account_id": "pinned-account", "access_token": "fake-pinned"},
        ]}
        self.assertEqual(self.load(data), "fake-pinned")

    def test_missing_or_duplicate_jcode_account_refused(self):
        account = {"account_id": "pinned-account", "access_token": "fake-pinned"}
        for entries in ([], [dict(account, account_id="other-account")], [account, account]):
            with self.subTest(entries=entries), self.assertRaises(ar.Refusal):
                self.load({"openai_accounts": entries})

    def test_malformed_jcode_store_refused(self):
        for data in ({"openai_accounts": {}}, {"openai_accounts": [None]},
                     {"openai_accounts": [{"account_id": "pinned-account"}]},
                     {"openai_accounts": [{"account_id": "pinned-account", "access_token": ""}]}):
            with self.subTest(data=data), self.assertRaises(ar.Refusal):
                self.load(data)

    def test_codex_and_flat_overrides_retained(self):
        account = {"account_id": "pinned-account", "access_token": "fake-pinned"}
        for data in ({"tokens": account}, account):
            with self.subTest(data=data):
                self.assertEqual(self.load(data), "fake-pinned")


class ResetTests(unittest.TestCase):
    def setUp(self):
        stack = ExitStack()
        self.addCleanup(stack.close)
        self.enter_context = stack.enter_context
        # Defense in depth: no test may construct a real network opener or read auth.
        self.enter_context(patch.object(ar.urllib.request, "build_opener",
                                       side_effect=AssertionError("Network prohibited")))
        self.enter_context(patch.object(ar, "load_auth",
                                       side_effect=AssertionError("Credentials prohibited")))
        self.enter_context(patch.object(ar.time, "time", return_value=NOW))
        self.enter_context(patch.object(ar.time, "sleep"))
        self.enter_context(patch.object(ar.time, "monotonic", return_value=42))
        self.saved = []
        self.enter_context(patch.object(ar, "save_state", side_effect=lambda p, s: self.saved.append(copy.deepcopy(s))))
        self.state = {"version": 1, "account": "synthetic", "attempts": []}

    def check(self, api, live=True, maximum=1):
        return ar.check(api, live, maximum, self.state, Path("never-written.json"))

    def test_threshold_boundaries(self):
        for remaining in (0, 0.5, 1):
            with self.subTest(remaining=remaining):
                ar.require_threshold(remaining)
        for remaining in (1.000001, 1.01, 2, 50, 100):
            with self.subTest(remaining=remaining):
                with self.assertRaisesRegex(ar.Refusal, "WARNING"):
                    ar.require_threshold(remaining)

    def test_bad_numbers_fail_closed(self):
        for value in (None, True, "100", float("nan"), float("inf"), 10 ** 1000, -1, 101):
            data = usage(0)
            data["rate_limit"]["secondary_window"]["used_percent"] = value
            with self.subTest(value=value), self.assertRaises(ar.Refusal):
                ar.weekly(data, NOW)

    def test_only_weekly_window_controls_trigger(self):
        api = FakeAPI(readings=(80,))  # session is exhausted, weekly is not
        with self.assertRaisesRegex(ar.Refusal, "WARNING"):
            self.check(api)
        self.assertEqual(api.calls, [("usage", None)])
        self.assertEqual(self.saved, [])

    def test_missing_duplicate_or_expired_weekly_window(self):
        missing = {"rate_limit": {"primary_window": usage(0)["rate_limit"]["primary_window"]}}
        duplicate = usage(0)
        duplicate["rate_limit"]["primary_window"] = duplicate["rate_limit"]["secondary_window"]
        for data in (missing, duplicate, usage(0, NOW - 1)):
            with self.assertRaises(ar.Refusal):
                ar.weekly(data, NOW)

    def test_dry_run_never_posts_or_saves(self):
        api = FakeAPI(readings=(0,))
        self.check(api, live=False)
        self.assertFalse(api.posted)
        self.assertEqual(self.saved, [])

    def test_fresh_read_above_one_blocks_post(self):
        api = FakeAPI(readings=(0, 2))
        with self.assertRaisesRegex(ar.Refusal, "WARNING"):
            self.check(api)
        self.assertFalse(api.posted)
        self.assertEqual(self.saved, [])

    def test_pending_intent_precedes_single_post(self):
        api = FakeAPI(readings=(1, 1, 100))
        api.on_post = lambda: self.assertEqual(self.saved[-1]["attempts"][0]["status"], "pending")
        self.check(api)
        posts = [body for path, body in api.calls if path.endswith("/consume")]
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0]["credit_id"], "synthetic-credit")
        self.assertEqual(self.saved[-1]["attempts"][0]["status"], "verified")

    def test_ambiguous_post_blocks_next_invocation(self):
        api = FakeAPI(fail_post=True)
        with self.assertRaises(ar.Refusal):
            self.check(api)
        self.assertEqual(self.saved[-1]["attempts"][0]["status"], "pending")
        second = FakeAPI()
        with self.assertRaisesRegex(ar.Refusal, "Unresolved"):
            self.check(second, maximum=10)
        self.assertFalse(second.posted)

    def test_persistence_failure_prevents_post(self):
        api = FakeAPI()
        with patch.object(ar, "save_state", side_effect=OSError("Synthetic disk failure")):
            with self.assertRaises(OSError):
                self.check(api)
        self.assertFalse(api.posted)

    def test_unverified_receipt_leaves_pending(self):
        api = FakeAPI(after_status="unknown")
        with self.assertRaisesRegex(ar.Refusal, "not verified"):
            self.check(api)
        self.assertEqual(self.saved[-1]["attempts"][0]["status"], "pending")

    def test_budget_and_cooldown(self):
        for age, maximum in ((30000, 1), (100, 2)):
            self.state["attempts"] = [{"status": "verified", "time": NOW - age,
                                       "credit_id": "older", "request_id": "older-request"}]
            api = FakeAPI()
            with self.assertRaises(ar.Refusal):
                self.check(api, maximum=maximum)
            self.assertFalse(api.posted)

    def test_inventory_mismatch_refused(self):
        data = inventory()
        data["available_count"] = 2
        with self.assertRaises(ar.Refusal):
            ar.available_credits(data, NOW)

    def test_slow_final_read_blocks_post(self):
        api = FakeAPI()
        with patch.object(ar.time, "monotonic", side_effect=(0, 6)):
            with self.assertRaisesRegex(ar.Refusal, "stale"):
                self.check(api)
        self.assertFalse(api.posted)
        self.assertEqual(self.saved[-1]["attempts"][0]["status"], "pending")

    def test_changed_weekly_boundary_blocks_post(self):
        api = FakeAPI()
        original = api.request
        usage_calls = 0

        def changed(path, body=None):
            nonlocal usage_calls
            result = original(path, body)
            if path == "usage":
                usage_calls += 1
                if usage_calls == 2:
                    result["rate_limit"]["secondary_window"]["reset_at"] += 100
            return result

        api.request = changed
        with self.assertRaisesRegex(ar.Refusal, "window changed"):
            self.check(api)
        self.assertFalse(api.posted)
        self.assertEqual(self.saved, [])

    def test_redirect_refused(self):
        with self.assertRaises(ar.Refusal):
            ar.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.com")


if __name__ == "__main__":
    unittest.main()
