"""The files a user actually downloads: `git archive` of the working copy.

The Godot Asset Library (and GitHub's "Download ZIP") serve `git archive` of a commit, which
honours the export-ignore rules in .gitattributes. The checks run against exactly that, built
from the CURRENT working copy (tracked changes and new, not-ignored files included) through a
temporary git index, so they test the code as it is now without touching the real index.
"""
from __future__ import annotations

import io
import os
import re
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _git(args: list[str], env: dict | None = None) -> bytes:
    return subprocess.run(["git"] + args, cwd=ROOT, env=env, check=True, capture_output=True).stdout


def archive_tar() -> tarfile.TarFile:
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(tmp) / "index"))
        _git(["read-tree", "HEAD"], env)
        _git(["add", "-A"], env)
        tree = _git(["write-tree"], env).decode().strip()
    data = _git(["archive", "--format=tar", tree])
    return tarfile.open(fileobj=io.BytesIO(data))


def extract(dest: Path) -> list[str]:
    """Extracts the archive into [dest]; returns its member names."""
    with archive_tar() as tar:
        names = tar.getnames()
        tar.extractall(dest, filter="data")
    return names


def problems(names: list[str], dest: Path) -> list[str]:
    """Anything in the extracted archive a user should not get."""
    out = []
    top = sorted({n.split("/")[0] for n in names})
    for entry in top:
        if entry not in ("LICENSE", "addons"):
            out.append(f"unexpected top-level entry in the archive: {entry}")
    addons = sorted({n.split("/")[1] for n in names if n.startswith("addons/") and n.count("/") >= 1 and n.split("/")[1]})
    if addons != ["gads"]:
        out.append(f"unexpected addons in the archive: {addons}")
    # Relative links in shipped Markdown must point at shipped files.
    for name in names:
        if not name.endswith(".md"):
            continue
        text = (dest / name).read_text(encoding="utf-8")
        for link in re.findall(r"\]\(([^)#\s]+)", text):
            if re.match(r"^[a-z]+://|^mailto:", link):
                continue
            if not (dest / name).parent.joinpath(link).exists():
                out.append(f"{name}: link to a file that is not shipped: {link}")
    return out
