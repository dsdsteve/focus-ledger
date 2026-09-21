# Security

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue. Use GitHub's [private vulnerability reporting](https://github.com/dsdsteve/focus-ledger/security/advisories/new) (Security tab → Report a vulnerability), or open a minimal issue asking for a private contact and details will be exchanged from there.

You'll get an acknowledgement, and a fix or explanation once the report is assessed.

## Trust boundary

The plugin makes **no network calls**. Its trust boundary still includes the local filesystem, executable resolution, Claude Code, and the configured model provider:

- `CLAUDE_PLUGIN_ROOT` selects plugin code; `HOME`, `PWD`, and `PATH` select state paths and executables. Treat those inputs and the installed plugin files as trusted code/configuration.
- Ledger items are untrusted, inert text. The shell never evaluates an item, and dynamic values reach awk through environment data rather than generated source. Command prompts relay escaped TSV records; they do not execute fields returned by list, match, doctor, or tidy.
- SessionStart automatically puts parked lines into model context. Stop may put up to three stale item texts into a `systemMessage`. Invoked commands also return ledger text, candidates, or diagnostic/report rows to the model. **Do not park secrets**, including credentials, private keys, tokens, passwords, or sensitive customer data.
- Setup installs model instructions in `CLAUDE.md`; the managed text can influence future sessions. Inspect it before enabling it globally.
- Hooks never return a deny decision. PreToolUse is silent unless `FOCUS_WRITE_CHECK=on|strict`; `strict` asks through the ordinary permission flow.

## Read and write surface

Automatic hooks read the ledger and snooze/cooldown state. Explicit commands can additionally inspect setup `CLAUDE.md` files, the archive, lock metadata, markers, and ledger-adjacent artifacts.

### Retained state

| Path | Access |
|---|---|
| `~/.claude/focus-ledger.md` | Read by hooks/commands; created or changed by park, resume, done, and tidy. |
| `~/.claude/focus-ledger-archive.md` | Read and changed only by explicit tidy apply when completed records are eligible. |
| `~/.claude/.focus-snooze` | Written by snooze; read by Stop/doctor/tidy; an expired numeric marker may be removed by Stop or tidy. |
| `~/.claude/.focus-last-nudge` | Written by Stop; read by Stop/doctor/tidy; an expired numeric marker may be removed by tidy. |
| `~/.claude/focus-ledger.md.backup.YYYYMMDDTHHMMSS.XXXXXX` | Verified tidy recovery backup, intentionally retained after a successful apply. |
| `./CLAUDE.md` or `~/.claude/CLAUDE.md` | Read by doctor and changed only by explicit setup/update/remove. |
| `<CLAUDE.md>.focus-bak.<epoch>.<suffix>` | Setup recovery copy. A new generation is byte-verified before an accepted setup run rotates older matching copies. |

These files are plaintext, not encrypted by the plugin. Some creation paths inherit the caller's umask rather than forcing a private mode. Protect the containing directories and files with permissions appropriate to their content, and do not rely on focus-ledger for secret storage.

Doctor and tidy do not purge the retained archive or successful tidy ledger backups; completed text can remain there indefinitely. Uninstalling/disabling plugin code also leaves the ledger, archive, markers, managed setup block, and every recovery generation intact. After ensuring no focus-ledger command is running, users who no longer need that history must first remove any managed block with setup, then inspect and remove only the exact regular ledger/archive/marker/backup files they select. Avoid broad globs around active lock or transaction paths. Accepted setup runs separately rotate their own `.focus-bak.*` files to one generation.

### Transient state

The plugin can create and normally remove:

- `<target>.lock/owner`, `<target>.lock.reap/owner`, and pre-publication `<target>.lock.claim.<pid>` / `<target>.lock.reap.claim.<pid>` state for ledger, snooze, cooldown, and archive locking;
- ledger stages `focus-ledger.md.tmp.<pid>.XXXXXX` and optional `.trim` files;
- marker stages `<marker>.tmp.<pid>`;
- tidy ledger/archive stages, `.verify*` snapshots, `.archive-lines.*`, an archive transaction backup, and `.rollback.*` files;
- tidy deletion quarantine `<original>.tidy-delete.<pid>` plus `.restore` recovery copies;
- a private no-follow source snapshot and same-directory output stage while setup builds and publishes canonical output.

A crash or uncatchable interruption can leave these artifacts. Doctor conservatively reports ledger/archive/marker lock and claim state, snooze/cooldown marker state, managed-block files, eligible versus legacy ledger-adjacent temps, and common archive transaction leftovers. It deliberately excludes retained successful tidy ledger backups and does not inventory arbitrary paths or setup temps. Tidy removes only narrowly classified stale regular PID-bearing ledger-rewrite temps and expired regular markers after verification; unknown artifacts require manual inspection.

## Confirmation and recovery behavior

- `doctor` is strictly read-only: it acquires no lock, creates no scratch file, and never repairs or removes anything. It reports malformed lines and unsafe paths with explicit hand-fix guidance.
- Tidy report mode is also read-only. `/focus-ledger:tidy` requires a complete report ending in `SUMMARY`, refuses any `BLOCK`, asks once, and invokes apply only for an answer whose entire content is the standalone word `yes` (case-insensitive). Directly invoking `focus-tidy.sh --apply` bypasses that prompt-level gate. Missing/empty ledgers are no-ops that do not clean markers or temps.
- Tidy apply locks and re-derives current candidates, creates a verified ledger backup only when ledger/archive bytes will change, stages archive and ledger replacements, and post-verifies raw-record multisets plus duplicate-aware Parked placement. Eligible completed records are archived, not deleted. Handled pre-commit failures attempt rollback while deferring a second catchable signal; incomplete recovery preserves and names actual surviving backups/quarantine copies. Quarantine renames commit volatile deletion, so later unlink/lock/work cleanup failure returns nonzero `verified-with-artifacts` with exact retained paths rather than attempting an impossible rollback.
- Setup validates managed-block marker depth and refuses a symlinked or non-regular `CLAUDE.md` before creating directories, targets, backups, or rewrite stages. A FIFO or device target is refused by type before the snapshot read, which would otherwise block on the open. Unmatched, nested, unclosed, same-line, and duplicate blocks return status 3 with target existence, bytes, mtime, and existing backups unchanged. Existing regular targets receive a timestamped, byte-verified backup before older generations rotate; missing-target and marker-free removal create nothing. For recovery, restore the newest `.focus-bak.*` if available or hand-delete only the partial managed block before retrying.
- Park status 0 means its exact dated line was observable after publication; status 1 means the write could not be verified and status 2 means the normalized input was empty. Exact-line verification cannot distinguish a newly written duplicate from an identical pre-existing record, so retrying after an uncertain crash can duplicate an item.

## Unsafe path handling

Path defenses are operation-specific; there is no general filesystem sandbox:

- Doctor does not follow ledger or `CLAUDE.md` symlinks and reports symlink/nonregular ledger, marker, lock, claim, temp, archive, and archive-artifact paths. It rejects `HOME`/`PWD` containing TSV record separators. It also reports an unwritable ledger directory and a missing `cmp`, `sort`, `cksum`, or `mktemp`, the preconditions tidy apply enforces, so its clean result covers whether apply can run.
- Tidy refuses unsafe or unreadable ledger, archive, marker, generated backup, and eligible temp paths before mutation, and rejects `HOME` containing tab/newline separators before report or apply. Its stages and backups must be regular non-symlinks.
- Park/list/match/resume/done refuse unsafe ledgers, while Stop stays silent; Stop classifies snooze/cooldown markers without following unsafe paths. The shared marker publisher removes an unsafe destination pathname and renames a private regular temp into place.
- SessionStart retains a legacy regular-file check. Setup refuses a symlinked or non-regular `CLAUDE.md` before reading or rewriting it. Do not point SessionStart paths at sensitive files; run doctor before maintenance when path provenance is uncertain.

## Residual failure limits

- Same-directory rename and append provide process-level single-file publication. The runtime does not `fsync` file contents or parent directories, so status 0 is not a power-loss durability guarantee.
- Tidy has no cross-file atomic transaction. Archive is published before ledger; power loss between those renames can leave the same completed record in both files, and a retry can archive it again.
- Recovery traps cover `INT`, `TERM`, and `HUP`, not `SIGKILL`, shell/runtime failure, or machine power loss. A second catchable signal is deferred while rollback restores state and releases locks. Rollback is best effort; incomplete recovery preserves and names actual surviving recovery paths.
- Lock ownership is PID-only. PID reuse can make an abandoned lock or temp look active, conservatively preventing reaping or cleanup until inspected.
- Park can fall back to one append-only write when cooperative locking/publication cannot proceed. This protects existing bytes but can leave the record outside a required section for doctor/tidy to report or re-home.
- Setup serializes concurrent runs on its target with the shared lock the ledger verbs use, so two runs cannot each take a backup and then delete the other's during rotation. It captures an existing regular source without following symlinks and atomically replaces the target pathname from a same-directory stage. A concurrent regular-file edit by something other than setup, landing after its final comparison, can still be replaced; use the retained backup to recover.

The implementation is intentionally small (`hooks/`, `scripts/`, `commands/`) and is worth reviewing before trusting it on your machine.

## Supported versions

Fixes land on the latest release. There's no back-porting to older tags.
