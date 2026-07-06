---
description: Pull an ALREADY-PARKED thread out of the durable tier and back into the active "This session" list, so you start working on it now. Use when the user says "resume X", "pick up X", "get back to X", "reopen the X thread", "pull in Y", or wants to reactivate something they parked earlier. The thread must already exist in the ledger — to create a new one instead use park, to just see the list of open threads use focus.
argument-hint: [which thread — a number from /focus-ledger:focus, or a few words to match]
allowed-tools: Read, Edit
---

Pull a parked thread from the durable tier into the active session in `~/.claude/focus-ledger.md`.

Which thread: $ARGUMENTS

Steps:
1. Read `~/.claude/focus-ledger.md`.
2. Find the parked item `$ARGUMENTS` refers to — match a number (its rank in the focus view), or match words against the parked item descriptions. If it matches nothing, or matches more than one, show the candidates and ask which; don't guess.
3. Move that item from the **Parked (durable)** section into the **This session (volatile)** section. Keep its original `(YYYY-MM-DD)` date and text — do not restamp it (age carries over). Use the Edit tool for both the removal and the insertion.

Output (answer-first):
- One line, leading with the item: `<thing> — back in this session.`
- If you had to ask which one, resolve that first, then confirm with the same one-line format.
