#!/bin/bash
# Wire the panel into your shell and Ghostty.
#
# Every edit is additive and marked, so re-running changes nothing and an
# existing binding, position, rc symlink or file mode is left as it is.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTKEY="$(printf '%s' "${AGENT_USAGE_HOTKEY:-cmd+shift+u}" | tr '[:upper:]' '[:lower:]')"
MARKER="agent-usage"

fail() { echo "✗ $*" >&2; exit 1; }

python3 -c 'import json, sys' 2>/dev/null \
  || fail "needs a working python3 (macOS: xcode-select --install)"

# Accept a single chord; config syntax must never enter through the hotkey.
python3 - "$HOTKEY" <<'PYHOTKEY'
import re, sys
parts = sys.argv[1].split("+")
aliases = {"cmd": "super", "command": "super", "opt": "alt", "option": "alt", "control": "ctrl"}
mods = [aliases.get(p, p) for p in parts[:-1]]
# A global binding without a modifier would swallow that key everywhere.
if (not mods
        or not re.fullmatch(r"[a-z0-9_]+", parts[-1])
        or any(p not in {"super", "ctrl", "alt", "shift"} for p in mods)
        or len(set(mods)) != len(mods)):
    raise SystemExit("✗ AGENT_USAGE_HOTKEY must be one chord with at least one"
                     " modifier, e.g. cmd+shift+u")
PYHOTKEY

if [ "$(uname)" = "Darwin" ]; then
  GHOSTTY_CONFIG="$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
  GHOSTTY_BIN="/Applications/Ghostty.app/Contents/MacOS/ghostty"
else
  GHOSTTY_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config.ghostty"
  GHOSTTY_BIN="$(command -v ghostty || true)"
  echo "! not macOS, and untested there: Ghostty's quick terminal needs Wayland's"
  echo "  layer-shell protocol and is not supported on GNOME, the global hotkey"
  echo "  needs the GlobalShortcuts portal (KDE 5.27+; not wlroots compositors"
  echo "  such as Sway), and quick-terminal-autohide defaults to off."
fi
if [ -x "$GHOSTTY_BIN" ]; then
  VERSION="$("$GHOSTTY_BIN" +version 2>/dev/null)" || fail "cannot read Ghostty version"
  python3 - "$VERSION" "$GHOSTTY_BIN" "$HOTKEY" <<'PYVERSION'
import re, subprocess, sys, tempfile
match = re.search(r"\b(\d+)\.(\d+)\.(\d+)", sys.argv[1])
if match is None:
    raise SystemExit("✗ cannot verify Ghostty version; need 1.3 or newer")
if tuple(map(int, match.groups())) < (1, 3, 0):
    raise SystemExit("✗ Ghostty 1.3 or newer is required")
print("✓ " + sys.argv[1].splitlines()[0])
# Ghostty owns the key vocabulary; validate without loading the user's config.
with tempfile.NamedTemporaryFile("w", suffix=".ghostty") as config:
    config.write("keybind = global:%s=toggle_quick_terminal\n" % sys.argv[3])
    config.flush()
    result = subprocess.run([sys.argv[2], "+validate-config", "--config-file=" + config.name],
                            capture_output=True, text=True)
    if result.returncode:
        raise SystemExit("✗ Ghostty rejected AGENT_USAGE_HOTKEY: " + (result.stdout + result.stderr).strip())
PYVERSION
else
  echo "! no ghostty binary found; version (requires 1.3+) and key names unchecked; writing configuration anyway"
fi

chmod +x "$HERE/agent-usage" "$HERE/quick-view" "$HERE/statusline-tap"

# ── Shell hook ──────────────────────────────────────────────────────────────
# The quick terminal is the only surface with GHOSTTY_QUICK_TERMINAL set, so the
# shell there hands over to the panel and every other shell is untouched.
case "$(basename "${SHELL:-/bin/zsh}")" in
  zsh)  RC="$(zsh -c 'print -r -- ${ZDOTDIR:-$HOME}')/.zshrc"; STYLE=posix ;;
  bash) RC="$HOME/.bashrc"; STYLE=posix
        echo "! bash: a login shell reads its profile, not .bashrc. Make sure your"
        echo "  profile sources ~/.bashrc, or move the block below into it." ;;
  fish) RC="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"; STYLE=fish ;;
  *)    RC=""; STYLE="" ;;
esac

if [ -z "$RC" ]; then
  echo "! unrecognised shell ($SHELL). Add this to your rc file by hand:"
  echo "    when GHOSTTY_QUICK_TERMINAL is set, exec $HERE/quick-view"
else
  python3 - "$RC" "$HERE/quick-view" "$STYLE" "$MARKER" <<'PY'
import os, shlex, stat, sys, tempfile
from pathlib import Path

rc, panel, style, marker = Path(sys.argv[1]).expanduser(), sys.argv[2], sys.argv[3], sys.argv[4]
begin, end = "# >>> %s >>>" % marker, "# <<< %s <<<" % marker
# Edit the file the link points at, so a managed dotfile keeps its symlink.
target = rc.resolve() if rc.is_symlink() else rc
text = target.read_text(encoding="utf-8", errors="surrogateescape") if target.exists() else ""
quoted = "'%s'" % panel.replace("'", "'\\''") if style == "fish" else shlex.quote(panel)
if begin in text:
    body = text.split(begin, 1)[1].split(end, 1)[0] if end in text else ""
    live = [l for l in body.splitlines() if not l.lstrip().startswith("#")]
    if any(quoted in l for l in live):
        print("✓ %s already has the hook" % rc)
    else:
        print("! %s has an agent-usage block with no exec line — delete the"
              " block and re-run" % rc)
    raise SystemExit

body = (["if set -q GHOSTTY_QUICK_TERMINAL; and test -x %s" % quoted,
         "    exec %s" % quoted, "end"] if style == "fish"
        else ['[ -n "${GHOSTTY_QUICK_TERMINAL:-}" ] && [ -x %s ] && exec %s' % (quoted, quoted)])
block = "\n".join([
    begin,
    "# Ghostty summons the quick terminal with a global hotkey; there it shows the",
    "# agent quota panel rather than a shell (`s` inside the panel still gets one).",
] + body + [end, "", ""])

target.parent.mkdir(parents=True, exist_ok=True)
mode = stat.S_IMODE(os.stat(target).st_mode) if target.exists() else 0o600
fd, tmp = tempfile.mkstemp(dir=str(target.parent))
try:
    os.fchmod(fd, mode)                      # never widen the rc file's permissions
    with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as handle:
        handle.write(block + text)
    os.replace(tmp, target)
except BaseException:
    os.path.exists(tmp) and os.unlink(tmp)
    raise
print("✓ hook added at the top of %s" % rc)
PY
fi

# ── Ghostty config ──────────────────────────────────────────────────────────
python3 - "$GHOSTTY_CONFIG" "$HOTKEY" "$MARKER" <<'PY'
import os, sys
from pathlib import Path

cfg, hotkey, marker = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
ALIASES = {"cmd": "super", "command": "super", "opt": "alt", "option": "alt", "control": "ctrl"}


def normalise(trigger):
    parts = [ALIASES.get(p.strip().lower(), p.strip().lower()) for p in trigger.split("+")]
    return "+".join(sorted(parts[:-1]) + parts[-1:])


# Ghostty loads both filenames and, on macOS, both config directories.
paths = {cfg, cfg.with_name("config")}
xdg = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "ghostty"
paths.update((xdg / "config", xdg / "config.ghostty"))
wanted, conflict, position_set, manual = normalise(hotkey), None, False, False
configs = {path: path.read_text(encoding="utf-8", errors="surrogateescape")
           if path.exists() else "" for path in sorted(paths)}
for path, text in configs.items():
    begin, end = "# >>> %s >>>" % marker, "# <<< %s <<<" % marker
    if begin in text:
        body = text.split(begin, 1)[1].split(end, 1)[0] if end in text else ""
        live = [l for l in body.splitlines() if not l.lstrip().startswith("#")]
        if any("toggle_quick_terminal" in l for l in live):
            print("✓ %s already has the hook" % path)
        else:
            print("! %s has an agent-usage block with no keybind — delete the"
                  " block and re-run" % path)
        raise SystemExit
for text in configs.values():
    for line in text.splitlines():
        active = line.strip()
        if active.startswith("#"):
            continue
        key, sep, value = active.partition("=")
        if not sep:
            continue
        key, value = key.strip(), value.strip()
        if key == "quick-terminal-position":
            position_set = True
        elif key == "config-file":
            manual = True
        elif key == "keybind":
            manual = True
            trigger, _, action = value.partition("=")
            prefixes = ("global:", "all:", "unconsumed:", "performable:")
            while trigger.startswith(prefixes):
                trigger = trigger.partition(":")[2]
            if trigger and normalise(trigger) == wanted:
                conflict = action.strip()

if manual:
    if conflict is not None:
        print("! %s is already bound to %s — left alone" % (hotkey, conflict))
    print("! Existing keybinds or config-file directives need manual review.")
    print("  Paste these settings only after checking all loaded configs:")
    print("    keybind = global:%s=toggle_quick_terminal" % hotkey)
    print("    quick-terminal-position = center")
    print("  Keep your existing position if preferred. Ghostty config left unchanged.")
    raise SystemExit

add = ["keybind = global:%s=toggle_quick_terminal" % hotkey]
if not position_set:
    add.append("quick-terminal-position = center")
else:
    print("✓ quick-terminal-position already set — left alone")

block = "\n".join([
    "", "# >>> %s >>>" % marker,
    "# A global hotkey summons the quick terminal, whose shell hands over to the",
    "# quota panel. With quick-terminal-autohide (the macOS default) it also",
    "# dismisses itself when you click outside.",
] + add + ["# <<< %s <<<" % marker, ""])
cfg.parent.mkdir(parents=True, exist_ok=True)
with cfg.open("a") as handle:                          # append only; nothing is replaced
    handle.write(block)
print("✓ added to Ghostty config: %s" % ", ".join(add))
PY

if [ "$(uname)" = "Darwin" ]; then
  if osascript -e 'if application "Ghostty" is not running then error "Ghostty is not running"' \
      -e 'tell application "Ghostty" to perform action "reload_config" on (first terminal of front window)' >/dev/null 2>&1; then
    echo "✓ Ghostty configuration reloaded"
  else
    echo "! Reload Ghostty configuration with cmd+shift+, after opening a window."
  fi
fi

# The value is pasted into JSON and then run through a shell, so it needs both
# shell quoting and JSON escaping.
TAP_JSON=$(python3 -c 'import json, shlex, sys; print(json.dumps(shlex.quote(sys.argv[1]))[1:-1])' "$HERE/statusline-tap")

cat <<NEXT

Claude Code keeps its limits nowhere on disk — it only hands them to the status
line — so something has to sit there. In ~/.claude/settings.json, either:

  A. no status line of your own yet
       "statusLine": { "type": "command", "command": "$TAP_JSON" }

  B. you already have one (its output is unchanged, it is only wrapped)
       "statusLine": { "type": "command", "command": "$TAP_JSON <program> <args>" }
       A shell command string needs a shell: ... "statusline-tap sh -c 'your | pipeline'"

  (Coralline users can instead set VL_LIMIT_SYNC=1 and skip the tap.)

Codex needs no setup: it already writes its limits into its own session files.

macOS global hotkeys need permission:
  System Settings → Privacy & Security → Accessibility → enable Ghostty

Current reading:
NEXT
"$HERE/agent-usage" --format detail || true
