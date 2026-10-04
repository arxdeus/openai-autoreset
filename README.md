# OpenAI Autoreset

**A lightweight macOS CLI that monitors Codex weekly usage and redeems your banked resets when you need them.**

[Quick start](#quick-start) · [Usage](#usage) · [Background mode](#background-mode) · [Safety](#safety) · [Troubleshooting](#troubleshooting)

- **One-minute monitoring:** run once, poll in your terminal, or detach into the background.
- **Strict reset threshold:** only reset at **0%–1% weekly remaining**, never above 1%.
- **Read-only by default:** spending a reset requires an explicit `--execute`.
- **No dependencies:** uses Python's standard library and your existing OAuth credentials.

> [!WARNING]
> This is an unofficial tool using undocumented ChatGPT backend endpoints. `--execute` can spend real reset credits. It does not buy credits, bypass usage limits, or guarantee compatibility with future OpenAI changes.

## Quick start

### Requirements

- macOS and **Python 3.10+**.
- An existing ChatGPT-authenticated Codex login stored in `~/.codex/auth.json`.
- Available **banked reset credits** for live resets. Purchased usage credits and API-key billing are different and are not supported.

Download this repository and open a terminal in its root. There are no packages to install.

**1. Find your account ID locally.** This prints only the account ID, not tokens, and makes no network request:

```sh
python3 -c 'import json; from pathlib import Path; print(json.loads((Path.home()/".codex/auth.json").read_text())["tokens"]["account_id"])'
```

**2. Check usage without spending a reset.** Replace `YOUR_ACCOUNT_ID` with that ID:

```sh
python3 autoreset.py --account-id 'YOUR_ACCOUNT_ID' --dry-run
```

**3. Opt into background resets when ready.** This checks immediately, then approximately once per minute:

```sh
python3 autoreset.py --background --account-id 'YOUR_ACCOUNT_ID' --execute
```

> [!IMPORTANT]
> Without `--max-resets`, there is **no lifetime attempt cap**. The monitor can repeat the reset-and-wait cycle while eligible credits remain, but the **six-hour cooldown from the recorded attempt**, 0%–1% threshold, and unresolved-attempt protection still apply. Add `--max-resets 1` if you want to permit only one lifetime attempt.

## Usage

| Option | Behavior |
| --- | --- |
| `--account-id ID` | Required. Pins all reads and resets to the intended OAuth account. |
| `--auth PATH` | Credential file. Defaults to `~/.codex/auth.json`. |
| `--dry-run` | Read-only usage/credit eligibility check, also the default. Makes authenticated GET requests but never requests a reset. |
| `--execute` | Allows a reset only when all safety checks pass. Mutually exclusive with `--dry-run`. |
| `--background` | Detaches a worker that polls every 60 seconds and prints its PID and log path. |
| `--foreground` | Polls every 60 seconds in the current terminal. Stop with Ctrl+C. Mutually exclusive with `--background`. |
| `--max-resets N` | Optional lifetime attempt cap, **1–100**, across runs for this account. Omit for no cap. |
| `--help` | Displays CLI help. |

Without either polling flag, the script checks once and exits. Background mode does **not** imply `--execute`.

Dry-run does not check journal-based pending attempts, cooldowns, or caps. Above 1% remaining, it warns without fetching credit inventory.

```sh
# Watch in your terminal without spending resets
python3 autoreset.py --foreground --account-id 'YOUR_ACCOUNT_ID'

# Allow at most one lifetime attempt while monitoring in the background
python3 autoreset.py --background --account-id 'YOUR_ACCOUNT_ID' --execute --max-resets 1
```

### Other credential stores

For a custom `CODEX_HOME`, pass its auth file explicitly with `--auth`. Keychain-only credentials are not supported.

To use [Jcode](https://github.com/1jehuang/jcode) credentials instead:

```sh
python3 autoreset.py --background --auth "$HOME/.jcode/openai-auth.json" --account-id 'YOUR_ACCOUNT_ID' --execute
```

Use the `account_id` from the intended Jcode `openai_accounts[]` entry. Exactly one entry must match; Jcode's active-account selection never overrides the pin. Codex nested-token and legacy flat OAuth stores are also supported. Credentials reload each polling cycle, but the tool never refreshes or rewrites them.

## Background mode

The detached worker survives closing its launching terminal. Startup confirmation means its lock and local configuration are valid, **not** that the API request succeeded. Read its log to confirm polling:

```sh
tail -f "$HOME/Library/Application Support/openai-autoreset/background.log"
```

Only one polling worker per OS user is allowed. Slow requests do not overlap; they can delay the next check. The worker does not wake a sleeping Mac, install a login service, or automatically restart after exit.

To stop it, use the PID printed at startup. **Verify the process before sending a signal**, since PIDs can be reused:

```sh
ps -p YOUR_PID -o pid=,command=
kill -TERM YOUR_PID
```

Stopping allows in-flight requests or verification to finish. It cannot undo a reset already submitted. Restart deliberately after changing options or updating the script; running workers do not reload code or CLI arguments.

<details>
<summary><strong>Alternative: schedule checks with launchd</strong></summary>

The [launchd template](launchd/com.local.openai-autoreset.plist.example) runs a single check every 60 seconds. It ships **disabled and read-only**.

1. Replace all placeholders with absolute paths and your account ID. Use a Python 3.10+ binary, not a shell alias. Create the log parent directory first.
2. Set `Disabled` to false. Keep `--dry-run` for monitoring, or deliberately replace it with `--execute` for live resets. Add an optional `--max-resets` cap if needed.
3. For another credential store, add `--auth` and its absolute path. `launchd` does not expand `~` or shell variables.
4. Copy it to `~/Library/LaunchAgents/com.local.openai-autoreset.plist`, then enable it:

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.local.openai-autoreset.plist"
```

To stop the job:

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.local.openai-autoreset.plist"
```

Choose **launchd or the built-in polling worker**, not both. Do not add `--background` or `--foreground` to the template: launchd already schedules one-shot checks.

</details>

## Safety

Before spending a reset, the tool:

1. Identifies the general seven-day window by its duration, not the session or model-specific limit. It calculates remaining percentage without client-side rounding and warns above 1%.
2. Requires an available `codex_rate_limits` credit with a known expiry more than one minute away, choosing the earliest expiry first. It refuses within five minutes of the natural weekly reset.
3. Rechecks inventory and weekly usage immediately before submission, requiring the same reset boundary and a preflight no more than five seconds old.
4. Acquires the reset lock and durably records a unique request ID and selected credit **before** the POST. Submitted POSTs are never automatically retried.
5. Checks recovered weekly quota and an explicit `consumed` credit status after three seconds. Uncertain results remain `pending` and block further live attempts, including after restart.

Account journals and the built-in background log live in `~/Library/Application Support/openai-autoreset/`. That directory is private (0700), and those generated files are private (0600). Foreground output goes to the terminal; launchd logs use the template's configured paths. Tokens and raw API bodies are not logged. Background logs are append-only without automatic rotation; stop the monitor before archiving a growing log and preserve its journals.

> [!CAUTION]
> Do not delete journals or restore stale copies to bypass a pending attempt, cooldown, or cap. Another device or manual reset can race the final usage check, and server rounding or delayed consistency cannot be ruled out. Do not run another reset redeemer concurrently.

## Troubleshooting

| Message or symptom | Meaning / next step |
| --- | --- |
| `WARNING: ... above 1%` | Expected behavior. Continue monitoring until weekly remaining is 0%–1%. |
| `Six-hour reset cooldown is active` | Fewer than six hours have elapsed since the recorded attempt. Removing `--max-resets` does not remove the cooldown. |
| `Configured lifetime reset-attempt budget reached` | An explicit cap has been reached, including previous runs. Omit or increase it deliberately, then restart. |
| `No eligible ... reset credit available` | No eligible, unexpired banked reset is available. The tool cannot create or buy one. |
| `Unresolved reset attempt` / `Reset outcome not verified` | Stop automation and inspect the [official usage dashboard](https://chatgpt.com/codex/settings/usage) and credit history. A reset may have succeeded even when verification failed. |
| HTTP 401/403 or unreadable credentials | Check the pinned account and file path. Reauthenticate through the credential-owning app if necessary. |
| Network error or HTTP 504 | Polling resumes usage reads on later intervals. An uncertain reset POST still remains blocked, not retried. |
| `Another reset checker or background monitor is running` | Avoid duplicate workers and simultaneous live checks. Verify the existing PID and log before stopping anything. |
| Background startup failure | Inspect `background.log` for credential, journal, permission, or lock errors. |

**Pending attempts need manual reconciliation.** The single verification check can be too early, or the backend may represent consumed credits differently. Omitting a cap does not fix that. After stopping automation, preserve and back up the journal; only mark the specific attempt `verified` if its completion has been independently confirmed. Otherwise leave it blocked. There is no automatic clear/retry command.

One-shot exit codes: **0** for a completed dry-run check or verified reset, **2** for a refusal/error, and **130** for interruption. A background launch returning 0 reports worker readiness; subsequent polling results are in the log.

## Development

The project consists of [the CLI](autoreset.py), [mock-only tests](tests/test_autoreset.py), and the optional launchd template. Run the offline test suite explicitly from the repository root:

```sh
python3 -m unittest discover -s tests -v
```

Tests cover threshold boundaries, account selection, journal safety, optional caps, credential reload, polling, and mocked process startup. They use synthetic credentials and mocked network/process boundaries; they do not establish live OpenAI API compatibility.

<details>
<summary><strong>API references and related implementations</strong></summary>

- [OpenAI Codex pricing and usage documentation](https://developers.openai.com/codex/pricing/): plan usage and the official dashboard, not a supported reset-redemption API contract.
- [Codex Account Switcher reset implementation](https://github.com/lordydord/Codex-Account-Switcher/blob/955e1c854a96b8ef9a70aea5662c375d6cfbd2e0/Sources/main.swift): reference for the private redemption protocol.
- [CodexBar provider documentation](https://github.com/steipete/CodexBar/blob/main/docs/codex.md): usage and reset-inventory monitoring, not redemption.
- [codex-reset-credits](https://gitlab.com/aa22396584/codex-reset-credits): a read-only reset-credit inventory tool.

</details>
