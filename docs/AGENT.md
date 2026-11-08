# Clew Agent

Status: **design**, 2026-11-08. Builds on [ARCHITECTURE.md](ARCHITECTURE.md)
(ADR-4, ADR-5). Not a coding agent: a task and wellbeing companion that reads
your record and says a little, kindly.

## 1. Principles

1. **Clew is complete without it.** Every feature works with AI off. Summaries
   fall back to plain counts, and the Later pile is managed by hand.
2. **It never changes your data.** It reads history and writes only its own
   `AgentOutput` records. Swift enforces this, not the prompt (§7).
3. **No conversation.** There is no chat or text box. Its only inputs are your task
   history and the optional evening question (§5).
4. **A friend, not a coach with a whistle.** Encouraging, brief, never pushy.
   **Never compares you to anyone.** No streaks, no guilt, no "you missed".
5. **Say less.** One line in the menu bar, one notification line. Never paragraphs.
6. **Grounded in practice, then tuned by use.** We start with established
   methods (§6) and adjust from the user's feedback, not from guesses.

## 2. Switches (user-selected, all off by default)

| Switch | What it does | Cost |
|---|---|---|
| **Daily coach** | Evening recap line with encouragement; quick-start hints; daily dream | ~2 calls/day |
| **Later helper** | "3 that fit tonight" from the Later pile, each with a short reason | ~1 call/day |
| **Reader** | Opens a link: summary, minutes, energy needed, key points, and help while reading | Most expensive; per item, or automatically for new Later items |

- **Monthly token cap** in Settings, with usage shown next to it. Swift totals the
  usage `pi-ai` reports per job and refuses jobs that would exceed the cap, falling
  back to the non-AI behaviour.
- The Later helper without the Reader works from titles, lengths and sources only.

## 3. Runtime

```
Clew.app (Swift)                               clew-agent (optional download)
 AgentRuntime ── spawn per job ──stdio──▶  pi-agent-core  +  pi-ai
   │  ◀── toolCall {name,args}                  (loop, hooks)   (providers, login)
   │  ──▶ toolResult  (read-only ClewCore query)
   │  ◀── credential.get/put  ──▶ Keychain
   │  ◀── usage {tokens}
   │  ◀── result {json}  ──▶ validate (§7) ──▶ AgentOutput
```

- **clew-agent**: TypeScript on `@earendil-works/pi-agent-core` and `pi-ai`, with
  **exact versions pinned** (1.5.0 at time of writing). Compiled with Bun into one
  executable, signed, inside `Clew.app/Contents/Helpers`, and installed only when a
  switch is turned on. It is wrapped behind our own `AgentRuntime` protocol, so it
  can be replaced without touching the rest of the app.
- **Spawned per job, exits after.** No resident process and no database handle.
- **Protocol:** newline-delimited JSON over stdio, versioned (`proto: 1`).
- **Credentials:** the helper's `CredentialStore` implementation forwards to the
  Swift Keychain. Tokens are never written by the helper.
- **Providers** (all through `pi-ai`):
  - ChatGPT subscription via the Codex OAuth login. **Personal use only.** A public
    build must use OpenAI's official "Sign in with ChatGPT" programme instead.
  - API keys: OpenAI, Anthropic, Google.
  - Local: Ollama, for users who want nothing to leave the Mac.
  - Claude *subscription* login is not offered (reportedly disallowed for
    third-party tools; verify before release).
- **Unverified:** whether Bun's JIT needs `com.apple.security.cs.allow-jit` under the
  sandbox and hardened runtime. Measure this in the first spike.

## 4. Two roles, kept apart

Web content is untrusted: a page can contain text written to steer a model. So
the role that reads the web never sees the user, and the role that sees the user
never reads the web.

| | **Reader** | **Coach** (planner) |
|---|---|---|
| Sees | one item's URL and fetched content | history summaries, memory notes, mood answers, Reader outputs as plain fields |
| Tools | `fetch_url` (GET, size-capped, text only) | `get_today`, `get_history(range)`, `get_later`, `get_notes` (all read-only) |
| Never | sees Clew data, mood, notes | fetches the web |
| Writes | `Enrichment` for that item | `Recap`, `Suggestions`, `QuickStart`, memory note ops |

Reader output reaches the Coach only as **validated, length-capped fields**
(summary ≤ 140 chars, minutes, energy, ≤ 3 tags), never as raw page text.

## 5. Inputs

**Task history** (from ClewCore read models): check-ins with `localDay`, time and
rating; picks from Later; items ignored or abandoned (e.g. watch % stalled); what
was planned versus done.

**Data minimisation:** the Coach receives aggregates for a recent window (default
14 days), plus memory notes. It never receives the whole raw history.

**Evening question** (optional, once a day, skippable; works with AI off too):

1. **"How did today feel?"**: one slider, *unpleasant ↔ pleasant*. This follows the
   valence axis of the circumplex model of affect, as Apple's State of Mind
   logging does, and avoids judgemental words like "bad" or "low". *Later option:*
   a Mood-Meter-style 2×2 (pleasantness × energy; Yale RULER).
2. **"Which one felt best?"**: tap one of today's done items. This is a no-typing
   form of "Three Good Things" (savouring what went well), and it is the Coach's
   strongest preference signal.

Both answers are facts (`DayReflection`), owned by the user, never by the agent.

## 6. Jobs

| Job | When | Output |
|---|---|---|
| **Recap** | evening summary time (default 21:00) | `Recap { line ≤ 120 chars, highlightItemId? }` |
| **Dream** | right after Recap, daily | memory note ops (§8) |
| **Later suggestions** | morning, and when Later is opened (cached for the day) | `Suggestions [{itemId, reason ≤ 80}] ≤ 3` |
| **Quick start** | when an item is opened and has no hint yet | `QuickStart { step ≤ 100 chars }`: a 2-minute first action (from AAHD) |
| **Read** | on demand, or for new Later items if the Reader is on | `Enrichment { summary, minutes, energy: light/focus, tags, keyPoints? }` |

**How the Coach decides what to say.** These are the starting rules; tune from feedback.
- **Adjust the load to the day:** after a less pleasant day, suggest 1 light item,
  not 3. If the plan has more than 6 items, gently suggest a smaller list.
- **Reframe (CBT):** recap what *was* done ("3 done, including the hard one"),
  never what wasn't.
- **Autonomy (motivational interviewing):** offer, don't instruct. "Maybe…",
  "If you feel like it…".
- **Savour:** name the item you said felt best, or the highest-rated one.
- **Zero-tick days use curated lines, not the model:** a hard-coded, rotating,
  non-repeating set ("Rest is part of the plan." / "Tomorrow's list is ready when
  you are."). This is safer on a hard day, costs nothing, and works with AI off.

## 7. Output validation (Swift, before anything is stored or shown)

1. JSON matches the job's schema; unknown fields are rejected.
2. Length caps (above) and language (system language; English first).
3. Every `itemId` exists and is in the allowed set for that job (e.g. Later items only).
4. **Banned content:** comparisons with other people ("than most", "other
   people", "average user"…), streak or guilt language ("you missed", "broke",
   "failed"), medical or diagnostic terms. This is a word-list check plus a rule in
   the prompt; a failure drops the output.
5. On any failure: use the non-AI fallback, and log the reason, never the content, in debug.

## 8. Memory (after Anthropic's "components of agent memory")

| Layer | In Clew |
|---|---|
| Transcripts | the fact history (check-ins, picks, reflections): append-only and attributed, so it is trustworthy ground truth |
| Notes | short observations, each with evidence: `{claim, evidence: "12 of 15 evening picks", firstSeen, lastConfirmed}` |
| Representation | a small structured profile: sections such as Evenings, Videos, Courses, Load |
| Injected context | a ≤ 15-line digest of the profile, sent into every Coach job |

**Dream (daily, after Recap):**
- **re-test** each note against recent facts, and weaken or delete the ones the facts contradict;
- **merge** duplicates;
- **promote** stable notes into the digest, and **demote** details out of it;
- **prune** notes not confirmed in about 30 days.

Purpose-directed rather than rule-driven: the dream prompt says what the memory is
*for* (better-fitting, kinder suggestions), not what to record.

- **No approval step.** The memory updates itself.
- **Visibility:** shown **only in debug mode** for now ("What Clew noticed",
  read-only). Whether regular users see it is decided before public release.
- Notes are agent-owned (`AgentOutput.notes`). Deleting them never touches user facts.

## 9. Safety boundaries

- Not therapy; no diagnosis; no medical advice; no comparisons.
- There is no free-text input, so open-ended distress cannot be entered. **Proposal
  (needs a decision):** after a run of very unpleasant evenings (e.g. 5 of 7), show
  one **hard-coded** gentle line pointing to real support. Rate-limited, never
  model-generated.
- The agent cannot act outside its own outputs: no notifications of its own, and no
  changes to schedules or reminders.

## 10. Measuring whether it helps

From behaviour only, with no rating buttons for the agent:
- **pick rate**: suggested items picked;
- **follow-through**: picked → done the same day;
- **coach-on vs coach-off days**: done/planned ratio, and evening valence;
- **active days**: the SPEC's 5-of-7 bar.

**Offline evals:** synthetic histories with expected *properties*, run against
prompt + validator. Examples: a zero-tick day gets a curated line; a low-valence day
gets ≤ 1 suggestion; no output ever contains a comparison; Reader output never
appears unvalidated in Coach input. Per AGENTS.md, each eval must fail against a
deliberately broken prompt or validator.

## 11. Privacy

- Off by default. Each switch says plainly what is sent and to whom.
- Mood answers go only to the Coach, and only when the Coach is on.
- Local-only mode via Ollama.
- "Delete agent data" removes all `AgentOutput` (notes, recaps, enrichments).

## 12. Phases

1. **v1.2a**: evening question (no AI), curated lines, `AgentRuntime` + helper spike
   (measure size, JIT, login).
2. **v1.2b**: daily Coach (recap + dream), Later helper, quick start.
3. **v1.2c**: Reader (enrichment, then reading help).
4. Later: Mood-Meter option, reward-theme-aware recaps, system-language output.

## 13. Open questions

1. The distress pointer in §9: adopt it, and with which threshold and wording?
2. Should regular users see the memory page? (Decide before public release.)
3. Should the Reader run automatically on every new Later item, or only on request?
