# focus-ledger

A cross-session task ledger for Claude Code, with soft nudges. Park open threads that survive restarts, have them replayed when you open a session, and get a quiet flag when one goes stale. The tool holds the state so you don't have to remember to.

**Current release:** `1.3.0`. This release adds a UserPromptSubmit hook: when a message announces an aside with `sidenote`, `side note`, or `btw`, it reminds the model to offer to park an unfinished thread, and when a message floats an idea such as `would be nice` or `need a new feature`, to keep working and offer to park the idea. Both back up the prose instruction `setup` installs, which now covers side ideas too. The eight verbs also moved from `commands/` to `skills/`, where the same files load in Claude Code and Kiro. 1.2.2 made `doctor` report the preconditions `tidy --apply` enforces, preserved the ledger's permission bits, refused a non-regular setup target, and serialized concurrent setup runs. In 1.2.0 the optional pre-write nudge became opt-in: `FOCUS_WRITE_CHECK` must be `on` or `strict`; unset, `off`, and other values are silent.

## What it does

- **`/focus-ledger:focus`** — list all open durable and in-session threads, ranked, with stale items flagged. Read-only.
- **`/focus-ledger:park <thing>`** — create a new durable thread that survives across sessions.
- **`/focus-ledger:resume <query>`** — move one uniquely matched parked thread into this session.
- **`/focus-ledger:done <query>`** — mark one uniquely matched parked or in-session thread complete.
- **`/focus-ledger:snooze [1d|4h|30m]`** — mute the stale-thread nudge temporarily; the default is one day.
- **`/focus-ledger:doctor`** — diagnose ledger, marker, setup-block, lock, and adjacent-artifact problems without changing anything. It also reports the conditions that would make `tidy --apply` refuse, so a clean report means apply can run: an unsafe or unreadable archive path, a ledger directory it cannot write, and a missing `cmp`, `sort`, `cksum`, or `mktemp`.
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
- **UserPromptSubmit** backs up the park instructions from `setup`. It reads only the prompt text. When the prompt floats an idea with `would be nice`, `nice to have`, `someday`, `feature idea`, or `might need a new feature`, it adds one line telling the model to keep the current task and offer to park the idea. Otherwise, when it announces an aside with `sidenote`, `side note`, or `btw`, it adds one line reminding the model to offer to park the unfinished thread being left. Cues match whole words only. An unannounced pivot or idea still relies on the instruction alone. It never blocks and prints nothing otherwise.

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

This is **format v1**. Release 1.3.0 does not change it.

### Ranking and selection

`focus` and the matcher use one deterministic snapshot order:

1. stale Parked items;
2. other Parked items;
3. This session items.

Source order is preserved inside each group. Age uses local calendar days. A displayed number is a snapshot rank, not a durable ID; a day rollover, threshold change, or another mutation can move it.

A numeric query selects the current displayed rank (`resume` accepts only a rank currently in Parked; `done` accepts either section). A text query requires every space-separated token to occur as a case-insensitive substring of the item text, in any order. Exactly one match mutates. No match returns status 1 and ambiguity returns status 3 with ranked candidates; both leave the ledger unchanged and the command asks instead of guessing. Duplicate identical records remain separate, so a text query can be ambiguous even when candidate text looks the same.

### Tidy is report → confirm → apply

`/focus-ledger:tidy` always runs read-only report mode first and relays every `META`, action, `SKIP`, `BLOCK`, and final `SUMMARY` row. If capture is truncated/incomplete or the final `SUMMARY` is missing, it stops. Report mode creates no lock or temporary file and changes no mtime. Apply is offered only when the complete report contains an automatic action and no `BLOCK`; the command runs `--apply` only after an answer whose entire content is the standalone word `yes`, case-insensitively.

Apply does not trust the earlier report as a transaction plan. It locks the current ledger, re-derives candidates (including newly arrived actions), stages same-filesystem replacements, verifies exact duplicate-aware open/near-miss/retained-record multisets, and explicitly proves every promoted or re-homed occurrence is inside Parked before the first following real H2. It:

- **archives, never discards, eligible completed records** into `~/.claude/focus-ledger-archive.md`;
- promotes valid open This session records to Parked;
- re-homes valid open records found outside the required sections;
- removes only expired numeric snooze/cooldown markers and safely classified stale PID-bearing rewrite temps;
- never guesses a section for a completed record outside the required sections and never repairs malformed text.

Missing and empty ledgers are intentional report/apply no-ops: tidy creates no lock or backup and does **not** clean markers or temps in that state. Inspect those exact artifacts manually. A cleanup-only apply against a nonempty ledger does not create a ledger backup and leaves ledger bytes and mtime unchanged.

Quarantine renames are the volatile-deletion commit. Later unlink or owned lock/work-file cleanup failures do not attempt an impossible rollback; tidy returns nonzero with `APPLY verified-with-artifacts` and prints each retained recovery path. Core publication or pre-commit failures still attempt rollback, defer a second `INT`/`TERM`/`HUP` until restoration and lock release complete, and preserve/name surviving backups or quarantine copies when recovery is incomplete.

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

### Kiro

The same skill files load in Kiro, and both tools share one ledger at `~/.claude/focus-ledger.md`. There is no Kiro marketplace install, so copy the files from a clone of this repository:

```bash
git clone https://github.com/dsdsteve/focus-ledger && cd focus-ledger
mkdir -p ~/.kiro/skills/focus-ledger-shared
cp -R scripts hooks ~/.kiro/skills/focus-ledger-shared/
for s in skills/*/; do
  n=$(basename "$s")
  mkdir -p ~/.kiro/skills/focus-ledger-"$n"
  cp "$s"SKILL.md ~/.kiro/skills/focus-ledger-"$n"/
done
```

Kiro hooks belong to an agent, so add these entries under `hooks` in the agent you use (`~/.kiro/agents/<agent>.json`):

```json
"agentSpawn": [{"command": "CLAUDE_PLUGIN_ROOT=$HOME/.kiro/skills/focus-ledger-shared $HOME/.kiro/skills/focus-ledger-shared/hooks/focus-session-start.sh", "timeout_ms": 5000}],
"userPromptSubmit": [{"command": "$HOME/.kiro/skills/focus-ledger-shared/hooks/focus-prompt.sh", "timeout_ms": 5000}]
```

Kiro does not read `CLAUDE.md`, so `setup` has no effect there. Put the park-offer instruction in a steering file such as `~/.kiro/steering/focus-ledger.md`, using the text `setup` writes. Kiro discards Stop-hook output, so the stale-item nudge has no Kiro equivalent. To update, pull and re-run the copy.

## Uninstall and optional data removal

1. Remove any optional pivot instruction you installed: run `/focus-ledger:setup local remove` in each project and/or `/focus-ledger:setup global remove`. This changes only the managed `CLAUDE.md` block; bare “uninstall” is not treated as setup removal.
2. In Claude Code, open `/plugin`, select the installed `focus-ledger@focus-ledger` entry, and uninstall/disable it through the plugin manager. If you used `--plugin-dir`, stop launching Claude with that directory instead.
3. Plugin removal deliberately leaves user data and recovery material. To erase it, first stop all Claude/focus-ledger processes. Inspect and, only if no recovery is needed, remove these exact regular paths: `~/.claude/focus-ledger.md`, `~/.claude/focus-ledger-archive.md`, `~/.claude/.focus-snooze`, `~/.claude/.focus-last-nudge`, selected `~/.claude/focus-ledger.md.backup.*` generations, and selected local/global `<CLAUDE.md>.focus-bak.*` generations.
4. Run `doctor` before uninstall if possible. Manually inspect any reported abandoned `.lock`, `.lock.reap`, `.claim.<pid>`, `.tmp.*`, `.verify*`, `.rollback.*`, `.tidy-delete.<pid>`, `.restore`, or archive transaction artifacts; remove only exact paths after confirming no recorded process is alive. Avoid broad globs around active state.

## Tuning

All supported variables are optional:

| Variable | Effect |
|---|---|
| `FOCUS_STALE_DAYS=<n>` | Nonnegative decimal staleness threshold in local calendar days (default `7`; invalid or over-nine-digit values fall back to `7`). |
| `FOCUS_STOP_NUDGE=off` | Exact value `off` disables the Stop stale nudge. Other values leave it enabled. |
| `FOCUS_PROMPT_NUDGE=off` | Exact value `off` disables the UserPromptSubmit park reminders. Other values leave them enabled. The `setup` instruction is separate: remove it with `/focus-ledger:setup remove`. |
| `FOCUS_WRITE_CHECK=on` | Emit the soft PreToolUse write note. Unset, `off`, and any value other than `on` or `strict` are silent. |
| `FOCUS_WRITE_CHECK=strict` | Emit the same note and ask before each matched `Write`/`Edit`; it does not deny the operation. |
| `FOCUS_NUDGE_COOLDOWN=<seconds>` | Stop-nudge cooldown (default `14400`). `0` disables cooldown suppression, so each eligible Stop may emit; invalid values fall back to `14400`. |
| `FOCUS_ARCHIVE_DAYS=<n>` | Nonnegative decimal age for tidy archival (default `30`; invalid or over-nine-digit values fall back to `30`). `0` makes completed records dated today or earlier eligible; future-dated records remain ineligible until their date. |

Only those five names are supported user configuration. For auditability, runtime also uses these implementation-only `FOCUS_*` parser, path, lock, and rewrite symbols; they are not settings and may change without notice:

`FOCUS_ARCHIVE_PATH`, `FOCUS_CALENDAR_DATE`, `FOCUS_DISPLAY_LEDGER`, `FOCUS_LEDGER`, `FOCUS_LEDGER_PATH`, `FOCUS_LIB_DIR`, `FOCUS_LOCK`, `FOCUS_LOCKED`, `FOCUS_LOCK_TOKEN`, `FOCUS_MARKER_PATH`, `FOCUS_MATCH_ELIGIBLE`, `FOCUS_MATCH_QUERY`, `FOCUS_PARKED_HEAD`, `FOCUS_PARSE_AWK`, `FOCUS_PARSE_MODE`, `FOCUS_PRE_BYTES`, `FOCUS_PRE_CKSUM`, `FOCUS_PRE_FINAL_NEWLINE`, `FOCUS_PRE_LINES`, `FOCUS_REAP`, `FOCUS_REAPING`, `FOCUS_REAP_TOKEN`, `FOCUS_REWRITE_ITEM`, `FOCUS_SESSION_HEAD`, `FOCUS_STALE_THRESHOLD`, `FOCUS_TARGET_LINE`, `FOCUS_TMP`, `FOCUS_TODAY_DAYS`, `FOCUS_TRIM`, and `FOCUS_WRITE_GATE`.

`FOCUS_TIDY_TEST_FAIL` is an implementation-only test fault selector used by the automated suite to enter rollback/recovery phases deterministically. It is unsupported, is not a user setting, and must never be set during normal command use.

## Optional: offer to park when you change direction

Some people want the assistant to offer to park an unfinished thread after a real pivot. That judgment cannot be a shell hook, so `setup` installs a managed instruction in `CLAUDE.md`. It is off by default because it affects future conversations.

```text
/focus-ledger:setup local     # this project's CLAUDE.md
/focus-ledger:setup global    # ~/.claude/CLAUDE.md
/focus-ledger:setup remove    # local unless another scope is stated
```

Before creating a parent, target, backup, or staging rewrite, setup refuses a symlinked `CLAUDE.md` and validates the existing `<!-- FOCUS-LEDGER:BEGIN ... -->` / `<!-- FOCUS-LEDGER:END -->` structure. Symlinked targets plus unmatched, nested, unclosed, same-line, or multiple balanced blocks refuse with status 3; target existence, bytes, mtime, and existing backups remain unchanged. Recover malformed marker state by restoring the newest `CLAUDE.md.focus-bak.*` if one exists, or hand-delete only the partial managed block, then rerun.

On an accepted install, update, or removal of an actually present managed block, setup first creates and byte-verifies a new `<CLAUDE.md>.focus-bak.<epoch>.<suffix>` recovery copy, then rotates older matching generations and rewrites the target. A `--remove` against either a missing target or an existing marker-free target is a true no-op: it preserves target bytes and metadata and every existing backup. A first install has no source file to back up. Re-running updates the one managed block; removal takes it out. The installed instruction offers to park; it never auto-parks.

## Exit status and retry notes

- `focus-park.sh` returns 2 for an empty normalized item. Status 0 means the exact dated line was observable after the write; status 1 means that verification failed, so the command must not claim success. Other I/O failures can also return nonzero.
- `focus-list.sh` returns 0 with TSV or empty output when the ledger is absent/empty; parser or local-date failure returns nonzero and must not be presented as an empty ledger.
- `focus-snooze.sh` returns 2 for an invalid, zero, overflowing, or unformattable duration; operational clock/directory/lock/write failure returns 1; status 0 means the marker was published and a confirmation was printed.
- Park's final exact-line check cannot distinguish a line written by this attempt from an identical line already present. A crash after publication but before confirmation, followed by a retry, can create a duplicate; inspect with `focus` or `doctor` before retrying an uncertain identical park.
- `resume` and `done` return 2 for an empty normalized query, 1 for no eligible match, 3 for ambiguity, and 4 when locking or guarded publication cannot be proven; those paths leave the ledger unchanged.
- `setup` returns 3 for marker-scan failure or malformed marker structure and prints recovery guidance. Unknown arguments return 2.
- `doctor` returns 0 for clean or not-yet-created state, 1 when findings were fully reported, and 2 when diagnosis was incomplete. `tidy` uses 0 for a complete report/verified apply/no-op and 2 for refusal, operational failure, incomplete rollback, or a verified apply that retained named cleanup artifacts.

A successful read-after-write check is not an `fsync` or stable-storage guarantee; see the recovery limits below.

## What runs, what it reads, and what it can touch

There are no network calls. Trust is local filesystem access plus what plugin output exposes to the configured model:

- SessionStart sends parked lines into model context automatically. Stop can send up to three stale item texts in a `systemMessage`. UserPromptSubmit reads each message you send, matches it against a fixed phrase list, and stores and transmits nothing. Its only output is up to two fixed lines of its own text. Command output and candidate/report rows are also read by the model when you invoke a command. Do not put passwords, credentials, private keys, tokens, or other secrets in the ledger.
- Ledger records are inert, untrusted data. Scripts never evaluate them as shell or awk source. Dynamic parser values travel through the environment, and command prompts relay escaped TSV fields rather than executing them.
- `doctor` is strictly read-only: it does not acquire locks, create scratch files, remove artifacts, or repair text. Tidy report mode is also read-only.
- A guarded ledger rewrite preserves the ledger's existing permission bits, so park, resume, done, snooze, and tidy apply never silently retighten a file you deliberately widened. A ledger created from scratch gets the mode your umask implies.
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
| `<CLAUDE.md>.focus-bak.<epoch>.<suffix>` | setup | Retained recovery copy; setup verifies the new generation before rotating older matching copies. |

Tidy and doctor never purge the retained archive or successful tidy ledger backups. Completed text can therefore remain indefinitely after it leaves the active ledger. To purge it, first ensure no focus-ledger command is running, inspect and preserve any recovery copy you still need, then remove only the exact regular archive/backup files you selected with ordinary filesystem tools. Avoid broad globs around active locks or transaction files. Setup backups are different: an accepted setup run automatically keeps only its newest matching generation.

### Locks, stages, and recovery transients

- Ledger, snooze, last-nudge, and archive locking can create `<target>.lock/owner`, `<target>.lock.reap/owner`, and pre-publication claim siblings such as `<target>.lock.claim.<pid>` or `<target>.lock.reap.claim.<pid>`. Tidy also takes marker locks during cleanup.
- Ledger rewrites create `focus-ledger.md.tmp.<pid>.XXXXXX` and sometimes a `.trim` companion. Marker publication creates `<marker>.tmp.<pid>`.
- Tidy creates ledger/archive stages and verification files such as `.tmp.*`, `.verify*`, `.archive-lines.*`, and a transient archive transaction backup. Rollback can create `<target>.rollback.*`.
- Before deleting an expired marker or eligible stale temp, tidy renames it to `<original>.tidy-delete.<pid>` and creates a `.restore` recovery copy. The quarantine rename commits logical deletion; unlink failures can intentionally retain a named recovery artifact.
- Setup uses a private no-follow source snapshot and a same-directory output stage while building and publishing canonical `CLAUDE.md` output.

These are normally removed on handled success or failure. A crash, `SIGKILL`, shell abort, or power loss can retain locks, claims, stages, transaction backups, quarantine files, or setup temps. `doctor` reports ledger, archive, snooze, and cooldown lock/reap directories and pending claims; snooze/cooldown marker state; managed-block files; narrowly classified ledger-adjacent artifacts; and common archive-adjacent transaction leftovers. It deliberately excludes successful retained tidy ledger backups and does not inventory arbitrary paths or implementation-selected setup temps. Tidy removes only its narrowly classified safe stale PID-bearing ledger-rewrite temps and expired regular markers. Artifacts focus-ledger itself created during an interrupted run are reported as `*-interrupted` and name it as the author. A legacy or manual adjacent file, whose provenance cannot be recovered from its name, keeps the `*-leftover` wording. Both require manual review and removal.

### Unsafe path handling is intentionally narrow

- `doctor` refuses to follow ledger or `CLAUDE.md` symlinks and reports unsafe/nonregular ledger, marker, lock, claim, temp, archive, and archive-artifact paths without changing them. It rejects `HOME` or `PWD` containing tab/newline separators before emitting TSV.
- Tidy refuses an unsafe ledger, archive, marker, generated backup, or eligible temp before applying; it does not follow those paths. It rejects `HOME` containing tab/newline separators before report or apply.
- Park, list, match, resume, done, and Stop refuse or stay silent on unsafe ledger paths. Stop classifies snooze/cooldown markers without following symlinks. Snooze and cooldown publication replace an unsafe destination pathname with a private regular file rather than writing through it.
- SessionStart retains its legacy regular-file test. Setup refuses a symlinked or non-regular `CLAUDE.md` before reading or rewriting it, so a FIFO or device target exits 3 instead of blocking the snapshot read. Do not point SessionStart paths at sensitive files; run `doctor` before maintenance when provenance is uncertain.

### Recovery limits

- Same-directory rename and append provide process-level single-file publication, not a durability guarantee after power loss. The runtime does not `fsync` file contents or parent directories.
- Tidy publishes archive and ledger separately. There is no cross-file atomic transaction; a crash between renames can leave an archived record in both files. Rollback on handled errors and `INT`/`TERM`/`HUP` is best effort; a second catchable signal is deferred during recovery. Incomplete rollback preserves and names surviving ledger/archive backups and quarantine recovery paths. After quarantine renames commit volatile deletion, later artifact cleanup failure returns `verified-with-artifacts` instead of claiming an impossible restore.
- Locks identify owners by PID only. PID reuse can make an abandoned lock or temp look active, conservatively blocking cleanup. Tidy never reaps someone else's ledger/archive lock.
- Park alone has an append-only fallback when guarded locking/publication cannot proceed. It preserves data but can place the new record at end of file outside the intended section; `doctor` reports that state and tidy can re-home a valid open record.
- Setup serializes concurrent runs on its target with the shared lock the ledger verbs use, so two runs cannot each take a backup and then delete the other's during rotation. It captures an existing regular source without following symlinks and atomically replaces the target pathname from a same-directory stage. A concurrent regular-file edit by something other than setup, landing after its final comparison, can still be replaced; recover from the retained backup.

Runtime requires `bash`, `awk`, and standard POSIX/BSD/GNU macOS/Linux userland used by the scripts: `cat`, `cksum`, `cmp`, `cp`, `date`, `dd`, `dirname`, `grep`, `kill -0`, `ln`, `ls`, `mkdir`, `mktemp`, `mv`, `rm`, `rmdir`, `sed`, `sleep`, `sort`, `stat`, `tail`, `tr`, and `wc`. The implementation handles BSD/GNU `date`, `stat`, and `mktemp` conventions where they differ. `jq` is optional; Stop has a fallback serializer.

## Development

The automated suite has a **test-only Python 3 dependency** for structural JSON parsing; the shipped runtime does not. Bash, dash, shellcheck, Git, and Python 3 are expected for full local verification. Run the complete suite under both supported shells:

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
