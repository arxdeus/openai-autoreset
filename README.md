# macOS Codex automatic banked reset

**Implemented and statically reviewed only. Not executed, imported, installed, or enabled. No authenticated API calls were made during development.**

`autoreset.py` spends an existing Codex reset credit only when the general **weekly remaining percentage is between 0% and 1%, inclusive**. Above 1% it prints `WARNING` to stderr and exits without resetting. There is no threshold override. It does not buy credits, rotate accounts, or reset passwords.

## Important limitations

This uses **undocumented ChatGPT backend endpoints**, identified in public open-source implementations, not a supported OpenAI reset API. See [RESEARCH.md](RESEARCH.md). API and response compatibility have not been live-tested. Unknown schemas and uncertain results stop automation rather than risk another reset.

The saved `ChatGPT.html` and its companion assets were searched as inert text. They did not contain the reset endpoint, `redeem_request_id`, or the reset button label. The saved page was not executed and its private contents are not included here.

## Requirements

- macOS and Python 3.10 or newer. No third-party packages.
- An existing ChatGPT-authenticated Codex `auth.json` containing `tokens.access_token` and `tokens.account_id`. Keychain-only credentials are not supported.
- At least one eligible banked reset. API-key billing is not supported.
- Obtain the intended `tokens.account_id` locally and keep it private. Never paste tokens into commands, logs, or this repository.

## Commands for your later use, NOT run during implementation

Read-only check (this still makes authenticated GET requests when **you** run it):

```sh
python3 autoreset.py --account-id 'YOUR_ACCOUNT_ID' --dry-run
```

Default auth file: `$CODEX_HOME/auth.json`, otherwise `~/.codex/auth.json`. Override with `--auth '/absolute/path/auth.json'`. OAuth tokens are read only, never refreshed or rewritten.

**The next command can consume a real reset immediately. Run only when you decide to activate it:**

```sh
python3 autoreset.py --account-id 'YOUR_ACCOUNT_ID' --execute --max-resets 1
```

`--max-resets` caps total attempts recorded in this account's journal across all invocations, not per run. Default: one. Increase deliberately for longer automation. A failed or uncertain attempt also counts and blocks further attempts until manually reconciled. A six-hour cooldown applies after an attempt.

Exit 0: read-only eligibility reported or reset verified. Exit 2: warning, ineligible condition, budget/cooldown, lock contention, or error. Exit 130: interruption. Threshold warnings go to stderr, not a macOS notification.

## Automatic polling with launchd

`launchd/com.local.openai-autoreset.plist.example` is an **uninstalled, disabled-by-default, dry-run template** for checking every five minutes while logged in. It does not wake a sleeping Mac.

To use later, replace every placeholder with an absolute path or your account ID. Use the actual Python 3.10+ binary path, not a shell alias. `launchd` does not expand `~`, `$HOME`, or shell expressions. If using a nondefault Codex home, add `--auth` and its absolute auth file path. Ensure log parent directories exist. Keep configuration and logs private.

For live mode, deliberately replace `--dry-run` with `--execute`, set your total `--max-resets` budget, and change `Disabled` to false. Copy the reviewed file to `~/Library/LaunchAgents/com.local.openai-autoreset.plist`. Installing/enabling is intentionally left to you, and was **not done** here.

Future enable command, after reviewing the configuration:

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.local.openai-autoreset.plist"
```

Stop before any maintenance or account changes:

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.local.openai-autoreset.plist"
```

## Safety design

1. Read the window whose `limit_window_seconds` is exactly 604800. Do not mistake session or model-specific usage for the weekly limit.
2. Compute `remaining = 100 - used_percent` without rounding. Permit only `0 <= remaining <= 1`. For example, 98.99% used means 1.01% remaining and is refused.
3. Require a pinned account ID and an available `codex_rate_limits` credit with a known expiry more than one minute away. Select earliest expiry first.
4. Refuse within five minutes of natural weekly reset. Re-read inventory and weekly usage immediately before spending. Refuse if the weekly boundary changes or final preflight becomes stale.
5. Acquire an OS file lock and durably persist the selected credit and unique request ID **before** the POST. The journal is account-scoped under `~/Library/Application Support/openai-autoreset/`.
6. Send at most one POST per invocation. Never retry it, even on timeout, HTTP 429/500, invalid JSON, interruption, or uncertain success. Any unresolved intent blocks later live invocations.
7. Verify both recovered weekly quota and explicit `consumed` status for the selected credit. Unrecognized status, disappearance, or delayed consistency leaves the journal pending. This conservative rule can require manual reconciliation after a successful reset.
8. Fixed HTTPS host, normal certificate validation, redirects refused, inherited proxies disabled, bounded responses, no secret logging. No browser automation, credential extraction from saved HTML, account switching, or purchases.

The client cannot make the usage check and redemption atomic on OpenAI's server. Another app, device, or manual reset could race the final check. **Do not run another reset redeemer concurrently.** Server-side percentages may also be rounded; the script uses the value actually returned, not the dashboard's display text. No guarantee of undisclosed backend precision is possible.

Do not delete the state directory to bypass a pending attempt or budget. Stop launchd and inspect the official usage dashboard and credit history first. For a known-completed pending attempt, a knowledgeable operator may preserve its IDs/timestamp and change only its `status` to `verified`. There is deliberately no automatic clear/retry command. A truly uncertain outcome should remain blocked. Back up the journal before editing.

## Review and tests

[REVIEW.md](REVIEW.md) records static checks and remaining limitations. `tests/test_autoreset.py` contains mock-only tests for future authorized execution. **Tests were authored but not run**, and the script was not imported even for testing, per the request. Syntax was checked by parsing source text only.
