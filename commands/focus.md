---
description: Show the full list of open threads — durable parked threads plus this session's in-flight items — ranked, with stale ones flagged. Use when the user asks what's open, what they were working on, where they left off, what's still pending, or wants an overview of their loose ends or todos. This lists everything and acts on nothing; to reopen one specific parked item use resume, to add a new one use park. Read-only and safe to run anytime.
argument-hint: (no args) — just shows the ledger
allowed-tools: Read
---

Show the user their open threads from the focus ledger at `~/.claude/focus-ledger.md`.

Steps:
1. Read `~/.claude/focus-ledger.md`. If it doesn't exist, say so plainly and mention `/focus-ledger:park <thing>` to add the first item.
2. List the open items — lines that **start with** `- [ ]` — from both sections. Ignore any `- [ ]` inside `<!-- -->` comment blocks (those are format examples, not real items), and skip done (`- [x]`) or deleted lines.
3. Flag any item whose `(YYYY-MM-DD)` date is more than 7 days before today's date as **stale** (show the age, e.g. "9d"). Today's date is in your context. (7 days matches the Stop hook's default `FOCUS_STALE_DAYS`; if the user has set that env var to another value, prefer theirs so the two surfaces agree.)
4. Rank: stale durable items first, then other durable items, then this-session items. Within a tier keep ledger order.

Output rules:
- Lead with the content. First line: `Open threads, ranked.`
- Then the two counts: `Parked (durable): N — M flagged stale.` and `Session: N in flight.`
- Then the ranked items as a short list, each with its age. Put a `(stale, Nd)` marker only on flagged ones.
- If nothing is stale, end with `No items flagged stale.`
- If the ledger is empty or missing, say so plainly.
- Keep it neutral and factual; just report what's open, don't add advice or commentary.
