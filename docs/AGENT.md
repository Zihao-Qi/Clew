# Clew AI

Status: **design v2**, 2026-11-22. Replaces the 2026-11-08 plan (a bundled TypeScript
helper on pi-agent-core); see §11 for what changed and why. Builds on
[ARCHITECTURE.md](ARCHITECTURE.md). Not a chat and not a coding agent: small, optional
help that suggests, and you choose.

## 1. Principles

1. **Clew is complete without it.** Every feature works with AI off; each AI feature
   only adds a button or a line. Off by default.
2. **It never changes your data.** A job returns a suggestion; only your tap writes
   (Add, Add all). Swift enforces this: jobs have no access to the store's writer.
3. **No conversation.** No chat or text box. A job's input is built by Clew from what
   is already there.
4. **A friend, not a coach with a whistle.** Brief, encouraging, never pushy. Never
   compares you to anyone. No streaks, no guilt, no "you missed".
5. **Say less.** Short items, one line at most. Never paragraphs.
6. **Small core, clear seams** (borrowed from pi's design, *user* 2026-11-22): layers
   that each do one thing, a tiny prompt, only the input a job needs, typed output.
   A provider or a job is easy to add; nothing else is pluggable.

## 2. Layers

```
App (Clew.app)        Suggest button, sign-in, Keychain, Settings › AI, debug log
  │ uses
ClewAgent (SwiftPM)   Jobs: instructions + input snapshot → typed output → validated
  │ uses
ClewAI (SwiftPM)      Provider: one streaming request, cancellable; ChatGPT plan first
```

- **ClewAI** (Foundation only). `Provider` takes a request (instructions, input text,
  model, an optional JSON schema) and returns an `AsyncThrowingStream` of events:
  `text(String)`, `done(usage)`, `failed(ProviderError)`. Cancelling the task cancels
  the request. Providers: **ChatGPT plan** (§3) first; Apple's on-device model or an
  API key can follow behind the same protocol.
- **ClewAgent** (Foundation + ClewDomain + ClewAI; never ClewCore's writer, never the
  store). A `Job` has a name, its instructions (a few lines), an `Encodable` input
  snapshot, a `Decodable` output, and `validate(output, input) → Result`. One request,
  one answer, **no retry** (a retry spends the person's plan); on any failure the job
  returns nothing and the app shows its plain fallback. **No agent loop and no tools**:
  every planned job is one question and one answer. A loop is a layer to add only when
  a job must act (e.g. a Reader fetching a page).
- **App**: composes them, owns the credentials (Keychain), the Settings section and
  where each job's result appears.

Layering is enforced by SwiftPM targets, as for the rest of Clew (AGENTS.md rule 4).

## 3. Provider: the person's ChatGPT plan

OpenAI's **Sign in with ChatGPT** for open-source, locally run apps
(developers.openai.com/siwc/token-sharing-open-source; Clew's repo is public and it
runs on the Mac). Clew registers as itself ("Clew"); it does not borrow Codex's or
pi's login. **Spike 2026-11-22** (`CLEW_CHATGPT_SPIKE`, a debug build signed with
Clew's sandbox entitlements): signed in, plan permission granted, models listed, one
streamed answer in 3.0 s. No helper process, no JavaScript.

- **Sign-in**: the system browser, PKCE (S256), a loopback callback on
  `127.0.0.1:1455` (`/auth/callback`; Clew already has the network server
  entitlement). First sign-in uses `client_id=dynamic_agent_client` and
  `agent_name_hint=Clew`; the callback's issued client id (`oaiapp_…`) is kept and used
  from then on. `ext_agent_host_id` is a `urn:uuid:` chosen once per Mac. Scopes
  `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`,
  resource `https://api.openai.com/v1`. Plan use needs `chatgpt.tokens.use.direct` in
  the granted scopes; without it Clew keeps the sign-in and says AI is not available
  on this plan.
- **ID token**: signature checked against OpenAI's JWKS (from
  `auth.openai.com/.well-known/openid-configuration`), with issuer, audience (the issued
  client id), expiry and nonce.
- **Tokens** in the Keychain, never in files, logs or URLs. Access tokens last an hour;
  a refresh (`grant_type=refresh_token`, issued client id, resource) returns a new
  refresh token each time, saved together; refreshes are serialized. A refresh error
  of the `invalid_grant` family means signing in again. **Sign out** revokes the
  refresh token (revocation endpoint from the OpenID configuration) and clears it; the
  client id and host id stay.
- **Requests**: `POST https://api.openai.com/v1/responses`, `stream: true`,
  `store: false`, `instructions` for the job's text (no system messages), structured
  output (a JSON schema) when the model takes it. No `temperature`, `max_output_tokens`
  and the other fields the preview refuses. Success is `response.completed` only;
  `response.failed`, `response.incomplete` or a stream that just ends are failures.
- **Models**: `GET /v1/models`, items with `visibility == "list"`, shown by
  `display_name`, sent as `slug`. Default: the first listed; Settings › AI can choose.
- **Errors** (OpenAI's list): usage limit (`subscription_sharing_usage_limit_exceeded`)
  pauses AI and shows "Usage limit reached · Manage usage"; `…_unavailable` /
  503 retry later (not now: no retry within a job); not eligible, invalid user or a
  revoked sign-in end the sign-in with a plain message. Never loop through sign-in.
- **OpenAI's interface rules**: a **Continue with ChatGPT** button; once, on first use,
  "You're using your ChatGPT plan" with **Got it**; **Manage usage** links to
  chatgpt.com/settings/usage; "Usage limit reached" when it is.
- It is a **preview** at OpenAI: details may change. Everything above sits in ClewAI,
  so a change stays there.

## 4. Untrusted text

Text Clew did not get from the person's typing is untrusted: page titles fetched for
pasted links (`titleOrigin = fetched`), imported YouTube and X titles. A job's input
marks such fields `untrusted: true` and quotes them; they may shape only short-lived,
validated suggestions, never anything kept. Jobs never see URLs' contents.

## 5. Validation (Swift, before anything is shown)

1. The output decodes into the job's type; unknown fields are refused.
2. Length and count caps per job.
3. Every item id exists and is in the job's allowed set.
4. **Banned content**: comparisons with other people, streak or guilt words ("you
   missed", "broke", "failed"), medical or diagnostic terms. Item titles are masked
   before this check, so "Fix broken build" never trips it.
5. On any failure the job returns nothing: the plain behaviour, a short "Couldn't
   suggest steps" line, and in a debug build the reason (never the content) in the log.

## 6. Jobs

| Job | Where | Output | Phase |
|---|---|---|---|
| **Suggest steps** | Add Step… and Details' Steps (SPEC "Suggest steps") | 3–5 steps, ≤ 80 characters each, the first a 2-minute start | AI-1 |
| **Evening line** | the 21:00 summary | one line ≤ 120 characters naming something done | AI-2 |
| **Fits today** | Goals & Later | ≤ 3 items with a free slot on today's timeline and a reason ≤ 80 | AI-3 |
| Reader, memory | later | from the 2026-11-08 plan (§10) | later |

Zero-tick days keep the hand-written lines (shipped), never a model's.

## 7. Settings › AI

Off by default. **Continue with ChatGPT** (then the account's email, **Sign out**,
**Manage usage**), the model, and a switch per job. Each says plainly what is sent:
"Sends the task's title, its steps and its note to OpenAI, using your ChatGPT plan."

## 8. Debug log and evals

- A debug build keeps a local log of each job: name, input size, model, time, whether
  it passed validation and why not. Never tokens, never content. It is how prompts are
  tuned.
- **Evals**: fixed inputs with expected *properties* (Suggest steps: 3–5 items, under
  the caps, the first short, none repeating an existing step, no banned words), run
  against the live model on request and against recorded answers in CI. Each must fail
  against a deliberately broken prompt or validator (AGENTS.md rule 1).

## 9. Privacy

- Off by default; nothing is sent until the person signs in and turns a job on.
- Each job sends only its own input (§6), never the history.
- Measuring helpfulness, if ever, from local behaviour only (suggestions added); no
  tracking (AGENTS.md rule 8).

## 10. Kept from the 2026-11-08 plan, for later

The evening question (a pleasantness slider and "Which one felt best?", facts the
person owns), the support nudge after a run of very unpleasant evenings (hard-coded,
at most every 14 days), the Reader (one link's summary, kept apart from the person's
data) and memory notes with a daily "dream". Each comes back as its own job when the
first jobs have earned their place.

## 11. Decisions

- **2026-11-22 (*user*)**: the person's ChatGPT plan through Sign in with ChatGPT, in
  Swift, replaces the bundled pi-agent-core helper: the spike passed in the sandbox,
  with no helper, no JavaScript, no borrowed login. pi's design is kept as a shape
  (layers, small prompts, typed output), not as code.
- **2026-11-22**: no agent loop, no tools, no plug-ins until a job needs them.
- **2026-11-22**: the first job is Suggest steps (SPEC).
- Superseded 2026-11-22: the bundled `clew-agent` helper, Codex OAuth reuse, the
  monthly token cap (the plan's own limits apply), `AgentOutput` records (Suggest
  steps keeps nothing).
