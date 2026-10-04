"""Offline safety tests using synthetic credentials and mocked external boundaries.

Run explicitly from the repository root:
    python3 -m unittest discover -s tests -v
"""
import copy
import json
from contextlib import ExitStack, nullcontext
from datetime import datetime, timezone
from pathlib import Path
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

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

    def test_codex_default_path(self):
        self.assertEqual(ar.DEFAULT_AUTH, Path.home() / ".codex/auth.json")

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

    def test_uncapped_mode_permits_another_verified_reset_cycle(self):
        self.state["attempts"] = [
            {"status": "verified", "time": NOW - 30000 - i,
             "credit_id": f"older-{i}", "request_id": f"older-request-{i}"}
            for i in range(3)
        ]
        api = FakeAPI()
        self.check(api, maximum=None)
        self.assertTrue(api.posted)
        self.assertEqual(len(self.state["attempts"]), 4)
        self.assertEqual(self.state["attempts"][-1]["status"], "verified")

    def test_uncapped_mode_still_blocks_pending_attempt(self):
        self.state["attempts"] = [{"status": "pending", "time": NOW - 30000,
                                   "credit_id": "older", "request_id": "older-request"}]
        api = FakeAPI()
        with self.assertRaisesRegex(ar.Refusal, "Unresolved"):
            self.check(api, maximum=None)
        self.assertFalse(api.posted)

    def test_uncapped_mode_still_enforces_cooldown(self):
        self.state["attempts"] = [{"status": "verified", "time": NOW - 100,
                                   "credit_id": "older", "request_id": "older-request"}]
        api = FakeAPI()
        with self.assertRaisesRegex(ar.Refusal, "cooldown"):
            self.check(api, maximum=None)
        self.assertFalse(api.posted)

    def test_uncapped_mode_still_requires_available_credits(self):
        api = FakeAPI()
        original = api.request

        def no_credits(path, body=None):
            if path == ar.CREDITS:
                return {"available_count": 0, "credits": []}
            return original(path, body)

        api.request = no_credits
        with self.assertRaisesRegex(ar.Refusal, "No eligible"):
            self.check(api, maximum=None)
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
        self.assertEqual(self.saved, [])
        self.assertEqual(self.state["attempts"], [])

    def test_slow_journal_cancels_only_unsent_intent(self):
        api = FakeAPI()
        with patch.object(ar.time, "monotonic", side_effect=(0, 0, 6)):
            with self.assertRaisesRegex(ar.Refusal, "unsent intent cancelled"):
                self.check(api)
        self.assertFalse(api.posted)
        self.assertEqual(self.saved[0]["attempts"][0]["status"], "pending")
        self.assertEqual(self.saved[-1]["attempts"], [])

    def test_stopping_before_poll_makes_no_requests(self):
        api = FakeAPI()
        stop = Mock()
        stop.is_set.return_value = True
        with self.assertRaisesRegex(ar.Refusal, "stopping"):
            ar.check(api, True, 1, self.state, Path("never-written.json"), stop=stop)
        self.assertEqual(api.calls, [])

    def test_stop_during_journal_cancels_unsent_intent(self):
        api = FakeAPI()
        stop = Mock()
        stop.is_set.side_effect = (False, False, True)
        with self.assertRaisesRegex(ar.Refusal, "unsent intent cancelled"):
            ar.check(api, True, 1, self.state, Path("never-written.json"), stop=stop)
        self.assertFalse(api.posted)
        self.assertEqual(self.saved[-1]["attempts"], [])

    def test_sleep_or_backwards_clock_marks_preflight_stale(self):
        for wall in (NOW + 60, NOW - 1):
            with patch.object(ar.time, "time", return_value=wall):
                self.assertTrue(ar.preflight_stale(42, NOW, NOW + 10000))

    def test_failed_rollback_preserves_persisted_pending_intent(self):
        api = FakeAPI()
        snapshots = []

        def persistence(path, state):
            if snapshots:
                raise OSError("Synthetic rollback failure")
            snapshots.append(copy.deepcopy(state))

        with patch.object(ar, "save_state", side_effect=persistence), \
                patch.object(ar.time, "monotonic", side_effect=(0, 0, 6)):
            with self.assertRaises(OSError):
                self.check(api)
        self.assertFalse(api.posted)
        self.assertEqual(snapshots[0]["attempts"][0]["status"], "pending")

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


class BackgroundTests(unittest.TestCase):
    def setUp(self):
        stack = ExitStack()
        self.addCleanup(stack.close)
        self.enter_context = stack.enter_context
        self.enter_context(patch.object(ar, "load_auth", side_effect=AssertionError("No real credentials")))
        self.enter_context(patch.object(ar, "API", side_effect=AssertionError("No real network")))
        self.enter_context(patch.object(ar.subprocess, "Popen", side_effect=AssertionError("No real processes")))
        self.args = SimpleNamespace(account_id="synthetic-account", auth=ar.DEFAULT_AUTH,
                                    execute=False, max_resets=1)

    def test_child_command_keeps_auth_budget_and_read_only_default(self):
        command = ar.background_command(self.args, 11)
        self.assertIn("--foreground", command)
        self.assertNotIn("--background", command)
        self.assertIn("--dry-run", command)
        self.assertNotIn("--execute", command)
        self.assertEqual(command[command.index("--auth") + 1], str(ar.DEFAULT_AUTH.absolute()))
        self.assertEqual(command[command.index("--max-resets") + 1], "1")

    def test_child_live_mode_requires_explicit_execute(self):
        self.args.execute = True
        self.args.auth = Path.home() / ".jcode/openai-auth.json"
        command = ar.background_command(self.args, 11)
        self.assertIn("--execute", command)
        self.assertNotIn("--dry-run", command)
        self.assertEqual(command[command.index("--auth") + 1], str(self.args.auth.absolute()))

    def test_uncapped_child_omits_budget_argument(self):
        self.args.max_resets = None
        command = ar.background_command(self.args, 11)
        self.assertNotIn("--max-resets", command)
        self.assertNotIn("None", command)
        self.assertIn("--dry-run", command)

    def test_poll_warning_continues_and_waits_to_one_minute_boundary(self):
        stop = Mock()
        stop.is_set.side_effect = (False, False, True)
        with patch.object(ar.threading, "Event", return_value=stop), \
                patch.object(ar, "locked_state", return_value=nullcontext()) as lock, \
                patch.object(ar, "load_auth", return_value="synthetic-token"), \
                patch.object(ar.signal, "signal"), \
                patch.object(ar.time, "monotonic", side_effect=(0, 4, 60, 62)), \
                patch.object(ar, "run_once", side_effect=ar.Refusal("WARNING: above 1%")) as run:
            ar.poll_forever(self.args)
        lock.assert_called_once_with("background.lock")
        self.assertEqual(run.call_count, 2)
        self.assertEqual([c.args[0] for c in stop.wait.call_args_list], [56, 58])

    def test_main_background_dispatch_does_not_enable_execute(self):
        argv = ["autoreset.py", "--background", "--account-id", "synthetic-account"]
        with patch.object(ar.sys, "argv", argv), patch.object(ar.sys, "platform", "darwin"), \
                patch.object(ar, "launch_background") as launch:
            ar.main()
        args = launch.call_args.args[0]
        self.assertFalse(args.execute)
        self.assertEqual(args.auth, ar.DEFAULT_AUTH)
        self.assertIsNone(args.max_resets)

    def test_explicit_background_budget_is_preserved(self):
        argv = ["autoreset.py", "--background", "--account-id", "synthetic-account", "--max-resets", "2"]
        with patch.object(ar.sys, "argv", argv), patch.object(ar.sys, "platform", "darwin"), \
                patch.object(ar, "launch_background") as launch:
            ar.main()
        self.assertEqual(launch.call_args.args[0].max_resets, 2)

    def test_invalid_explicit_background_budget_is_refused(self):
        for value in ("0", "-1", "101"):
            argv = ["autoreset.py", "--background", "--account-id", "synthetic-account",
                    "--max-resets", value]
            with self.subTest(value=value), patch.object(ar.sys, "argv", argv), \
                    patch.object(ar.sys, "platform", "darwin"), \
                    patch.object(ar, "launch_background") as launch:
                with self.assertRaises(ar.Refusal):
                    ar.main()
                launch.assert_not_called()

    def test_main_foreground_dispatch_does_not_spawn(self):
        argv = ["autoreset.py", "--foreground", "--account-id", "synthetic-account"]
        with patch.object(ar.sys, "argv", argv), patch.object(ar.sys, "platform", "darwin"), \
                patch.object(ar, "poll_forever") as poll, \
                patch.object(ar, "launch_background") as launch:
            ar.main()
        poll.assert_called_once()
        launch.assert_not_called()

    def fake_launch(self, response):
        child = Mock(pid=444)
        child.poll.return_value = None
        stack = ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.object(ar, "prepare_state_dir"))
        stack.enter_context(patch.object(ar.os, "open", return_value=10))
        stack.enter_context(patch.object(ar.os, "pipe", return_value=(11, 12)))
        stack.enter_context(patch.object(ar.os, "fstat", return_value=SimpleNamespace(
            st_mode=ar.stat.S_IFREG | 0o600, st_uid=123)))
        stack.enter_context(patch.object(ar.os, "getuid", return_value=123))
        stack.enter_context(patch.object(ar.os, "close"))
        stack.enter_context(patch.object(ar.select, "select", return_value=([11], [], [])))
        stack.enter_context(patch.object(ar.os, "read", return_value=response))
        spawn = stack.enter_context(patch.object(ar.subprocess, "Popen", return_value=child))
        return child, spawn

    def test_startup_handshake_reports_only_a_ready_detached_child(self):
        child, spawn = self.fake_launch(b"READY\n")
        ar.launch_background(self.args)
        spawn.assert_called_once()
        self.assertTrue(spawn.call_args.kwargs["start_new_session"])
        self.assertEqual(spawn.call_args.kwargs["pass_fds"], (12,))
        self.assertIn("--dry-run", spawn.call_args.args[0])
        child.terminate.assert_not_called()

    def test_startup_eof_cleans_up_without_automatic_retry(self):
        child, spawn = self.fake_launch(b"")
        with self.assertRaisesRegex(ar.Refusal, "did not start"):
            ar.launch_background(self.args)
        spawn.assert_called_once()
        child.terminate.assert_called_once()

    def test_duplicate_worker_never_polls(self):
        with patch.object(ar, "locked_state", side_effect=ar.Refusal("Already running")), \
                patch.object(ar, "run_once") as run:
            with self.assertRaisesRegex(ar.Refusal, "Already running"):
                ar.poll_forever(self.args)
        run.assert_not_called()

    def test_auth_symlink_path_is_not_resolved_for_child(self):
        self.args.auth = Path("synthetic-symlink-auth.json")
        with patch.object(Path, "resolve", return_value=Path("/synthetic/autoreset.py")):
            command = ar.background_command(self.args, 11)
        self.assertEqual(command[command.index("--auth") + 1], str(self.args.auth.absolute()))

    def test_invalid_local_auth_exits_before_readiness_or_poll(self):
        with patch.object(ar, "locked_state", return_value=nullcontext()), \
                patch.object(ar.signal, "signal"), \
                patch.object(ar.os, "write") as ready, \
                patch.object(ar.os, "close"), \
                patch.object(ar, "load_auth", side_effect=ar.Refusal("Invalid local auth")), \
                patch.object(ar, "run_once") as run:
            with self.assertRaisesRegex(ar.Refusal, "Invalid local auth"):
                ar.poll_forever(self.args, ready_fd=12)
        ready.assert_not_called()
        run.assert_not_called()

    def test_run_once_reloads_tokens_without_enabling_live_mode(self):
        with patch.object(ar, "load_auth", side_effect=("fake-first", "fake-refreshed")) as auth, \
                patch.object(ar, "API", return_value=Mock()) as api, \
                patch.object(ar, "check") as check:
            ar.run_once(self.args)
            ar.run_once(self.args)
        self.assertEqual(auth.call_count, 2)
        self.assertEqual([c.args[0] for c in api.call_args_list], ["fake-first", "fake-refreshed"])
        self.assertTrue(all(c.args[1] is False for c in check.call_args_list))


if __name__ == "__main__":
    unittest.main()
