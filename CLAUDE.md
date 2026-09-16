# ghostty-agent-usage-dashboard

A quota panel for Claude Code and Codex, summoned in Ghostty's quick terminal.
`DESIGN.md` explains why it is shaped this way — including the display locations
that were measured and rejected. It is worth reading before changing anything.

## The principle this project is built on

Neither agent has an interface for asking what your quota is. Every number here
is residue the agent left behind after it ran. So **honesty matters more than
polish**: a stale reading, a window that has already reset, a source that
reported nothing — each has to be said plainly rather than shown as a percentage
that no longer describes anything. `–`, `window has reset since` and `timestamp
ahead of this clock` are features, not error handling.

## Hard constraints

- **Python 3.9** (macOS's `/usr/bin/python3`). No `tomllib`, and `fromisoformat`
  rejects `+0000` and single-digit fractional seconds. Standard library only,
  no network access.
- **Four independent executables, no shared module** — installing means cloning
  the repository and running it. Because of that, `epoch()` in `agent-usage` and
  in `statusline-tap` **must stay byte-for-byte identical**: the two read and
  write the same cache, and any difference in parsing makes them reach different
  conclusions about the same record (this has happened).
- **`quick-view` is a long-lived process.** While the quick terminal stays open
  it is the same process, possibly across several updates. When the reader's
  JSON contract changes, the panel must **say that it cannot understand the
  output** rather than quietly render "no data" (this has happened: a panel that
  had been running for two days drew all four windows as `–`).
- **`install.sh` edits other people's shell rc and Ghostty config.** Only add
  inside the marker block; preserve existing bindings, positions, file
  permissions and symlinks; a re-run must have no side effects. This is the most
  delicate surface in the project.
- When walking Ghostty's surfaces, iterate `tabs`, not `terminals` — a tab with
  a split holds several terminals, so indexing by terminal shifts every label
  after that tab.

## Verifying

Run these after a change. Every one of them has caught a real regression.

```bash
./agent-usage --format detail        # both sources, live readings
./agent-usage --format json         # window states, skew, ages
for j in 'null' '[]' '{"rate_limits":null}' 'nope'; do \
  d=$(mktemp -d); printf '%s' "$j" > "$d/claude-rate-limits.json"; \
  AGENT_USAGE_STATE_DIR="$d" ./agent-usage --format detail | head -1; rm -rf "$d"; done
HOME=/tmp/nonexistent ./agent-usage --format detail
```

Behavioural checks (the reasoning behind them is in `DESIGN.md`): a pty with the
panel in an orphaned process group, three `SIGTSTP` in a row, then `q`; the tap
fed 45% and then 40% (the cache must keep 45); the tap fed an expired window over
a cached one that has no reset time (it must not replace it, and `taken_at` must
not advance); `install.sh` run twice against a sandbox HOME that holds a
conflicting binding, an existing position and a 0600 rc symlink.

When several changes land together, watch for tests masking each other — a parser
test once "passed" only because an expiry rule added in the same batch discarded
its input first. It reproduced only with a future timestamp.
