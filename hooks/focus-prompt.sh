#!/bin/sh
# focus-ledger UserPromptSubmit hook: remind the model to offer parking when the
# user floats a side idea or announces an aside. Soft only: never blocks, always
# exits 0, and prints nothing unless a cue matches.
[ "${FOCUS_PROMPT_NUDGE:-}" = off ] && exit 0
in=$(cat) || exit 0

# Match the prompt field only. Claude Code and Kiro both send it as "prompt",
# alongside cwd and transcript paths that must not trigger a cue. JSON escapes
# are turned back into spaces so a cue at the start of a line still matches.
# The capture steps over escaped characters, so a quoted phrase inside the
# prompt (\"like this\") does not end the match early.
p=$(printf '%s' "$in" |
  sed -nE 's/.*"prompt"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' |
  sed 's/\\[nrt"]/ /g')
[ -n "$p" ] || exit 0

b='(^|[^[:alpha:]])'
e='([^[:alpha:]]|$)'
# An idea wins over an aside: "btw, would be nice to have X" is an idea to
# park, not a pivot away from the current task.
if printf '%s' "$p" | grep -qiE "${b}(would be nice|nice to have|someday|feature idea|might need (a )?new fea?ture)${e}"; then
  echo 'User floated a side idea. Keep the current task, and offer in one line to park the idea.'
elif printf '%s' "$p" | grep -qiE "${b}(side ?note|btw)${e}"; then
  echo 'User flagged a topic switch. If the previous thread is unfinished, answer this, then offer in one line to park it.'
fi
exit 0
