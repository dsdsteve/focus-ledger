# Changelog

All notable changes to focus-ledger are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); this project uses
[semantic versioning](https://semver.org/).

## [1.3.0] — 2026-09-24

### Added
- A UserPromptSubmit hook backs up the pivot-park instruction that `setup`
  installs. When a message announces an aside with `sidenote`, `side note`, or
  `btw`, it adds one fixed line reminding the model to offer to park an
  unfinished thread. The prose instruction alone failed on exactly this case:
  an announced aside read as not a real pivot and then grew into its own
  thread. The hook decides only that the user flagged a switch; whether the
  earlier thread is unfinished stays the model's call. It matches three words,
  so an unannounced topic change still relies on the instruction. It reads
  prompt text, stores and transmits nothing, and never blocks.

### Fixed
- README's recovery-limits list said setup has no lock after 1.2.2 gave it
  one, contradicting SECURITY.md and this changelog.

## [1.2.2] — 2026-09-21

### Fixed
- Doctor and `tidy --apply` no longer disagree about whether an install is
  usable. Doctor now reports an unsafe or unreadable archive path, a ledger
  directory it cannot write, and a missing `cmp`, `sort`, `cksum`, or `mktemp`.
  Each of those made apply refuse with status 2 after doctor had printed
  `all-clean` and exited 0, and in two of them apply's own error told the
  operator to run doctor.
- A lapsed nudge-cooldown marker no longer counts as a finding. The Stop hook
  writes `now+FOCUS_NUDGE_COOLDOWN` to `.focus-last-nudge` and never removes
  it, so every install that had nudged in the past exited 1 and suppressed the
  `all-clean` line. It reports as `INFO` now. The user-created snooze marker
  still reports its expiry as a finding.
- Artifacts focus-ledger itself creates during an interrupted run are reported
  as `*-interrupted` rather than described as legacy or manual files. One
  shared predicate now drives all three adjacent-artifact scans, which
  previously each carried a hand-written exclusion list covering only `.lock`
  paths and so missed the `.tidy-delete.*` namespace entirely.
- A pending lock claim written without a trailing newline is no longer reported
  as unreadable at status 2. POSIX `read` returns nonzero at end of file
  without a delimiter even though the token is populated, which the sibling
  lock-owner handler already tolerated.
- Guarded ledger rewrites preserve the ledger's existing permission bits. Park,
  resume, done, snooze, and tidy apply staged through `mktemp`, which forces
  0600, and the publishing `mv` carried that mode onto the ledger, silently
  retightening a file the user had deliberately widened.
- Setup refuses a non-regular `CLAUDE.md` by type before reading it. A FIFO or
  device target is not a symlink, so the existing refusal missed it and the
  snapshot `cp` blocked on the open indefinitely.
- Setup serializes concurrent runs on its target with the shared lock the
  ledger verbs use. Two overlapping runs each took a backup and then each
  rotation loop deleted the other's, destroying the losing run's only recovery
  copy of the original. Reusing the shared lock brings stale-lock reaping with
  it, so a killed setup does not wedge the next run.
- Tidy's lock-acquisition failure names the real cause. `mkdir` fails for
  reasons other than contention, and blaming an existing owner for an
  unwritable directory sent the operator looking for a lock that was never
  created.

## [1.2.1] — 2026-08-25

### Fixed
- Setup removal against an existing marker-free `CLAUDE.md` is now a true
  no-op: target bytes and metadata plus existing recovery backups remain
  unchanged. Setup also refuses symlinked targets before reading, backing up,
  or rewriting through them.
- Tidy archive-stage read failures now return through owned cleanup instead of
  exiting around lock release and transient-backup removal.
- SessionStart neutralizes ASCII control bytes in a parked line before printing
  it, matching the stale and list output paths, so a hand-edited ledger cannot
  emit raw control sequences into the session context.
- Doctor now flags a same-line `<!-- FOCUS-LEDGER:BEGIN --> ... FOCUS-LEDGER:END -->`
  marker as an error, matching setup's refusal of that structure. The two tools
  no longer disagree about whether a same-line block is valid.
- Park into an empty existing ledger writes the full skeleton so the item lands
  inside Parked. It previously appended a section-less line that list and tidy
  could not see.
- Fresh setup installs publish `CLAUDE.md` at the umask-based mode a plain create
  produces instead of `mktemp`'s 0600, keeping a shared project file group- and
  other-readable. The no-follow source snapshot overwrites its staging file in
  place rather than deleting and recreating it, which closes a symlink-swap window.

## [1.2.0] — 2026-08-25

### Added
- Deterministic `focus-list.sh` and shared format-v1 parsing provide
  calendar-day ranking and safe TSV output; `resume` and `done` add explicit
  unique/no-match/ambiguity contracts; `snooze` validates and formats portable
  durations without model-side epoch arithmetic.
- Read-only `doctor` diagnostics for ledger structure, malformed records,
  setup markers, locks, markers, and adjacent artifacts.
- Report-confirm-apply `tidy` maintenance: verified archival of eligible
  completed records, session-item promotion, misplaced-open-item re-homing,
  expired marker cleanup, conservative stale-temp cleanup, and retained ledger
  recovery backups.
- Stop-hook cooldown state through `FOCUS_NUDGE_COOLDOWN` (default four hours),
  plus `FOCUS_ARCHIVE_DAYS` (default 30) for tidy eligibility.

### Changed
- The PreToolUse write nudge is now opt-in. `FOCUS_WRITE_CHECK=on` emits the
  soft note, `strict` asks through the ordinary permission flow, and unset,
  `off`, or other values are silent. Existing users who want the previous note
  must set `on`; there is no ledger migration. Default silence keeps an optional
  writing aid from appearing unless the user deliberately enables it.
- Command prompts now delegate ranking, matching, date math, mutation, and
  maintenance to bundled scripts instead of editing or interpreting ledger
  state freehand.

### Fixed
- Park no longer loses concurrent items around stale/slow locks or the
  append-versus-rename publication window, and status 0 now requires the exact
  dated line to be observable after writing.
- Setup validates managed-block markers before backup rotation or content
  rewrite, refusing malformed structures with status 3 instead of risking
  deletion of following user content.
- Resume and completion mutate only a unique current match under the shared
  lock and leave the ledger unchanged for no-match, ambiguity, or unverified
  publication paths.
- Stop removes an expired numeric snooze marker before ordinary stale-item
  evaluation and rate-limits repeated stale notices with the cooldown marker.
- Tidy now places every promoted/re-homed occurrence inside Parked before the
  first following H2, verifies that section invariant duplicate-aware, preserves
  non-cooperative pre-rename edits, avoids backups for cleanup-only applies, and
  reports retained recovery artifacts instead of claiming impossible rollback.
- Doctor now aligns stale-temp advice with tidy eligibility, treats source/stat/
  clock/relay failures as operational, inventories archive and marker lock crash
  blockers read-only, and gives truthful expired-marker guidance for missing or
  empty ledgers.
- Epic 1's park-concurrency, truthful-exit, and setup data-loss fixes are
  included in 1.2.0 and can be cherry-picked together as an unpublished
  `1.1.2` patch when a 1.1.x deployment needs only those fixes; maintained
  releases and ongoing fixes remain on the latest release line.

### Security
- Ledger-controlled text remains inert across list, match, SessionStart, Stop,
  doctor, and tidy; parser inputs use environment data and command prompts relay
  escaped TSV rather than executing returned fields.
- Marker publication replaces unsafe destination types without following them;
  doctor reports unsafe paths read-only, and tidy refuses unsafe ledger,
  archive, marker, backup, or cleanup targets before applying.
- Tidy stages and post-verifies exact raw-record multisets, quarantines volatile
  deletions until verification succeeds, and attempts rollback from verified
  backups on handled failures.

## [1.1.1] — 2026-07-09

### Fixed
- Stop hook: two or more stale items now join with `; ` as intended —
  `paste -sd '; '` treats `'; '` as a cycling delimiter *list* (`a;b c`),
  so the join is done in `awk` instead.
- Park: item text containing backslashes (e.g. a literal `\n`) is no longer
  mangled — the item reaches `awk` via `ENVIRON` instead of `-v`, which
  interprets escape sequences and would split the line.
- Hooks now skip `- [ ]` lines inside `<!-- -->` comment blocks, matching what
  the `focus` command already documented: commented format examples are no
  longer replayed at SessionStart or flagged stale by the Stop hook.
- Park: a stale lock left by a killed park is reaped after the wait window,
  instead of costing every future park the full 2s timeout forever.
- Setup: repeated runs keep only the latest `CLAUDE.md.focus-bak.*` backup
  instead of accumulating one per run in the project root.

### Changed
- Test fixtures use an `@TODAY@` placeholder (substituted at run time) so
  "fresh" items can't rot into stale as calendar time passes.

## [1.1.0] — 2026-07-06

### Added
- **`focus` `setup` command** and `scripts/focus-setup.sh`: installs the one
  behavior that can't be a hook — "offer to park the old thread when you pivot" —
  as a managed, idempotent block in `CLAUDE.md` (local or global), with a backup
  and a clean `--remove`. Replaces the old hand-paste instruction, which stays
  documented as a fallback. Pure shell + `awk`, no new dependency.
- `SECURITY.md` with a private disclosure channel and a plain statement of what
  the plugin can and can't touch.

## [1.0.0] — 2026-07-06

Initial release.

### Added
- **Commands**: `focus` (show ranked open threads), `park` (add a durable thread),
  `resume` (pull a parked thread into the session), `snooze` (mute the stale nudge).
- **Hooks** (all soft, never block): SessionStart replays parked threads;
  Stop emits a quiet note only when an item is stale (default 7 days);
  PreToolUse shows an optional pre-write check on `Write`/`Edit`.
- **Ledger**: a single hand-editable markdown file at `~/.claude/focus-ledger.md`,
  created on first `park`, with durable and this-session sections.
- **Tuning** via env: `FOCUS_STALE_DAYS`, `FOCUS_STOP_NUDGE`, `FOCUS_WRITE_CHECK`.
- Portable, POSIX-clean scripts — parked-date staleness is computed entirely in
  `awk` (no shell-out), `park` appends deterministically with a lock, and all
  scripts run under both `bash` and `dash`.
- Test suite (`test/run.sh`, dependency-free) and CI on macOS + Linux with `shellcheck`.
- Optional opt-in "offer to park on pivot" instruction documented in the README.
