#!/usr/bin/env python3
"""Checks for a docs/ tree that lives beside the code. Stdlib only.

  docs-check.py frontmatter DIR...        every page declares type, owner, reviewed
  docs-check.py stale --days N DIR...     pages whose `reviewed` is older than N days (report only)
  docs-check.py links DIR...              relative Markdown links point at files that exist
  docs-check.py site-links SITE_ROOT      absolute links in built HTML resolve inside SITE_ROOT
  docs-check.py forbid --pattern RE DIR... no page's prose matches RE (e.g. product names in shared docs)
  docs-check.py env --code DIR --doc FILE every env var the Go code reads is named in FILE

Every DIR is walked for *.md; a directory named in --exclude (repeatable) is
skipped wherever it appears. All checks except `stale` exit 1 on a finding.

Front matter is the YAML block at the very top of a page:

  ---
  type: how-to
  owner: platform
  reviewed: 2026-10-30
  ---

`type` is one of TYPES below. A page nobody can vouch for any more gets a new
`reviewed` date after someone checks it, or gets deleted — never a date bump
without a read.
"""
import argparse
import datetime as dt
import os
import pathlib
import re
import sys

TYPES = {
    "tutorial",     # learning by doing, start to finish
    "how-to",       # one task, for someone who knows why they want it
    "runbook",      # what to do when something is wrong in production
    "reference",    # facts to look up: flags, tables, schemas
    "explanation",  # how and why it works
    "adr",          # a decision, immutable once accepted
    "plan",         # proposed or in-flight work; archived when done
    "index",        # a landing page that only routes to others
}
REQUIRED = ("type", "owner", "reviewed")

FENCE = re.compile(r"^(```|~~~)")
LINK = re.compile(r"\]\(([^)\s]+)\)")
CODE_SPAN = re.compile(r"`[^`]*`")


def pages(dirs, exclude):
    for d in dirs:
        root = pathlib.Path(d)
        if root.is_file():
            yield root
            continue
        for p in sorted(root.rglob("*.md")):
            if not exclude.intersection(p.relative_to(root).parts[:-1]):
                yield p


def front_matter(text):
    """The leading `---` block as a dict, or None when the page has none."""
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 4)
    if end < 0:
        return None
    meta = {}
    for line in text[4:end].splitlines():
        if ":" in line and not line.startswith((" ", "#")):
            k, v = line.split(":", 1)
            meta[k.strip()] = v.strip().strip("'\"")
    return meta


def prose_lines(text):
    """(line number, line) outside fenced code, with inline code removed."""
    in_fence = False
    for n, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line.lstrip()):
            in_fence = not in_fence
            continue
        if not in_fence:
            yield n, CODE_SPAN.sub("", line)


def cmd_frontmatter(a):
    bad = []
    for p in pages(a.dirs, set(a.exclude)):
        meta = front_matter(p.read_text(encoding="utf-8"))
        if meta is None:
            bad.append(f"{p}: no front matter")
            continue
        missing = [k for k in REQUIRED if not meta.get(k)]
        if missing:
            bad.append(f"{p}: missing {', '.join(missing)}")
        if meta.get("type") and meta["type"] not in TYPES:
            bad.append(f"{p}: type {meta['type']!r} is not one of {', '.join(sorted(TYPES))}")
        if meta.get("reviewed"):
            try:
                dt.date.fromisoformat(meta["reviewed"])
            except ValueError:
                bad.append(f"{p}: reviewed {meta['reviewed']!r} is not YYYY-MM-DD")
    return report(bad, "front matter")


def cmd_stale(a):
    cutoff = dt.date.today() - dt.timedelta(days=a.days)
    rows = []
    for p in pages(a.dirs, set(a.exclude)):
        meta = front_matter(p.read_text(encoding="utf-8")) or {}
        try:
            when = dt.date.fromisoformat(meta.get("reviewed", ""))
        except ValueError:
            continue
        if when < cutoff:
            rows.append((when, meta.get("owner", "?"), p))
    for when, owner, p in sorted(rows):
        print(f"{when}  {owner:<14} {p}")
    print(f"{len(rows)} page(s) not reviewed in {a.days} days", file=sys.stderr)
    return 0


def cmd_links(a):
    bad = []
    for p in pages(a.dirs, set(a.exclude)):
        for n, line in prose_lines(p.read_text(encoding="utf-8")):
            for target in LINK.findall(line):
                path = target.split("#", 1)[0]
                if not path or "://" in path or path.startswith(("/", "mailto:", "{")):
                    continue
                if not (p.parent / path).exists():
                    bad.append(f"{p}:{n}: {target}")
    return report(bad, "broken relative link")


HREF = re.compile(r'href="(/[^"#?]*)')


def cmd_site_links(a):
    root = pathlib.Path(a.site_root)
    sites = {d.name for d in root.iterdir() if d.is_dir()}
    bad = []
    for page in sorted(root.rglob("*.html")):
        for href in set(HREF.findall(page.read_text(encoding="utf-8", errors="replace"))):
            first = href.strip("/").split("/", 1)[0]
            if first not in sites:
                continue  # not one of the staged sites (e.g. /api/…)
            target = root / href.lstrip("/")
            if not (target.is_file() or (target / "index.html").is_file()):
                bad.append(f"{page.relative_to(root)}: {href}")
    return report(sorted(set(bad)), "broken cross-site link")


LINK_TARGET = re.compile(r"\]\([^)]*\)")


def cmd_forbid(a):
    """Prose only: code and link targets name real identifiers (a metric, a
    path, a repo URL) that a shared page may quote."""
    rx = re.compile(a.pattern, re.IGNORECASE)
    bad = []
    for p in pages(a.dirs, set(a.exclude)):
        for n, line in prose_lines(p.read_text(encoding="utf-8")):
            m = rx.search(LINK_TARGET.sub("]", line))
            if m:
                bad.append(f"{p}:{n}: {m.group(0)!r}")
    return report(bad, f"match for {a.pattern}")


GETENV = re.compile(r'os\.(?:Getenv|LookupEnv)\("([A-Z][A-Z0-9_]*)"\)')


def cmd_env(a):
    doc = pathlib.Path(a.doc).read_text(encoding="utf-8")
    ignore = set(a.ignore)
    read = {}
    for dirpath, dirnames, files in os.walk(a.code):
        dirnames[:] = [d for d in dirnames if d not in ("vendor", "node_modules", ".git")]
        for f in files:
            if f.endswith(".go") and not f.endswith("_test.go"):
                p = pathlib.Path(dirpath) / f
                for var in GETENV.findall(p.read_text(encoding="utf-8", errors="replace")):
                    read.setdefault(var, p)
    bad = [f"{var} (read in {read[var]})" for var in sorted(read)
           if var not in ignore and not re.search(rf"\b{var}\b", doc)]
    return report(bad, f"env var missing from {a.doc}")


def report(bad, what):
    for line in bad:
        print(line)
    if bad:
        print(f"{len(bad)} {what}(s)", file=sys.stderr)
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def with_dirs(name, fn):
        s = sub.add_parser(name)
        s.add_argument("dirs", nargs="+")
        s.add_argument("--exclude", action="append", default=[])
        s.set_defaults(fn=fn)
        return s

    with_dirs("frontmatter", cmd_frontmatter)
    with_dirs("stale", cmd_stale).add_argument("--days", type=int, default=180)
    with_dirs("links", cmd_links)
    with_dirs("forbid", cmd_forbid).add_argument("--pattern", required=True)
    s = sub.add_parser("site-links")
    s.add_argument("site_root")
    s.set_defaults(fn=cmd_site_links)
    s = sub.add_parser("env")
    s.add_argument("--code", required=True)
    s.add_argument("--doc", required=True)
    s.add_argument("--ignore", action="append", default=[], help="a var deliberately left out (test-only)")
    s.set_defaults(fn=cmd_env)

    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
