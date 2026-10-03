# Research, 2026-10-03 UTC

## Official OpenAI documentation

- https://developers.openai.com/codex/pricing.md was retrieved and read. It identifies https://chatgpt.com/codex/settings/usage and Codex `/status` as usage sources, describes shared usage and weekly limits, and describes purchased credits/API billing as ways to continue. No supported reset-credit redemption API contract was found in this document. Paid usage credits are not the same as banked reset credits.
- https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan was attempted but returned HTTP 403. We do not claim to have read its contents.
- Public search via DuckDuckGo was challenged. Bing returned no results for the attempted query. Google returned an unhelpful access page. A browser research tab could not be created due to a bridge error. Public repository APIs and raw sources were accessible.

## Similar implementations

### Codex Account Switcher, GitHub: closest redemption reference

https://github.com/lordydord/Codex-Account-Switcher

Inspected source pinned to commit `955e1c854a96b8ef9a70aea5662c375d6cfbd2e0`:
https://github.com/lordydord/Codex-Account-Switcher/blob/955e1c854a96b8ef9a70aea5662c375d6cfbd2e0/Sources/main.swift

The `fetchResetCredits` and `consumeResetCredit` functions, approximately lines 3317-3398, implement:

```text
GET  https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
POST https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume
Authorization: Bearer <Codex OAuth access token>
ChatGPT-Account-ID: <account id>
OpenAI-Beta: codex-1
originator: Codex Desktop
Content-Type: application/json  (POST)

{"credit_id":"<selected credit>","redeem_request_id":"<UUID>"}
```

Its UI requires manual confirmation, and its POST explicitly disables retries. This is an existing macOS redemption implementation, but we did not establish that it supports the exact requested automatic 0%-1% weekly trigger. We used the observed protocol, not copied implementation code. No release binary or installer was executed.

### CodexBar, GitHub: mature usage and reset-inventory monitor

https://github.com/steipete/CodexBar
https://raw.githubusercontent.com/steipete/CodexBar/main/docs/codex.md

Documentation describes OAuth GET `/backend-api/wham/usage`, account-scoped reset-credit inventory GET, and Codex CLI RPC alternatives. It explicitly states that CodexBar does not redeem or modify reset credits. It also discusses delayed/stale usage observations and account-scoping safeguards. Useful monitoring reference, not a ready automatic redeemer.

### codex-reset-credits, GitLab: read-only implementation

https://gitlab.com/aa22396584/codex-reset-credits

Read its tree and `.codex/skills/codex-reset-credits/scripts/check_reset_credits.py` through the GitLab API. Confirms the OAuth inventory endpoint, account header, `available_count`, `credits`, `status`, and ISO timestamp expirations. Explicitly read-only, not a redeemer. A guessed GitHub mirror URL returned 404 and is not used as evidence.

### Other search results, not fully audited

GitHub repository search for `codex reset weekly` and `codex auto reset in:name,description` also surfaced:
- https://github.com/ofilis/codex-ha-bridge: publishes usage and reset times to Home Assistant.
- https://github.com/saaranshM/unsnooze: resumes work after natural usage-window resets. Different from spending a banked reset.

GitLab project search for `codex reset` also surfaced:
- https://gitlab.com/hafiz-dhanani/codex-usage: Mac menu-bar usage and banked-reset visibility.
- https://gitlab.com/aigoodbro/AgentHub-AiGoodBro: usage, reset messages and account switching.

Search results alone are not proof of redemption safety. None of these additional candidates was installed, executed, or fully reviewed.

## Supplied saved page

`/Users/mind/Downloads/ChatGPT.html` and its 31 companion entries were inspected as text only. Searches did not locate `rate-limit-reset-credits`, `redeem_request_id`, `codex_rate_limits`, or `Use reset`. The page did not independently verify the button's network request. Its private embedded content and assets were not copied into this repository or uploaded to any service.

## Confidence boundary

The reset request method/path/body are supported by public source, not by an official public API specification or live capture from this account. The strict weekly schema and explicit post-reset `consumed` status requirement are fail-closed assumptions that may need adjustment after an authorized read-only compatibility check. Unknown responses halt rather than guess. No live account requests or reset operations were performed.
