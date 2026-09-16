# Design notes

Why the tool looks like this. The README says what it does; this says what was
tried first, what the data actually allows, and which shapes are load-bearing.

## Why the quick terminal

Every other place a quota could live was tried against real Ghostty first:

| Location | Outcome |
|---|---|
| Window title | In Ghostty the window title **is** the selected tab's title — one string, not two fields (`name of front window` == `name of selected tab`). Forcing it through the `title` config replaces every tab's name; appending to it loses to Claude Code, which rewrites the title as it works. Sampled from a separate process while a session ran: an appended suffix survived in 1 of 60 samples. |
| Menu bar | One line, and the notch caps the width. The full reading is ~44 characters; legible sizes did not fit, and the reduced variants (5h only, or two lines cycling) lost the information that made it worth having. |
| Terminal background image | Global and uninterruptible — no program can overwrite it — but it sits behind terminal content and gets covered by it. |
| `window-subtitle` | The right architecture: a window-level property nothing else writes. Unimplemented on macOS and limited to `working-directory`, so it would need an upstream change. |

The quick terminal wins because `GHOSTTY_QUICK_TERMINAL=1` is set only in that
surface, so a shell hook can hand over to the panel there and nothing competes
for the space. `quick-terminal-autohide` already means "hide when focus leaves",
which is the dismiss behaviour for free.

`quick-terminal-position` needs a full Ghostty restart on macOS, not a config
reload — worth knowing before promising a layout change takes effect.

## What the data allows

Neither agent can be asked for its quota. Both numbers are residue:

- **Claude Code** hands the 5h/7d windows to its status line command on stdin
  and writes nothing to disk, so `statusline-tap` has to occupy that slot.
  `rate_limits` is absent from the first call of every session and from
  API-key sessions entirely.
- **Codex** records `payload.rate_limits` in its own session rollouts. The
  window is named by its own `window_minutes`, not by its `primary`/`secondary`
  position, and the snapshot carries a `limit_id` quota bucket — only the
  general `codex` bucket describes the account. A single account can carry both
  `codex` and `premium` snapshots, so the filter is not hypothetical.

Consequences that shape the code:

- **Two timestamps.** `observed_at` advances on every tap write and answers "is
  this number current"; `taken_at` advances only when a value changes and
  answers "when did usage last move". Staleness comes from the first. Coralline
  as a source can only supply the second, so it never claims liveness.
- **High-water merge.** A status line re-runs on a timer, so an idle session
  republishes its old numbers. Without a high-water rule the displayed
  percentage walks backwards. Within one window the higher value wins; a later
  reset beats any earlier one; a window whose reset has passed takes no part on
  either side of the merge.
- **A reading can be void, not merely old.** Past its own reset it describes a
  window that no longer exists, so it reports `–`. Ahead of the clock by more
  than a minute it says nothing about age at all, so it reports skew and counts
  as stale.

## Three incidents worth keeping

1. **A panel process ran for two days** across a JSON contract change and drew
   every window as absent. Nothing was broken; the panel was old. The guard now
   checks the fields it reads — a first version that checked only the outer keys
   would still have passed a renamed `used_pct` straight through.
2. **Renaming tabs by terminal index** mislabelled every tab after the one with
   a split (13 tabs, 14 terminals). Ghostty surfaces are walked by `tabs`.
3. **A self-masking test.** Checking that the tap and reader agreed on a naive
   ISO reset appeared to pass, because the test's timestamp was in the past and
   an expiry rule added in the same batch discarded it first. It reproduced only
   with a future timestamp.

## Deliberately not done

`CODEX_HOME` / `CLAUDE_CONFIG_DIR`; picking the newest event per window instead
of per snapshot; unifying the JSON `resets_at` int/float types; following
Ghostty `config-file` includes (the installer refuses to auto-edit and prints
the settings instead); making the panel's draw atomic against a signal arriving
mid-flush. Each is in the README's Known limitations. Disagreeing with one is a
fine thing to raise; implementing it silently is not.
