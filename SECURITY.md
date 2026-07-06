# Security

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue. Use GitHub's [private vulnerability reporting](https://github.com/dsdsteve/focus-ledger/security/advisories/new) (Security tab → Report a vulnerability), or open a minimal issue asking for a private contact and details will be exchanged from there.

You'll get an acknowledgement, and a fix or explanation once the report is assessed.

## What this plugin does and doesn't do

Useful context when judging impact:

- The hooks and scripts make **no network calls** — everything is local file I/O and text output.
- They **write only under `~/.claude/`** (the ledger, a snooze marker, and a transient lock file during `park`). The only write elsewhere is `/focus-ledger:setup`, which you invoke by hand — it edits a `CLAUDE.md` (project-local or `~/.claude/`) and backs it up first.
- They **read only** the ledger at `~/.claude/focus-ledger.md`.
- Ledger text is **parsed as data, never executed** — the staleness check does its date math in `awk`, so nothing from the file reaches a shell.
- `SessionStart` puts your parked items into the model's context, so treat the ledger like anything else in a conversation: don't park secrets.

The scripts are short (`hooks/`, `scripts/`) and worth a read before you trust them on your machine.

## Supported versions

Fixes land on the latest release. There's no back-porting to older tags.
