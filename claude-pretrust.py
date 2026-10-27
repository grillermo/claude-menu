#!/usr/bin/env python3
"""Pre-trust a directory for Claude Code.

Claude Code asks "Do you trust the files in this folder?" the first time it
runs in a directory, and records the answer in the global config file as

    projects["<path>"].hasTrustDialogAccepted = true

where <path> is the realpath of the git repo root when the folder lives in a
git repo, and the realpath of the folder itself otherwise. The file lives at
``$CLAUDE_CONFIG_DIR/.claude.json`` (or ``~/.claude.json`` for the default
login). cswap profiles get their own copy under the cswap backup root.

This script writes that flag for a given directory into every global config
file this machine can hold, so the trust dialog never appears for that folder
again. It only merges -- it never rewrites or drops unrelated keys -- and it
writes atomically so a running Claude Code process never sees a torn file.

Usage:
    claude-pretrust.py [directory]     # defaults to the current directory
"""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
import tempfile


def _realpath(path: str) -> str:
    return os.path.realpath(os.path.abspath(os.path.expanduser(path)))


def git_root(directory: str) -> str | None:
    """Realpath of the git repo root containing directory, or None."""
    try:
        out = subprocess.run(
            ["git", "-C", directory, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    top = out.stdout.strip()
    if not top:
        return None
    return _realpath(top)


def candidate_config_files() -> list[str]:
    """Every .claude.json that this machine's Claude setups may read."""
    home = os.path.expanduser("~")
    files: set[str] = set()

    # Default login (no CLAUDE_CONFIG_DIR).
    files.add(os.path.join(home, ".claude.json"))

    # The current shell's CLAUDE_CONFIG_DIR, if one is exported.
    ccd = os.environ.get("CLAUDE_CONFIG_DIR")
    if ccd:
        files.add(os.path.join(ccd, ".claude.json"))

    # cswap profiles: each session dir holds its own .claude.json. The backup
    # root is ~/.claude-swap-backup on macOS/Windows and
    # $XDG_DATA_HOME/claude-swap (default ~/.local/share/claude-swap) on Linux.
    xdg = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    for base in (
        os.path.join(home, ".claude-swap-backup"),
        os.path.join(os.path.expanduser(xdg), "claude-swap"),
    ):
        for pattern in (os.path.join(base, "sessions", "*"),):
            for session in glob.glob(pattern):
                if os.path.isdir(session):
                    files.add(os.path.join(session, ".claude.json"))

    return sorted(files)


def load_config(path: str) -> dict | None:
    """Parse a .claude.json, or return None when absent/invalid."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def atomic_write(path: str, data: dict) -> None:
    """Write data to path atomically, preserving the file's mode."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)

    mode = None
    try:
        mode = os.stat(path).st_mode & 0o777
    except OSError:
        mode = 0o600  # new file: private, like the rest of .claude

    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".claude.json.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def trust(path: str, directory: str) -> bool:
    """Seed trust for directory into path's projects map. True when changed.

    Only files that already exist are touched, so a profile that has never
    launched is left for Claude Code to create on its own first run.
    """
    config = load_config(path)
    if config is None:
        return False

    projects = config.get("projects")
    if not isinstance(projects, dict):
        projects = {}

    keys = [os.path.realpath(os.path.abspath(directory))]
    root = git_root(directory)
    if root and root not in keys:
        keys.append(root)

    changed = False
    for key in keys:
        entry = projects.get(key)
        if not isinstance(entry, dict):
            entry = {}
        if entry.get("hasTrustDialogAccepted") is not True:
            entry = dict(entry)
            entry["hasTrustDialogAccepted"] = True
            projects[key] = entry
            changed = True

    if not changed:
        return False

    config["projects"] = projects
    atomic_write(path, config)
    return True


def main(argv: list[str]) -> int:
    directory = argv[1] if len(argv) > 1 else os.getcwd()
    directory = _realpath(directory)

    if not os.path.isdir(directory):
        print(f"claude-pretrust: not a directory: {directory}", file=sys.stderr)
        return 1

    touched = 0
    for path in candidate_config_files():
        try:
            if trust(path, directory):
                touched += 1
        except OSError as exc:
            print(f"claude-pretrust: could not update {path}: {exc}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
