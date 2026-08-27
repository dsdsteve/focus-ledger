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
| `<CLAUDE.md>.focus-bak.<epoch>` | Setup recovery copy. An accepted setup run rotates older matching copies before rewriting. |

These files are plaintext, not encrypted by the plugin. Some creation paths inherit the caller's umask rather than forcing a private mode. Protect the containing directories and files with permissions appropriate to their content, and do not rely on focus-ledger for secret storage.

Doctor and tidy do not purge the retained archive or successful tidy ledger backups; completed text can remain there indefinitely. After ensuring no focus-ledger command is running, users who no longer need that history must inspect and remove only the exact regular archive/backup files they select. Avoid broad globs around active lock or transaction paths. Accepted setup runs separately rotate their own `.focus-bak.*` files to one generation.

### Transient state

The plugin can create and normally remove:

- `<target>.lock/owner` and `<target>.lock.reap/owner` for ledger, snooze, and cooldown operations;
- `focus-ledger-archive.md.lock/owner` for tidy archive publication;
- ledger stages `focus-ledger.md.tmp.<pid>.XXXXXX` and optional `.trim` files;
- marker stages `<marker>.tmp.<pid>`;
- tidy ledger/archive stages, `.verify*` snapshots, `.archive-lines.*`, an archive transaction backup, and `.rollback.*` files;
- tidy deletion quarantine `<original>.tidy-delete.<pid>` plus `.restore` recovery copies;
- one implementation-selected system temporary file during setup.

A crash or uncatchable interruption can leave these artifacts. Doctor reports the ledger lock/reap directories, snooze and last-nudge marker state, managed-block files, and `focus-ledger.md.*` adjacent artifacts; it does not inventory archive-adjacent files, marker lock/temp/quarantine paths, or setup temps. Tidy removes only narrowly classified stale regular ledger-rewrite temps and expired regular markers after verification; unknown artifacts require manual inspection.

## Confirmation and recovery behavior

- `doctor` is strictly read-only: it acquires no lock, creates no scratch file, and never repairs or removes anything. It reports malformed lines and unsafe paths with explicit hand-fix guidance.
- Tidy report mode is also read-only. `/focus-ledger:tidy` asks once and invokes apply only for an answer that is exactly `yes`, case-insensitively and without qualification. Directly invoking `focus-tidy.sh --apply` bypasses that prompt-level gate.
- Tidy apply locks and re-derives current candidates, creates and verifies a same-directory ledger backup, stages archive and ledger replacements, publishes each separately, and post-verifies raw-record multisets. Eligible completed records are archived, not deleted. On a handled failure it attempts to restore ledger, archive, and quarantined cleanup targets; an incomplete rollback names the retained ledger backup.
- Setup validates managed-block marker depth before rotating a backup or rewriting content. Malformed, nested, or unclosed markers return status 3 with file content and existing backups unchanged, plus recovery instructions. The script creates/touches the target before scanning, so refusal can still create the path or update its mtime. For recovery, restore the newest `.focus-bak.*` if available or hand-delete only the partial managed block before retrying.
- Park status 0 means its exact dated line was observable after publication; status 1 means the write could not be verified and status 2 means the normalized input was empty. Exact-line verification cannot distinguish a newly written duplicate from an identical pre-existing record, so retrying after an uncertain crash can duplicate an item.

## Unsafe path handling

Path defenses are operation-specific; there is no general filesystem sandbox:

- Doctor does not follow ledger or `CLAUDE.md` symlinks and reports symlink/nonregular ledger, marker, lock, and temp paths.
- Tidy refuses unsafe or unreadable ledger, archive, marker, generated backup, and eligible temp paths before mutation. Its stages and backups must be regular non-symlinks.
- The shared snooze/cooldown marker publisher removes an unsafe destination pathname and renames a private regular temp into place; it does not write through a destination symlink or FIFO.
- Ordinary ledger commands, SessionStart, Stop's legacy snooze read, and setup do not all enforce the doctor/tidy refusal policy. They assume trusted user-owned path topology. A ledger or `CLAUDE.md` symlink may be read, replaced, or in some missing-path cases followed. Stop can follow a snooze symlink to a regular target when reading and removes the link pathname if it is expired. Do not point plugin state or setup targets at sensitive files; run doctor before maintenance when path provenance is uncertain.

## Residual failure limits

- Same-directory rename and append provide process-level single-file publication. The runtime does not `fsync` file contents or parent directories, so status 0 is not a power-loss durability guarantee.
- Tidy has no cross-file atomic transaction. Archive is published before ledger; power loss between those renames can leave the same completed record in both files, and a retry can archive it again.
- Recovery traps cover `INT`, `TERM`, and `HUP`, not `SIGKILL`, shell/runtime failure, or machine power loss. Rollback is best effort.
- Lock ownership is PID-only. PID reuse can make an abandoned lock or temp look active, conservatively preventing reaping or cleanup until inspected.
- Park can fall back to one append-only write when cooperative locking/publication cannot proceed. This protects existing bytes but can leave the record outside a required section for doctor/tidy to report or re-home.
- Setup has no lock and rewrites by redirection. Concurrent setup/manual edits or an interruption can truncate the target; use the retained backup to recover.

The implementation is intentionally small (`hooks/`, `scripts/`, `commands/`) and is worth reviewing before trusting it on your machine.

## Supported versions

Fixes land on the latest release. There's no back-porting to older tags.
