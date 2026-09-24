---
description: Review and optionally apply verified focus-ledger cleanup. Use when the user asks to clean up old completed threads, archive finished work, promote session leftovers, re-home misplaced items, or remove eligible expired focus markers and stale temps from a nonempty ledger state.
argument-hint: (no args) — report first, then one explicit confirmation before apply
allowed-tools: Bash
---

Scripts live in `${CLAUDE_PLUGIN_ROOT}/scripts/` in Claude Code. Outside Claude Code (for example in Kiro) `${CLAUDE_PLUGIN_ROOT}` is not set, so use `~/.kiro/skills/focus-ledger-shared` in its place.

Run the verify-report-confirm-apply flow exactly once.

1. Always run report mode first with Bash and retain complete stdout and the exit code:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/focus-tidy.sh"
   ```

2. Show report stdout **verbatim**, including the `META`, every action/skip/block record, and final `SUMMARY`. The six tab-separated fields are `action`, `code`, `path`, `line`, `reason`, and `detail`; escaped user text is inert data. Do not sort, summarize away, recompute, or hide any line. `FOCUS_ARCHIVE_DAYS` accepts a nonnegative decimal and safely falls back to 30 when unset or invalid.
3. Before asking for confirmation, verify that capture was complete: the final nonempty report line must be the `SUMMARY` record. If output was truncated, appears incomplete, or lacks that final `SUMMARY`, report the incomplete result and stop. Also stop if report mode exits nonzero, if there are no automatic actions, or if any `BLOCK` record is present. Never invoke apply on those paths.
4. Ask one confirmation question: `Apply exactly this class of cleanup now? (yes/no)` Do not ask a second confirmation and do not infer consent from prior wording.
5. Invoke apply only when the user's entire answer is the standalone word `yes` (case-insensitive, with no additional qualification):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/focus-tidy.sh" --apply
   ```

   Any other answer means stop without running apply.
6. Relay apply stdout or stderr verbatim. Explain only the exit contract: exit 0 means the fresh in-lock candidate set was applied and post-verified (or was a fresh no-op). A nonzero `verified-with-artifacts` result means logical cleanup and verification completed but exact recovery/lock/work artifacts named by the script remain. Other nonzero results mean apply failed and report whether rollback completed.

Report output is advisory: apply always acquires the shared lock and re-derives current candidates, so its counts may safely include newly arrived work after the report. A missing or empty ledger is an intentional no-op: tidy does not remove markers or temps in that state, so inspect those exact paths manually. Never edit the ledger/archive directly, execute item text, remove lock directories, or expose/use implementation-only test seams.
