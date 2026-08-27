# focus-ledger

A cross-session task ledger for Claude Code, with soft nudges. Park open threads that survive restarts, have them replayed when you open a session, and get a quiet flag when one goes stale. The tool holds the state so you don't have to remember to.

**Current release:** `1.2.0`. In 1.2.0 the optional pre-write nudge became opt-in: `FOCUS_WRITE_CHECK` must be `on` or `strict`; unset, `off`, and other values are silent.

## What it does

- **`/focus-ledger:focus`** — list all open durable and in-session threads, ranked, with stale items flagged. Read-only.
- **`/focus-ledger:park <thing>`** — create a new durable thread that survives across sessions.
- **`/focus-ledger:resume <query>`** — move one uniquely matched parked thread into this session.
- **`/focus-ledger:done <query>`** — mark one uniquely matched parked or in-session thread complete.
- **`/focus-ledger:snooze [1d|4h|30m]`** — mute the stale-thread nudge temporarily; the default is one day.
- **`/focus-ledger:doctor`** — diagnose ledger, marker, setup-block, lock, and adjacent-artifact problems without changing anything.
- **`/focus-ledger:tidy`** — report safe cleanup, ask once, then archive and repair only the freshly verified candidate set.
- **`/focus-ledger:setup [local|global|remove]`** — manage the optional pivot-park instruction in a project or global `CLAUDE.md`.

You can also say it in plain English. The command descriptions let Claude choose the same command without a slash:

| You say | Runs |
|---|---|
| “What was I working on?” · “Any loose ends?” · “What is still open?” | `/focus-ledger:focus` |
| “Don't let me forget to renew the cert.” · “Park this for later.” | `/focus-ledger:park` |
| “Let's get back to the auth refactor.” · “Reopen the cert thread.” | `/focus-ledger:resume` |
| “Mark the cert thread done.” · “I finished the auth refactor.” | `/focus-ledger:done` |
| “Quiet stale reminders for four hours.” · “Snooze the nudge.” | `/focus-ledger:snooze` |
| “Is my ledger healthy?” · “Why is this item missing?” | `/focus-ledger:doctor` |
| “Clean up finished work.” · “Archive old completed threads.” | `/focus-ledger:tidy` |
| “Set up the pivot nudge locally.” · “Remove the focus-ledger setup block.” | `/focus-ledger:setup` |

### Hooks

- **SessionStart** runs on startup, resume, clear, and compact. It replays open Parked lines into the new session as explicitly marked untrusted text. It stays silent if nothing is available.
- **Stop** emits a soft stale-item note only when an eligible item is stale and neither snooze nor cooldown suppresses it. The default cooldown is 14,400 seconds (four hours). Lock/read, clock, parser, and serialization failures stay silent; once a note is emitted, cooldown-marker publication fails open, so a marker-write failure can allow another note on the next Stop.
- **PreToolUse** matches `Write` and `Edit` but is **off by default**. `FOCUS_WRITE_CHECK=on` adds a fixed, non-blocking note. `strict` asks for confirmation through the normal permission flow. It never returns a deny decision.

## Ledger and file-format contract

The ledger is a plain Markdown file at `~/.claude/focus-ledger.md`, created on the first successful `park`:

```markdown
# Focus ledger

## Parked (durable — carries across sessions)
- [ ] (YYYY-MM-DD) a thing to come back to
- [x] (YYYY-MM-DD) a completed thing

## This session (volatile — clear whenever)
- [ ] (YYYY-MM-DD) something in flight
```

For deterministic listing, matching, completion, and cleanup:

- The two `##` headings must occur exactly once, in the order shown, with exact spelling and punctuation.
- A valid open record begins exactly `- [ ] (YYYY-MM-DD) ` at column one; a valid completed record begins exactly `- [x] (YYYY-MM-DD) `. The date must be a real Gregorian calendar date.
- One item occupies one physical line. Column-one `<!-- ... -->` comment records are ignored by the shared parser.
- `focus`, matching, Stop, and tidy skip malformed or near-miss records rather than guessing. `doctor` reports the exact line and hand-fix without changing it. Tidy also reports malformed lines as `SKIP` and leaves them byte-for-byte unchanged.
- SessionStart retains a legacy, more permissive replay rule for column-one open lines under a heading beginning `## Parked`; run `doctor` if SessionStart shows something that `focus` omits.

This is **format v1**. Release 1.2.0 does not change it.

### Ranking and selection

`focus` and the matcher use one deterministic snapshot order:

1. stale Parked items;
2. other Parked items;
3. This session items.

Source order is preserved inside each group. Age uses local calendar days. A displayed number is a snapshot rank, not a durable ID; a day rollover, threshold change, or another mutation can move it.

A numeric query selects the current displayed rank (`resume` accepts only a rank currently in Parked; `done` accepts either section). A text query requires every space-separated token to occur as a case-insensitive substring of the item text, in any order. Exactly one match mutates. No match returns status 1 and ambiguity returns status 3 with ranked candidates; both leave the ledger unchanged and the command asks instead of guessing. Duplicate identical records remain separate, so a text query can be ambiguous even when candidate text looks the same.

### Tidy is report → confirm → apply

`/focus-ledger:tidy` always runs read-only report mode first and relays every `META`, action, `SKIP`, `BLOCK`, and `SUMMARY` row. Report mode creates no lock or temporary file and changes no mtime. Apply is offered only when the report contains an automatic action and no `BLOCK`; the command runs `--apply` only after an answer that is exactly `yes`, case-insensitively, with no qualification.

Apply does not trust the earlier report as a transaction plan. It locks the current ledger, re-derives candidates, stages same-filesystem replacements, verifies exact open/near-miss/retained-record multisets, and then reports the fresh result. It:

- **archives, never discards, eligible completed records** into `~/.claude/focus-ledger-archive.md`;
- promotes valid open This session records to Parked;
- re-homes valid open records found outside the required sections;
- removes only expired numeric snooze/cooldown markers and safely classified stale rewrite temps;
- never guesses a section for a completed record outside the required sections and never repairs malformed text.

Invoking `scripts/focus-tidy.sh --apply` directly bypasses the command prompt's confirmation gate.

## Install

```text
/plugin marketplace add dsdsteve/focus-ledger
/plugin install focus-ledger@focus-ledger
```

Or test locally without installing:

```bash
claude --plugin-dir ./focus-ledger
```

## Tuning

All supported variables are optional:

| Variable | Effect |
|---|---|
| `FOCUS_STALE_DAYS=<n>` | Nonnegative decimal staleness threshold in local calendar days (default `7`; invalid or over-nine-digit values fall back to `7`). |
| `FOCUS_STOP_NUDGE=off` | Exact value `off` disables the Stop stale nudge. Other values leave it enabled. |
| `FOCUS_WRITE_CHECK=on` | Emit the soft PreToolUse write note. Unset, `off`, and any value other than `on` or `strict` are silent. |
| `FOCUS_WRITE_CHECK=strict` | Emit the same note and ask before each matched `Write`/`Edit`; it does not deny the operation. |
| `FOCUS_NUDGE_COOLDOWN=<seconds>` | Stop-nudge cooldown (default `14400`). `0` disables cooldown suppression, so each eligible Stop may emit; invalid values fall back to `14400`. |
| `FOCUS_ARCHIVE_DAYS=<n>` | Nonnegative decimal age for tidy archival (default `30`; invalid or over-nine-digit values fall back to `30`). `0` makes completed records dated today or earlier eligible; future-dated records remain ineligible until their date. |

Only those five names are supported user configuration. For auditability, runtime also uses these implementation-only `FOCUS_*` parser, path, lock, and rewrite symbols; they are not settings and may change without notice:

`FOCUS_ARCHIVE_PATH`, `FOCUS_CALENDAR_DATE`, `FOCUS_DISPLAY_LEDGER`, `FOCUS_LEDGER`, `FOCUS_LEDGER_PATH`, `FOCUS_LIB_DIR`, `FOCUS_LOCK`, `FOCUS_LOCKED`, `FOCUS_LOCK_TOKEN`, `FOCUS_MARKER_PATH`, `FOCUS_MATCH_ELIGIBLE`, `FOCUS_MATCH_QUERY`, `FOCUS_PARKED_HEAD`, `FOCUS_PARSE_AWK`, `FOCUS_PARSE_MODE`, `FOCUS_PRE_BYTES`, `FOCUS_PRE_CKSUM`, `FOCUS_PRE_FINAL_NEWLINE`, `FOCUS_PRE_LINES`, `FOCUS_REAP`, `FOCUS_REAPING`, `FOCUS_REAP_TOKEN`, `FOCUS_REWRITE_ITEM`, `FOCUS_SESSION_HEAD`, `FOCUS_STALE_THRESHOLD`, `FOCUS_TARGET_LINE`, `FOCUS_TMP`, `FOCUS_TODAY_DAYS`, `FOCUS_TRIM`, and `FOCUS_WRITE_GATE`.

## Optional: offer to park when you change direction

Some people want the assistant to offer to park an unfinished thread after a real pivot. That judgment cannot be a shell hook, so `setup` installs a managed instruction in `CLAUDE.md`. It is off by default because it affects future conversations.

```text
/focus-ledger:setup local     # this project's CLAUDE.md
/focus-ledger:setup global    # ~/.claude/CLAUDE.md
/focus-ledger:setup remove    # local unless another scope is stated
```

Before rotating a backup or rewriting content, setup validates the `<!-- FOCUS-LEDGER:BEGIN ... -->` / `<!-- FOCUS-LEDGER:END -->` structure. Unmatched, nested, or unclosed markers refuse with status 3; content and existing backups remain unchanged. The script may create the parent/target or update an existing target's mtime before that scan, so status 3 is a content-safety guarantee, not a zero-filesystem-effects guarantee. Recover by restoring the newest `CLAUDE.md.focus-bak.*` if one exists, or hand-delete only the partial managed block, then rerun.

On an accepted install, update, or removal, setup removes older matching backups, copies the current file to `CLAUDE.md.focus-bak.<epoch>`, and rewrites the target. Re-running updates the one managed block; removal takes it out. The installed instruction offers to park; it never auto-parks.

## Exit status and retry notes

- `focus-park.sh` returns 2 for an empty normalized item. Status 0 means the exact dated line was observable after the write; status 1 means that verification failed, so the command must not claim success. Other I/O failures can also return nonzero.
- `focus-list.sh` returns 0 with TSV or empty output when the ledger is absent/empty; parser or local-date failure returns nonzero and must not be presented as an empty ledger.
- `focus-snooze.sh` returns 2 for an invalid, zero, overflowing, or unformattable duration; operational clock/directory/lock/write failure returns 1; status 0 means the marker was published and a confirmation was printed.
- Park's final exact-line check cannot distinguish a line written by this attempt from an identical line already present. A crash after publication but before confirmation, followed by a retry, can create a duplicate; inspect with `focus` or `doctor` before retrying an uncertain identical park.
- `resume` and `done` return 1 for no eligible match, 3 for ambiguity, and 4 when locking or guarded publication cannot be proven; those paths intend to leave the ledger unchanged.
- `setup` returns 3 for marker-scan failure or malformed marker structure and prints recovery guidance. Unknown arguments return 2.
- `doctor` returns 0 for clean or not-yet-created state, 1 when findings were fully reported, and 2 when diagnosis was incomplete. `tidy` uses 0 for a report/verified apply/no-op and 2 for refusal or operational failure.

A successful read-after-write check is not an `fsync` or stable-storage guarantee; see the recovery limits below.

## What runs, what it reads, and what it can touch

There are no network calls. Trust is local filesystem access plus what plugin output exposes to the configured model:

- SessionStart sends parked lines into model context automatically. Stop can send up to three stale item texts in a `systemMessage`. Command output and candidate/report rows are also read by the model when you invoke a command. Do not put passwords, credentials, private keys, tokens, or other secrets in the ledger.
- Ledger records are inert, untrusted data. Scripts never evaluate them as shell or awk source. Dynamic parser values travel through the environment, and command prompts relay escaped TSV fields rather than executing them.
- `doctor` is strictly read-only: it does not acquire locks, create scratch files, remove artifacts, or repair text. Tidy report mode is also read-only.
- The command-level gates are user intent for ordinary mutations, exact `yes` for tidy apply, a scope choice for setup when omitted, and optional `strict` permission confirmation for matched writes. Direct script invocation bypasses command-prompt gates.

### Retained paths

| Path | What changes it | Lifetime |
|---|---|---|
| `~/.claude/focus-ledger.md` | park, resume, done, tidy | Primary retained ledger. |
| `~/.claude/focus-ledger-archive.md` | tidy apply | Retained archive of eligible completed records. |
| `~/.claude/.focus-snooze` | snooze; expired marker cleanup by Stop/tidy | Retained while active. |
| `~/.claude/.focus-last-nudge` | Stop; expired marker cleanup by tidy | Retained cooldown state. |
| `~/.claude/focus-ledger.md.backup.YYYYMMDDTHHMMSS.XXXXXX` | tidy apply | Verified recovery copy intentionally retained after successful apply; later applies may accumulate copies. |
| `./CLAUDE.md` or `~/.claude/CLAUDE.md` | explicit setup/update/remove | Retained managed instruction target. |
| `<CLAUDE.md>.focus-bak.<epoch>` | setup | Retained recovery copy; setup rotates older matching copies before an accepted rewrite. |

Tidy and doctor never purge the retained archive or successful tidy ledger backups. Completed text can therefore remain indefinitely after it leaves the active ledger. To purge it, first ensure no focus-ledger command is running, inspect and preserve any recovery copy you still need, then remove only the exact regular archive/backup files you selected with ordinary filesystem tools. Avoid broad globs around active locks or transaction files. Setup backups are different: an accepted setup run automatically keeps only its newest matching generation.

### Locks, stages, and recovery transients

- Ledger, snooze, and last-nudge operations can create `<target>.lock/owner` and `<target>.lock.reap/owner`. Tidy creates the archive lock `focus-ledger-archive.md.lock/owner` and also takes marker locks during cleanup.
- Ledger rewrites create `focus-ledger.md.tmp.<pid>.XXXXXX` and sometimes a `.trim` companion. Marker publication creates `<marker>.tmp.<pid>`.
- Tidy creates ledger/archive stages and verification files such as `.tmp.*`, `.verify*`, `.archive-lines.*`, and a transient archive transaction backup. Rollback can create `<target>.rollback.*`.
- Before deleting an expired marker or eligible stale temp, tidy renames it to `<original>.tidy-delete.<pid>` and creates a `.restore` recovery copy. It removes those only after core publication verifies.
- Setup uses an implementation-selected system temporary file while rewriting `CLAUDE.md`.

These are normally removed on handled success or failure. A crash, `SIGKILL`, shell abort, or power loss can retain locks, stages, transaction backups, quarantine files, or setup temps. `doctor` reports the ledger lock/reap directories, snooze and last-nudge marker state, managed-block files, and `focus-ledger.md.*` adjacent artifacts. It does not inventory archive-adjacent files, marker lock/temp/quarantine paths, or implementation-selected setup temps. Tidy removes only its narrowly classified safe stale ledger-rewrite temps and expired regular markers. Unknown files require manual review.

### Unsafe path handling is intentionally narrow

- `doctor` refuses to follow a ledger or `CLAUDE.md` symlink and reports unsafe/nonregular ledger, marker, lock, and temp paths without changing them.
- Tidy refuses an unsafe ledger, archive, marker, generated backup, or eligible temp before applying; it does not follow those paths.
- Snooze and last-nudge publication replace the destination pathname with a private regular file rather than writing through a symlink or FIFO.
- Other ledger commands, SessionStart, Stop's legacy snooze read, and setup assume trusted user-owned path topology; they do not all implement doctor/tidy's refusal policy. A ledger or `CLAUDE.md` symlink may be read, replaced, or in some missing-path cases followed. Stop can follow a snooze symlink to a regular target when reading, then removes the link pathname if expired. Run `doctor`, and do not point these paths at sensitive files.

### Recovery limits

- Same-directory rename and append provide process-level single-file publication, not a durability guarantee after power loss. The runtime does not `fsync` file contents or parent directories.
- Tidy publishes archive and ledger separately. There is no cross-file atomic transaction; a crash between renames can leave an archived record in both files. Rollback on handled errors and `INT`/`TERM`/`HUP` is best effort and may retain the named ledger backup when incomplete.
- Locks identify owners by PID only. PID reuse can make an abandoned lock or temp look active, conservatively blocking cleanup. Tidy never reaps someone else's ledger/archive lock.
- Park alone has an append-only fallback when guarded locking/publication cannot proceed. It preserves data but can place the new record at end of file outside the intended section; `doctor` reports that state and tidy can re-home a valid open record.
- Setup has no lock and rewrites by redirection. Concurrent setup/manual edits or an interruption can leave a truncated target; recover from its retained backup.

Runtime requirements are `bash`, `awk`, and `date` on macOS or Linux. `jq` is optional; Stop has a fallback serializer.

## Development

Run the complete dependency-free suite under both supported shells:

```bash
bash test/run.sh
bash test/run.sh bash
bash test/run.sh dash
```

Run the release gates used for this closeout:

```bash
shellcheck -S warning scripts/*.sh hooks/*.sh test/run.sh
git diff --check
python3 -m json.tool .claude-plugin/plugin.json >/dev/null
python3 -m json.tool .claude-plugin/marketplace.json >/dev/null
```

CI runs the behavior suite on macOS and Linux and runs shellcheck at warning severity. Keep hooks and scripts dash-clean, preserve inert-data handling, and add a fixture for behavior changes.

## License

MIT
