---
description: Hide the stale-thread nudge for a while (default 1 day) by writing a snooze timestamp the Stop hook respects. Use when the user says "snooze the nudge", "quiet the reminders", "stop nagging me about open threads for a bit", or wants to mute the focus stale-thread pings temporarily.
argument-hint: [duration like 1d, 4h, 30m — default 1d]
allowed-tools: Bash
---

Silence the focus stale-thread nudge for a while by writing a future Unix epoch to `~/.claude/.focus-snooze`. The Stop hook stays silent while that epoch is in the future.

Duration requested: $ARGUMENTS

Steps:
1. Parse the duration from the argument. Accept `Nd` (days), `Nh` (hours), `Nm` (minutes). If empty or unparseable, default to `1d`.
2. Compute the target epoch = now + that duration. Use the Bash tool, e.g. for `4h`:
   `echo $(( $(date +%s) + 4*3600 )) > ~/.claude/.focus-snooze`
   (seconds per unit: d=86400, h=3600, m=60.)
3. Confirm in one line, showing when it lifts:
   `Nudge snoozed for <duration> (until $(date -r $(cat ~/.claude/.focus-snooze) '+%Y-%m-%d %H:%M')).`

To un-snooze early: `rm ~/.claude/.focus-snooze`.

Note: the `date -r` epoch-to-date form is BSD/macOS. On GNU/Linux use `date -d @<epoch>`.
