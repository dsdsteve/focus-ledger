---
description: Hide the stale-thread nudge for a while (default 1 day) by writing a snooze timestamp the Stop hook respects. Use when the user says "snooze the nudge", "quiet the reminders", "stop nagging me about open threads for a bit", or wants to mute the focus stale-thread pings temporarily.
argument-hint: [positive duration like 1d, 4h, 30m — default 1d]
allowed-tools: Bash
---

Snooze the stale-thread nudge through the deterministic command layer.

Duration requested: $ARGUMENTS

Pass `$ARGUMENTS` as one argv value using safe shell quoting and run `${CLAUDE_PLUGIN_ROOT}/scripts/focus-snooze.sh` with Bash. Never interpolate the duration into executable shell syntax. Retain the exit code and stdout.

- Exit 0: relay the success line exactly.
- Exit 2: report that the duration must be a positive `Nd`, `Nh`, or `Nm`; do not claim the nudge was snoozed.
- Any other nonzero exit: report that snoozing failed and the previous marker was left unchanged.

An empty argument defaults to `1d`. Do not compute epochs or format dates in the prompt. The script validates the duration, writes the marker safely, and handles BSD/GNU date behavior.
