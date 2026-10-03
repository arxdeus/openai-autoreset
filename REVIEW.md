# Static review

## Scope and outcome

Initial implementation and independent source review only. The reset script was **not run or imported**, including in dry-run mode. Mock tests were **not run**. No credentials were read during the initial implementation/review, no authenticated endpoints were called, and no launchd job was installed or activated. The subsequent user-requested Jcode auth adaptation inspected the local auth store's field names and types only, without printing credential or identity values.

Source was parsed with Python `ast.parse` and the launchd template with `plistlib.loads`. These operate on text/data and do not execute project code. Static parsing caught a text-edit collision during development, which was repaired before final checks. Parsing is not a runtime test.

## Requirement-to-evidence map

| Requirement | Source evidence | Validation boundary |
| --- | --- | --- |
| Only 0%-1% weekly remaining | `weekly` selects exactly one 604800-second general window. `require_threshold` enforces inclusive 0..1 without rounding. Called on initial read, final read, and immediately before POST. | Source trace and authored boundary tests, not executed. |
| Warn above 1% | `require_threshold` raises a message starting `WARNING`, caught and printed to stderr at CLI entry. No POST is reachable afterward. | Source trace. |
| Read-only by default | Mutually exclusive `--execute`/`--dry-run`. Default branches out before state persistence or POST. | Source trace. |
| Automate on macOS | Single-run checker plus five-minute launchd example. Example has `Disabled=true`, `RunAtLoad=false`, and `--dry-run`. | Plist parsed and safety settings asserted. Not installed. |
| Preserve finite resets | Lifetime attempt budget defaults to one. Six-hour cooldown, earliest-expiry eligible credit, five-minute natural-reset exclusion. | Source trace. |
| Avoid duplicate consumption | Lock, durable pre-POST intent, unique request ID, no POST retry, pending intent blocks future live invocations. | Source trace. Crash/power-loss behavior not tested. |
| Reject changed/stale state | Re-fetch inventory and weekly usage, identical reset boundary required, final GET plus persistence must finish within five seconds. | Source trace and authored tests, not executed. |
| Protect credentials | Pinned account, fixed host, no redirects, no inherited proxy, no response-body logging. Auth only read when user later runs the CLI. | Source trace. |
| Research similar implementations | GitHub redemption source, CodexBar docs, GitLab inventory script, official OpenAI pricing docs, and saved HTML inspection. | Public/source evidence linked in RESEARCH.md. No live compatibility claim. |

## Findings addressed

- Replaced journal `assert` checks with explicit validation so `python -O` cannot remove them.
- Final preflight timing now includes the GET's duration, rather than starting after it returns.
- Recheck natural reset proximity after durable journal publication.
- Numeric validator rejects non-numbers, booleans, NaN/infinity and integer conversion overflow.
- Display percentages without `:g` rounding that could misleadingly print a value slightly above 1 as `1`.
- Request a macOS `F_FULLFSYNC` before publication and again after file replacement/directory `fsync`. Any failure before POST prevents consumption.
- Tests use `ExitStack`, not a Python 3.11-only test helper, to match Python 3.10 requirements.

## Authored, unexecuted tests

15 mock-only test methods cover boundary values, invalid numbers, session-versus-weekly selection, missing/duplicate/expired windows, default dry-run behavior, final threshold refusal, intent-before-POST ordering, uncertain POST restart protection, persistence failure, unverified outcomes, budget/cooldown, inventory mismatch, stale final reads, changed weekly windows and redirects. They do not establish passing runtime behavior until a future authorized run.

## Remaining limitations

- Private API behavior and schema are not guaranteed by OpenAI documentation. Exact account compatibility remains unverified. In particular, post-reset verification expects the chosen credit to remain listed with `status=consumed`. Any different representation leaves a pending intent and blocks further resets.
- The server cannot be locked by this client. Another device or manual redeemer can race the final GET/POST. Server rounding or eventual consistency cannot be ruled out. Do not run another reset redeemer concurrently.
- The local journal must be retained. Deleting it, restoring an old backup, or using a different OS user defeats local historical duplicate/budget protection. No automatic recovery from missing historical state is claimed.
- macOS filesystem, device-cache durability, `flock`, permissions, launchd execution and live OAuth compatibility were not exercised. Unsupported flush behavior stops before sending a reset, but filesystem/hardware guarantees require separate runtime verification.
- The final request can be accepted remotely even if the response is lost. Such attempts remain pending, consume the local budget, and require manual inspection. This favors preserving remaining resets over unattended recovery.
- A successful reset whose confirmation is delayed can remain pending. There is intentionally no automatic retry or journal-clearing command.

**No resets were consumed by this work.**

## Jcode auth-path adaptation

- Default is now `~/.jcode/openai-auth.json`, not `$CODEX_HOME/auth.json`.
- Inspected field names/types identify `openai_accounts[]` entries with `access_token` and `account_id`. No auth file contents or values were copied to the repository.
- The loader requires exactly one entry matching explicit `--account-id`. It ignores `active_openai_account` for reset selection and refuses missing, duplicate, malformed, or tokenless matches.
- Explicit `--auth` overrides retain Codex nested-token and flat OAuth compatibility. Credential files remain read-only.
- Added five synthetic auth-format test methods, bringing the total to 20. All remain unexecuted. Source-only syntax checks cover the adaptation. Threshold, POST, and journal logic were unchanged.
- The follow-up review's known-unsent stale-preflight lockout finding remains unresolved in this path-only change.
