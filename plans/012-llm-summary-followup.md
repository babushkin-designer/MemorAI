# Plan 012 — Manual LLM summary + follow-up for calls

Status: DONE — implemented & smoke-tested 2026-07-09 (33 tests green; real
summary generated via Bluesminds/gpt-5.5, 182 in / 172 out tokens)
Priority: P2 · Effort: M · Depends on: Recent Calls menu (shipped 2026-07-09)

Methodology: plan-big / execute-small. Each step below is independently
buildable + verifiable. Do them in order; `swift build` + `swift test` must be
green after each. Do not proceed to the next step on a red build.

## Goal

Two manual menu actions on a recorded call:
- **Summarize** → `call_<tag>_summary.md` (top-level overview + decisions +
  action items). Skimmable; also used later for building product cases.
- **Draft follow-up** → `call_<tag>_followup.md` (a message the user sends to a
  freelance client). Asks for the other party's real name first and writes with
  real names (Я=Илья, Собеседник=<name>) — never "Персона 1/2".

Both are OFF by default / manual only (no auto-run). CallHistory already
surfaces `_summary.md` / `_followup.md`, so the menu wiring is mostly done.

## Backend

OpenAI-compatible Chat Completions. Two providers, user-selectable:
- **Bluesminds** (default): `https://api.bluesminds.com/v1/chat/completions`,
  key `bluesminds-api-key` (Keychain), free tokens via data-sharing. Default
  model **`gpt-5.5`** (smoke-tested 2026-07-09, correct RU). NOTE: `claude-*`
  models appear in public pricing but are NOT priced/enabled on this key
  ("has not been priced by the administrator"); deepseek-v4-* returned empty.
  Usable ids from authenticated /v1/models: gpt-5.5, gpt-5.2-chat, gpt-4o,
  gpt-4o-mini, glm-5.2, kimi-*, qwen*.
- **OpenAI direct**: `https://api.openai.com/v1/chat/completions`, key
  `openai-api-key`. Free daily tokens via data-sharing (≈1M/day gpt-5 class,
  250k on tiers 1-2) — SHARED with the pump-dump/polymarket bots' key.

Keys come from **macOS Keychain** (generic passwords `bluesminds-api-key` /
`openai-api-key`, account = current user), migrated 2026-07-09. No .env in the
app. Read via Security framework (SecItemCopyMatching).

### Quota guardrail (hard requirement — from polymarket OPS.md + program terms)

Program fact (help.openai.com/articles/10306912, confirmed 2026-07-09): when
the free daily allowance (1M/day large models, 250k on tiers 1-2) is exhausted,
overage is **silently billed at normal rates** — no error is returned. A
`429 insufficient_quota` only appears once the paid balance is also gone.
Therefore:
- **Default provider = Bluesminds** (separate key, not shared with the trading
  bots; zero OpenAI free-quota usage).
- OpenAI direct is a fallback only: hard `max_tokens` cap on every request, and
  log `usage.prompt_tokens/completion_tokens` from each response to memorai.log.
- On HTTP 429 with `error.code == "insufficient_quota"`: STOP, alert ("tokens
  exhausted — resume after billing/usage action"), do NOT retry. Retry/backoff
  only for transient 5xx / network / timeout, capped (2 tries).

## Steps

### 012.1 — Keychain helper
`AutoRec/Keychain.swift`: `Keychain.read(service:) -> String?` via
SecItemCopyMatching (kSecClassGenericPassword, account = NSUserName()).
Verify: unit test reads a temp item added in the test (or skip if unavailable).

### 012.2 — LLM settings
SettingsManager: `llmProvider` ("bluesminds"|"openai", default bluesminds),
`llmModel` (default "claude-sonnet"). Menu: a "Summarization Model" submenu
under Dictation-ish section is optional; defaults are fine for v1.

### 012.3 — LLMClient
`AutoRec/LLMClient.swift`: synchronous (background-queue) `complete(system:user:)
-> Result<String, LLMError>`. Builds the provider URL, reads the Keychain key,
POSTs chat/completions (temperature 0), parses `choices[0].message.content`,
maps 429/insufficient_quota → `.quotaExhausted`, other non-200 → `.http(code)`,
network → `.transport`. Bounded retry (2) on transport/5xx only. Pure helpers
(URL for provider, request-body builder, response/​error parser) split out and
unit-tested; the actual network call is thin.
Verify: unit tests on the pure helpers + one real smoke call to Bluesminds with
a 3-token prompt (manual, gated behind an env flag so `swift test` stays
offline).

### 012.4 — Prompts
`AutoRec/CallLLM.swift`: `summaryPrompt(transcript:)` and
`followupPrompt(transcript:, otherName:)`. RU output. Summary = overview,
decisions, action items with owners, open questions. Follow-up = short client
message, real names, action items/next steps, polite sign-off from Илья.
Reads the `_transcript.txt`; writes `_summary.md` / `_followup.md` atomically.
Verify: unit test that prompts embed the transcript and the substituted name.

### 012.5 — Menu wiring
AppDelegate Recent Calls per-call submenu: add "Summarize" and "Draft
follow-up" items (enabled only when `_transcript.txt` exists). Follow-up first
shows an NSAlert with a text field for the other party's name (optional).
Runs on a background queue; on success reveals/opens the produced file; on
`.quotaExhausted` shows the stop alert; on other errors shows a short error.
Verify: build + manual click-through after install.

### 012.6 — Docs / memory
Update CLAUDE.md (Keychain-based LLM, quota rule) and this plan's status.

## STOP conditions
- Never auto-retry on `insufficient_quota`.
- Never write LLM output over the transcript; only `_summary.md`/`_followup.md`.
- Never print or log the API key.
- Keep the network call out of `swift test` (offline CI).
