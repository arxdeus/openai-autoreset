# macOS Codex automatic banked reset

**Implemented and statically reviewed only. Not executed, imported, installed, or enabled. No authenticated API calls were made during development.**

`autoreset.py` spends an existing Codex reset credit only when the general **weekly remaining percentage is between 0% and 1%, inclusive**. Above 1% it prints `WARNING` to stderr and exits without resetting. There is no threshold override. It does not buy credits, rotate accounts, or reset passwords.

## Important limitations

This uses **undocumented ChatGPT backend endpoints**, identified in public open-source implementations, not a supported OpenAI reset API. See [RESEARCH.md](RESEARCH.md). API and response compatibility have not been live-tested. Unknown schemas and uncertain results stop automation rather than risk another reset.

The saved `ChatGPT.html` and its companion assets were searched as inert text. They did not contain the reset endpoint, `redeem_request_id`, or the reset button label. The saved page was not executed and its private contents are not included here.

## Requirements

- macOS and Python 3.10 or newer. No third-party packages.
- An existing ChatGPT-authenticated Codex store at `~/.codex/auth.json`, containing `tokens.access_token` and `tokens.account_id`. Explicit `--auth` overrides also support Jcode `openai_accounts[]` entries and legacy flat OAuth stores. Keychain-only credentials are not supported.
- At least one eligible banked reset. API-key billing is not supported.
- Obtain the intended `tokens.account_id` from your Codex auth file locally and keep it private. Never paste tokens into commands, logs, or this repository.

## Commands for your later use, NOT run during implementation

Read-only check (this still makes authenticated GET requests when **you** run it):

```sh
python3 autoreset.py --account-id 'YOUR_ACCOUNT_ID' --dry-run
```

Default auth file: `~/.codex/auth.json`. Override with `--auth '/absolute/path/auth.json'` to use another supported OAuth store. For a custom `CODEX_HOME`, pass its auth file explicitly. OAuth tokens are read only, never refreshed or rewritten. In polling mode the script reloads the file each iteration to see updates made by Codex/Jcode themselves.

Optional Jcode auth example:

```sh
python3 autoreset.py --auth "$HOME/.jcode/openai-auth.json" --account-id 'YOUR_ACCOUNT_ID' --dry-run
```

With a Jcode store, `--account-id` must match exactly one entry in `openai_accounts[]`; missing or duplicate matches are refused. Jcode's `active_openai_account` never overrides the pinned account.

**The next command can consume a real reset immediately. Run only when you decide to activate it:**

```sh
python3 autoreset.py --account-id 'YOUR_ACCOUNT_ID' --execute --max-resets 1
```

`--max-resets` caps total attempts recorded in this account's journal across all invocations, not per run or per minute. Default: one. Increase deliberately for longer automation. A failed or uncertain submitted attempt also counts and blocks further attempts until manually reconciled. Known-unsent stale preflights are refused before journaling, or their just-written intent is durably cancelled under the same lock. Failed cancellation persistence leaves the on-disk pending intent blocking. A six-hour cooldown applies after an attempt.

Exit 0: read-only eligibility reported or reset verified. Exit 2: warning, ineligible condition, budget/cooldown, lock contention, or error. Exit 130: interruption. Threshold warnings go to stderr, not a macOS notification.

## Detached background mode, one check every minute

The following commands are examples for your later use. **No background process was started during implementation.**

Read-only background monitor using the default Codex auth path:

```sh
python3 autoreset.py --background --account-id 'YOUR_ACCOUNT_ID' --dry-run
```

**Live background automation can spend a reset. Explicitly opt in:**

```sh
python3 autoreset.py --background --account-id 'YOUR_ACCOUNT_ID' --execute --max-resets 1
```

Optional Jcode path for live background mode:

```sh
python3 autoreset.py --background --auth "$HOME/.jcode/openai-auth.json" --account-id 'YOUR_ACCOUNT_ID' --execute --max-resets 1
```

- `--background` detaches a worker, prints its PID and log path, and returns after the worker acquires its singleton lock. Readiness confirms process startup, not successful API authentication. Inspect the log for actual polling results.
- First check runs immediately, then checks start approximately every 60 seconds. Slow operations never overlap. At more than 1% weekly remaining, each iteration makes only a usage GET and logs a warning. At 0%-1%, eligibility, freshness and optional reset verification can require additional requests.
- The worker stays read-only unless `--execute` is supplied. Account pin, hard 0%-1% threshold, total attempt budget, cooldown and unresolved-POST protection apply across all iterations. Increasing `--max-resets` is a deliberate lifetime budget increase, not a per-minute allowance.
- Only one foreground/background polling worker per OS user is allowed. A second worker fails its startup lock. One-shot checks still use the separate reset lock. Do not run other redeemers or the launchd scheduler alongside this worker.
- Logs append privately to `~/Library/Application Support/openai-autoreset/background.log` (0600). Tokens and raw API response bodies are not logged. Logs are not automatically rotated. Stop the monitor before archiving/truncating a growing log, and preserve account journals.
- Closing the launching terminal does not stop the detached worker. Reboot/log-out may stop it; it is not an installed login service, does not auto-restart, and does not wake a sleeping Mac. Use the optional launchd template instead for login scheduling.
- To see polling without detaching, use `--foreground` instead of `--background`. Stop it with Ctrl+C.

To stop the detached worker, use the PID printed at startup. **First verify it still belongs to this script**, since PIDs can be reused:

```sh
ps -p YOUR_PID -o pid=,command=
kill -TERM YOUR_PID
```

SIGTERM/Ctrl+C prevents a new reset once observed by the preflight checks, and waits for an in-flight request/verification to finish before exit. It cannot undo a request already sent. A tiny race between the last check and submission is unavoidable. Unexpected interruption or uncertain submission retains a blocking journal, never an automatic POST retry.

## Automatic polling with launchd

`launchd/com.local.openai-autoreset.plist.example` is an **uninstalled, disabled-by-default, dry-run template** for checking every minute while logged in. It does not wake a sleeping Mac. This is an alternative to `--background`, not additional required setup. Do not use both schedulers, and do not add `--background` or `--foreground` to the launchd template: launchd should run one check per interval.

To use later, replace every placeholder with an absolute path or your account ID. Use the actual Python 3.10+ binary path, not a shell alias. `launchd` does not expand `~`, `$HOME`, or shell expressions. The script itself resolves its default Codex auth path from your home directory. For another OAuth store, add `--auth` and its absolute file path. Ensure log parent directories exist. Keep configuration and logs private.

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

Do not delete the state directory to bypass a pending attempt or budget. Stop your background monitor or launchd job and inspect the official usage dashboard and credit history first. For a known-completed pending attempt, a knowledgeable operator may preserve its IDs/timestamp and change only its `status` to `verified`. There is deliberately no automatic clear/retry command. A truly uncertain outcome should remain blocked. Back up the journal before editing.

## Review and tests

[REVIEW.md](REVIEW.md) records static checks and remaining limitations. `tests/test_autoreset.py` contains mock-only tests for future authorized execution. **Tests were authored but not run**, and the script was not imported even for testing, per the request. Syntax was checked by parsing source text only.
