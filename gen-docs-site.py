#!/usr/bin/env python3
"""Regenerate a consumer's MkDocs stub trees and navs from docs/.

`docs/` is the source of truth: documentation lives beside the code it
describes, so a change and its docs land in the same diff. A site needs a
docs_dir of its own, so this mirrors docs/ into docs-site/<site>/ as
include-markdown stubs and rewrites that site's nav in mkdocs.<site>.yml.

Run from the consumer's root, after adding, moving or deleting anything under
docs/ (including the docs/platform-docs submodule):

    python3 devtools/gen-docs-site.py --site internal [--check]

What each site publishes comes from docs-site/sites.json:

    {
      "unpublished": ["archive/", "platform-docs/style/templates/"],
      "directories": [["Getting started", "getting-started"], ...],
      "sites": {
        "internal": {},
        "agents": {
          "roots": {"agents/": "", "platform-docs/libs/agent/use/": "use/"},
          "sections": [["Using", "use"], ["Building", "build"]]
        }
      }
    }

A site with `roots` is an audience site: each key is a path prefix under docs/
(one `*` segment allowed, e.g. "platform-docs/libs/*/admin/"), each value the
prefix that page gets inside the site. That is how a page owned by a library
in platform-docs is served at the same URL as when the product held it. A
site without `roots` is the engineering site: everything not claimed by an
audience site, its nav grouped by page `type` (front matter) then directory.

Hand-authored pages (index.md, anything with no counterpart in docs/) are left
untouched; only stubs are regenerated, and stubs whose source disappeared are
removed.
"""
import argparse
import io
import json
import os
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path.cwd()
DOCS = REPO / "docs"

# A reader arrives wanting to do a task, look a fact up or understand a design
# — not wanting "the infra folder". A page with no type lands under "Other", so
# a missing front matter is visible rather than silently dropped.
TYPE_SECTIONS = [
    ("Overview", "index"),
    ("Tutorials", "tutorial"),
    ("How-to guides", "how-to"),
    ("Runbooks", "runbook"),
    ("Reference", "reference"),
    ("Explanation", "explanation"),
    ("Decisions (ADR)", "adr"),
    ("Plans", "plan"),
]

AUDIENCE_SECTIONS = [("Orientation", "orientation"), ("Tasks", "tasks"), ("Reference", "reference")]

STUB_MARKER = "include-markdown"


def front_matter(path: pathlib.Path) -> dict:
    """The page's leading `---` block, as flat key: value pairs."""
    text = io.open(path, encoding="utf-8").read()
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---\n", 4)
    if end < 0:
        return {}
    meta = {}
    for line in text[4:end].splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            meta[k.strip()] = v.strip()
    return meta


def title_of(path: pathlib.Path) -> str:
    """The document's H1, trimmed to something that fits a sidebar."""
    text = None
    try:
        with io.open(path, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^#\s+(.*?)\s*$", line)
                if m:
                    text = re.sub(r"[`*_]", "", m.group(1)).strip()
                    break
    except OSError:
        pass
    if not text:
        text = path.stem.replace("-", " ").replace("_", " ")
        return text[:1].upper() + text[1:]

    # ADR headings are a number plus a full sentence, sometimes with status
    # clauses trailing off the end. Keep the number (how people refer to them)
    # AND some words (how people find them), drop the rest.
    m = re.match(r"^ADR\s+(\d+)\s*[:—–-]\s*(.+)$", text)
    if m:
        num, rest = m.group(1), m.group(2)
        rest = re.split(r"\s+—\s+\*\*|\s+\(platform-wide", rest)[0]
        if len(rest) > 58:
            rest = rest[:55].rstrip(" ,;:") + "…"
        return f"{num} — {rest}"

    for sep in (": ", " — "):
        if len(text) > 66 and sep in text:
            text = text.split(sep)[0]
    return text[:69].rstrip() + "…" if len(text) > 72 else text


def yaml_quote(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def root_regex(prefix: str):
    return re.compile("^" + re.escape(prefix).replace(r"\*", "[^/]+") + "(.*)$")


def map_to_site(rel: str, roots: dict):
    """The page's path inside the site, or None when no root claims it."""
    for prefix, dest in roots.items():
        m = root_regex(prefix).match(rel)
        if m:
            return dest + m.group(1)
    return None


def write_stubs(site_dir: pathlib.Path, pairs) -> tuple[int, int]:
    """pairs are (path under docs/, path inside the site)."""
    written = 0
    wanted = set()
    for rel, out_rel in pairs:
        dest = site_dir / out_rel
        wanted.add(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        up = "../" * (len(out_rel.parts) - 1) + "../../"
        # include-markdown copies the front matter too, which renders as text;
        # starting after its closing `---` keeps only the page.
        start = '   start="\\n---\\n"\n' if front_matter(DOCS / rel) else ""
        body = '{%%\n   include-markdown "%sdocs/%s"\n%s%%}\n' % (up, rel.as_posix(), start)
        # A case-only rename (STANDARDS.md -> standards.md) on a case-insensitive
        # disk would write into the old file and keep its old name, which the
        # cleanup below then deletes as orphaned. Drop it first.
        if dest.exists() and dest.name not in os.listdir(dest.parent):
            next(f for f in dest.parent.iterdir() if f.name.lower() == dest.name.lower()).unlink()
        if not dest.exists() or io.open(dest, encoding="utf-8").read() != body:
            io.open(dest, "w", encoding="utf-8").write(body)
            written += 1

    # A stub whose source is gone would 404 from the nav or, worse, keep
    # serving a page nobody can find in the repo any more.
    removed = 0
    for path in site_dir.rglob("*.md"):
        if path in wanted:
            continue
        if STUB_MARKER in io.open(path, encoding="utf-8").read():
            path.unlink()
            removed += 1
    return written, removed


def build_audience_nav(pairs, sections) -> str:
    sections = sections or AUDIENCE_SECTIONS
    buckets = {key: [] for _, key in sections}
    loose = []
    for rel, out_rel in pairs:
        head = out_rel.parts[0] if len(out_rel.parts) > 1 else None
        (buckets[head] if head in buckets else loose).append((rel, out_rel))

    def row(pair, indent=6):
        rel, out_rel = pair
        return f"{' ' * indent}- {yaml_quote(title_of(DOCS / rel))}: {out_rel.as_posix()}\n"

    out = ["nav:\n", "  - Home: index.md\n"]
    # Loose top-level pages first (orientation material), minus the hand-written index.
    top = [p for p in loose if p[1].name != "index.md"]
    if top:
        out.append('  - "Orientation":\n')
        out += [row(p) for p in sorted(top, key=lambda p: p[1].as_posix())]
    for label, key in sections:
        rows = buckets[key]
        if not rows:
            continue
        out.append(f"  - {yaml_quote(label)}:\n")
        rows.sort(key=lambda p: p[1].as_posix())
        out += [row(p) for p in rows]
    return "".join(out)


def directory_of(rel: pathlib.Path) -> str:
    """The nav subgroup a page belongs to: its top directory, or for the shared
    docs the library or area that owns it."""
    parts = rel.parts
    if parts[0] == "platform-docs" and len(parts) > 2:
        return "/".join(parts[:3]) if parts[1] == "libs" and len(parts) > 3 else "/".join(parts[:2])
    return parts[0] if len(parts) > 1 else ""


def label_of(d: str, labels: dict) -> str:
    if d in labels:
        return labels[d]
    if d.startswith("platform-docs/libs/"):
        return f"{d.split('/')[2]} library"
    if d.startswith("platform-docs/"):
        return f"Shared: {d.split('/')[1]}"
    return d.replace("-", " ").capitalize() if d else "General"


def build_nav(sources, directories) -> str:
    by_type = {key: [] for _, key in TYPE_SECTIONS}
    other = []
    for rel in sources:
        kind = front_matter(DOCS / rel).get("type")
        (by_type[kind] if kind in by_type else other).append(rel)

    order = {key: i for i, (_, key) in enumerate(directories)}
    labels = {key: label for label, key in directories}

    def row(rel, indent):
        return f"{' ' * indent}- {yaml_quote(title_of(DOCS / rel))}: {rel.as_posix()}\n"

    def section(label, rows):
        out = [f"  - {yaml_quote(label)}:\n"]
        dirs = sorted({directory_of(r) for r in rows},
                      key=lambda d: (d.startswith("platform-docs"), d not in order, order.get(d, 0), d))
        for d in dirs:
            group = sorted((r for r in rows if directory_of(r) == d),
                           key=lambda r: (r.name.lower() not in ("readme.md", "index.md"), r.as_posix()))
            if len(dirs) == 1:
                out += [row(r, 6) for r in group]
                continue
            out.append(f"      - {yaml_quote(label_of(d, labels))}:\n")
            out += [row(r, 10) for r in group]
        return out

    out = ["nav:\n", "  - Home: index.md\n"]
    for label, key in TYPE_SECTIONS:
        if by_type[key]:
            out += section(label, by_type[key])
    if other:
        out += section("Other", other)
    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--site", default="internal", help="site directory under docs-site/")
    ap.add_argument("--check", action="store_true",
                    help="fail instead of writing — for CI, so a forgotten sync is caught")
    args = ap.parse_args()

    conf = json.load(io.open(REPO / "docs-site" / "sites.json", encoding="utf-8"))
    sites = conf["sites"]
    spec = sites.get(args.site)
    if spec is None:
        print(f"unknown site {args.site!r}; known: {', '.join(sites)}", file=sys.stderr)
        return 2
    site_dir = REPO / "docs-site" / args.site
    config = REPO / f"mkdocs.{args.site}.yml"
    if not config.exists():
        print(f"no such config: {config}", file=sys.stderr)
        return 2

    unpublished = tuple(conf.get("unpublished", []))
    sources = sorted(p.relative_to(DOCS) for p in DOCS.rglob("*.md")
                     if not p.relative_to(DOCS).as_posix().startswith(unpublished))

    roots = spec.get("roots")
    if roots:
        pairs = [(r, pathlib.Path(out)) for r in sources
                 if (out := map_to_site(r.as_posix(), roots)) is not None]
        nav = build_audience_nav(pairs, spec.get("sections"))
    else:
        # Everything EXCEPT what an audience site claims: a customer-facing page
        # in two navs leaves a reader no way to tell which one they landed in.
        claimed = [s["roots"] for s in sites.values() if s.get("roots")]
        pairs = [(r, r) for r in sources
                 if not any(map_to_site(r.as_posix(), c) is not None for c in claimed)]
        nav = build_nav([r for r, _ in pairs], conf.get("directories", []))

    current = io.open(config, encoding="utf-8").read()
    head = current[: current.index("nav:\n")]

    if args.check:
        stale = [f"missing stub: docs-site/{args.site}/{out}" for _, out in pairs
                 if not (site_dir / out).exists()]
        # On a case-insensitive disk git keeps a stub's old case after a
        # case-only rename; Linux CI then finds the nav pointing at a file the
        # tree does not have. Catch it here, before a push.
        tracked = subprocess.run(["git", "ls-files", f"docs-site/{args.site}"], cwd=REPO,
                                 capture_output=True, text=True).stdout.split("\n")
        by_lower = {t.lower(): t for t in tracked if t}
        for _, out in pairs:
            want = f"docs-site/{args.site}/{out.as_posix()}"
            have = by_lower.get(want.lower())
            if have and have != want:
                stale.append(f"git tracks {have}, the nav needs {want}: git mv -f {have} {want}")
        if current != head + nav:
            stale.append(f"{config.name} nav is out of date")
        if stale:
            print("docs site is out of sync with docs/:", file=sys.stderr)
            for line in stale:
                print("  " + line, file=sys.stderr)
            print("\nRun: make docs-sync", file=sys.stderr)
            return 1
        print(f"docs site in sync ({len(pairs)} documents)")
        return 0

    written, removed = write_stubs(site_dir, pairs)
    io.open(config, "w", encoding="utf-8").write(head + nav)
    print(f"{len(pairs)} documents · {written} stubs written · {removed} stale removed · nav rewritten")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
