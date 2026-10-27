#!/usr/bin/env python3
"""Pre-answer Claude Code's per-folder consent dialogs for a directory.

Claude Code records the answers to two per-folder questions in the global
config file, keyed by the folder's path:

    projects["<path>"].hasTrustDialogAccepted = true
        (the "Do you trust the files in this folder?" prompt)

    projects["<path>"].hasClaudeMdExternalIncludesApproved = true
    projects["<path>"].hasClaudeMdExternalIncludesWarningShown = true
        (the "Allow external CLAUDE.md file imports?" prompt)

where <path> is the realpath of the git repo root when the folder lives in a
git repo, and the realpath of the folder itself otherwise. The file lives at
``$CLAUDE_CONFIG_DIR/.claude.json`` (or ``~/.claude.json`` for the default
login). cswap profiles get their own copy under the cswap backup root.

The trust flag is written for every directory. The external-imports flags are
written only for directories under ~/c, excluding ~/c/third-parties (where
third-party checkouts live), so a cloned repository still shows the
"Allow external CLAUDE.md file imports?" prompt. Override the scope with the
CLAUDE_PRETRUST_ALLOW_ROOT and CLAUDE_PRETRUST_EXCLUDE environment variables.

The script only merges -- it never rewrites or drops unrelated keys -- and it
writes atomically so a running Claude Code process never sees a torn file.

Usage:
    claude-pretrust.py [directory]     # defaults to the current directory
"""

from __future__ import annotations

# The trust flag is always seeded. External CLAUDE.md imports are only
# auto-approved inside the user's own code tree, so a third-party checkout
# still asks before pulling in instructions from outside the repository.
TRUST_FLAGS = {"hasTrustDialogAccepted": True}
EXTERNAL_INCLUDES_FLAGS = {
    "hasClaudeMdExternalIncludesApproved": True,
    "hasClaudeMdExternalIncludesWarningShown": True,
}

import glob
import json
import os
import subprocess
import sys
import tempfile


def _realpath(path: str) -> str:
    return os.path.realpath(os.path.abspath(os.path.expanduser(path)))


def _within(path: str, base: str) -> bool:
    """True when path is base or a descendant of base."""
    base = base.rstrip(os.sep)
    return path == base or path.startswith(base + os.sep)


def external_scope() -> tuple[str, str]:
    """(allowed_root, excluded_prefix) for auto-approving external imports."""
    home = os.path.expanduser("~")
    allowed = _realpath(
        os.environ.get("CLAUDE_PRETRUST_ALLOW_ROOT", os.path.join(home, "c"))
    )
    excluded = _realpath(
        os.environ.get(
            "CLAUDE_PRETRUST_EXCLUDE", os.path.join(home, "c", "third-parties")
        )
    )
    return allowed, excluded


def in_external_scope(path: str) -> bool:
    """Whether external CLAUDE.md imports should be auto-approved for path."""
    allowed, excluded = external_scope()
    return _within(path, allowed) and not _within(path, excluded)


def flags_for(key: str) -> dict:
    """The consent flags to seed for a project path, given the scope rules."""
    flags = dict(TRUST_FLAGS)
    if in_external_scope(key):
        flags.update(EXTERNAL_INCLUDES_FLAGS)
    return flags


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


def seed_consent(path: str, directory: str) -> bool:
    """Seed the consent flags for directory into path's projects map.

    Returns True when the file changed. Only files that already exist are
    touched, so a profile that has never launched is left for Claude Code to
    create on its own first run.
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
        missing = {
            flag: value
            for flag, value in flags_for(key).items()
            if entry.get(flag) is not value
        }
        if missing:
            projects[key] = {**entry, **missing}
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

    for path in candidate_config_files():
        try:
            seed_consent(path, directory)
        except OSError as exc:
            print(f"claude-pretrust: could not update {path}: {exc}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
