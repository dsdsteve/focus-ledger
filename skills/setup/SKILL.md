---
description: Install (or remove) the "offer to park when I pivot off an unfinished thread" behavior as a managed block in CLAUDE.md. Use when the user says "set up focus-ledger", "turn on the pivot nudge", "offer to park when I change topics", or specifically asks to remove/update that managed block.
argument-hint: [local | global | remove]
allowed-tools: Bash, AskUserQuestion
---

Scripts live in `${CLAUDE_PLUGIN_ROOT}/scripts/` in Claude Code. Outside Claude Code (for example in Kiro) `${CLAUDE_PLUGIN_ROOT}` is not set, so use `~/.kiro/skills/focus-ledger-shared` in its place.

Install the one focus-ledger behavior that can't be a hook: when the user pivots off an unfinished thread, the assistant offers (in one line) to park the old one. It lives as a managed, idempotent block in CLAUDE.md — re-running updates it in place; removing takes it out cleanly.

Requested: what the user asked for in their message.

Steps:

1. **If the request already says the scope**, skip the question:
   - contains `remove`/`off` and clearly refers to the pivot/setup block → removal (use the scope word if given, else `local`).
   - contains `global` → install global. contains `local` → install local.
   - bare `uninstall` refers to the plugin, not this managed block. Explain that setup removal only removes the CLAUDE.md pivot instruction; do not silently translate plugin uninstall into `--remove`.

2. **Otherwise ask once** (with AskUserQuestion where available, otherwise as one plain question) — this edits the user's CLAUDE.md, so which file is genuinely their call:
   - Question: "Install the focus-ledger pivot-park nudge where?"
   - Options: `Local — this project's CLAUDE.md (recommended)`, `Global — ~/.claude/CLAUDE.md, every project`, `Remove it instead`.

3. **Run the bundled script** with the resolved choice and retain its exit code and output:

   ```bash
   # install:
   "${CLAUDE_PLUGIN_ROOT}/scripts/focus-setup.sh" <local|global>
   # remove:
   "${CLAUDE_PLUGIN_ROOT}/scripts/focus-setup.sh" <local|global> --remove
   ```

   Before creating a parent, target, backup, or staging rewrite, the script refuses a symlinked `CLAUDE.md`, captures an existing regular target without following a later link swap, and validates the `<!-- FOCUS-LEDGER:BEGIN ... -->` / `<!-- FOCUS-LEDGER:END -->` structure. Symlinked targets plus unmatched, nested, unclosed, same-line, or duplicate managed blocks refuse with exit 3 and preserve target bytes and existing backups. For an accepted install/update or removal of an actually present managed block, setup byte-verifies a timestamped backup named `<CLAUDE.md>.focus-bak.<epoch>.<suffix>`, rotates the prior generation, and atomically replaces the target pathname from a same-directory stage. Removing a missing or existing marker-free target is a true no-op. The script does NOT touch hooks or settings; the plugin registers those itself.

4. **Report according to the exit code:**
   - Exit 0: relay both script output lines: the install/remove result and the backup/undo pattern. Do not infer that a backup exists for a missing-target or marker-free removal; only an existing target whose managed block is installed, updated, or removed is backed up. For an install, mention that it applies next session. The block is managed — re-run `/focus-ledger:setup` to update it, or `remove` to take it out.
   - Exit 3: report the refusal and relay the script's recovery guidance. Do not claim a backup, path creation, mtime change, or rewrite occurred.
   - Any other nonzero exit: report that setup failed and do not claim success.
