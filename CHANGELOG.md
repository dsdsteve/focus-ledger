# Changelog

All notable changes to focus-ledger are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); this project uses
[semantic versioning](https://semver.org/).

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
