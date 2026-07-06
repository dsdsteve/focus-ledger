# focus-ledger

A cross-session task ledger for Claude Code, with soft nudges. Park open threads that survive restarts, have them replayed when you open a session, and get a quiet flag when one goes stale. The tool holds the state so you don't have to remember to.

## What it does

- **`/focus-ledger:focus`** — list everything open (durable parked threads + this session's in-flight items), ranked, with stale ones flagged. Read-only.
- **`/focus-ledger:park <thing>`** — create a new durable thread that survives across sessions.
- **`/focus-ledger:resume <thing>`** — reactivate an already-parked thread into the active session.
- **`/focus-ledger:snooze [1d|4h|30m]`** — mute the stale-thread nudge for a while.
- **`/focus-ledger:setup [local|global|remove]`** — install the one behavior that can't be a hook: offer to park the old thread when you pivot to a new topic (see below). Writes a managed block to your `CLAUDE.md`; re-run to update, `remove` to take it out.

You can also just say it in plain English — the commands are trigger-described, so they fire without the slash prefix too:

| You say | Runs |
|---|---|
| "what was I in the middle of?" · "any loose ends?" | `focus` |
| "don't let me forget to renew the cert" · "add a todo: refactor auth" | `park` |
| "let's get back into the auth refactor" · "reopen the cert thing" | `resume` |
| "stop nagging me about old threads today" | `snooze` |

### Hooks (all soft — never block)

- **SessionStart** replays your parked threads into a fresh session, so nothing silently drops.
- **Stop** emits a quiet note *only* when an open item has gone stale (default 7 days). Silent otherwise.
- **PreToolUse** (on `Write`/`Edit`) shows a one-line "is this confirmed / does the wording fit its reader?" nudge. Non-blocking.

## The ledger

A single plain-markdown file at `~/.claude/focus-ledger.md`, created on first `park`. Greppable, portable, hand-editable. List open items:

```bash
grep -E '^- \[ \]' ~/.claude/focus-ledger.md
```

### Format (v1)

The hooks read this file with simple line matching, so the format is a small contract — keep to it when hand-editing:

```markdown
# Focus ledger

## Parked (durable — carries across sessions)
- [ ] (YYYY-MM-DD) a thing to come back to
- [x] (YYYY-MM-DD) a done thing (ignored)

## This session (volatile — clear whenever)
- [ ] (YYYY-MM-DD) something in flight
```

- **Two `##` sections**, named exactly as above — SessionStart only replays items under **Parked**.
- **Open item** = a line starting `- [ ] `; a `(YYYY-MM-DD)` date drives staleness. `- [x]` is treated as done and skipped.
- One item per line. The `park` command writes this shape for you; if you hand-edit, match it or the hooks will quietly skip the line.

This is **format v1** — a breaking change to it would come with a major version bump and migration notes.

## Install

```
/plugin marketplace add dsdsteve/focus-ledger
/plugin install focus-ledger@focus-ledger
```

Or test locally without installing:

```bash
claude --plugin-dir ./focus-ledger
```

## Tuning (all optional, via env)

| Variable | Effect |
|---|---|
| `FOCUS_STALE_DAYS=<n>` | Staleness threshold in days (default 7). |
| `FOCUS_STOP_NUDGE=off` | Disable the Stop stale-nudge entirely. |
| `FOCUS_WRITE_CHECK=off` | Disable the PreToolUse write-nudge. |
| `FOCUS_WRITE_CHECK=strict` | Make the write-nudge pause for confirmation instead of just noting. |

## Optional: offer to park when you change direction

The commands and hooks cover the *manual* and *event-driven* parts. There's one more behavior some people want — **when you pivot off an unfinished thread to a new topic, have the assistant offer to park the old one** — that can't be a hook (it needs the model's judgment about what "pivoting off something unfinished" means), so it lives as an instruction in your `CLAUDE.md` rather than in plugin code.

It's off by default, because it changes how the assistant talks to you in *every* conversation, and that's a matter of taste. Turn it on when you want it:

```
/focus-ledger:setup local     # this project's CLAUDE.md (or: global, for every project)
```

That writes a managed, clearly-marked block to your `CLAUDE.md` (backing the file up first). Re-run to update it in place, or `/focus-ledger:setup remove` to take it back out. The block it writes:

```markdown
When I pivot off an unfinished thread to a new topic, answer the new thing and
then offer in one line to park the old one (e.g. "want me to park <old thing>?").
Offer, don't auto-park. One line, not a paragraph. Only on a real pivot off
something unfinished — not every topic change.
```

Prefer to paste it yourself? That works too — the command just does it idempotently so you don't end up with duplicates when the wording changes.

## What runs, and what it can touch

The three hooks run automatically on session events, so here's the trust ask in full:

- **No network, ever** — only local file reads and text output. The scripts in `hooks/` and `scripts/` are short; read them.
- **Writes only under `~/.claude/`** — the ledger, a `.focus-snooze` marker, and a transient lock file during `park`. The one exception is `/focus-ledger:setup`, which you run explicitly: it edits a `CLAUDE.md` (project-local or `~/.claude/`) and backs it up first.
- **Ledger text is never executed** — the hooks parse it as data, never as shell.
- **SessionStart puts your parked items into the model's context** (so the session opens aware of them) — which means, like anything in a conversation, that text goes to your model provider. Don't park secrets.
- **Every hook is soft** — it adds a note or context, never blocks. Turn any off with the env vars above.

Requires `bash`, `awk`, `date` (standard on macOS and Linux); `jq` used if present, with a fallback if not.

## Development

Run the test suite (no dependencies beyond a shell):

```bash
bash test/run.sh          # runs under bash and dash
bash test/run.sh bash     # single shell
```

CI runs it on macOS and Linux plus `shellcheck` on every push. Contributions welcome — keep the hooks POSIX-clean (they're exercised under `dash`) and add a fixture case for any new behavior.

## License

MIT
