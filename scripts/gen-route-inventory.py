#!/usr/bin/env python3
"""Regenerate the "Route inventory (generated)" section of docs/api/DSVideoBackendAPI.md.

The hand-written prose in that doc covers the routes the iOS/tvOS clients actually call,
with request and response shapes — that is the part worth writing by hand and the part a
generator would make worse. This fills in the other half: a complete, checkable list of
every route the server registers, with the documented ones marked.

The point is that the coverage gap stays VISIBLE. The doc previously described 18 of 80
routes while reading as though it were complete, and nothing would have caught the ratio
drifting further. Run this after adding routes; the diff shows exactly what is undocumented.

    python3 scripts/gen-route-inventory.py

Caveats, stated because the numbers are only as good as the parse: this greps literal string
arguments to chi's Get/Post/Put/Delete/Patch/Head/Handle/HandleFunc. It does not resolve
chi Route/Mount prefix nesting into full paths, and a route registered with a computed
(non-literal) path is invisible to it. Treat the total as a close approximation.
"""

import collections
import glob
import os
import re
import sys

ROUTE_CALL = re.compile(
    r'r\.(?:With\([^)]*\)\.)?(Get|Post|Put|Delete|Patch|Head|Handle|HandleFunc)\(\s*"([^"]+)"'
)
DOCUMENTED_HEADING = re.compile(r'^### (?:GET|POST|PUT|DELETE|PATCH) `([^`]+)`', re.M)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_GLOB = os.path.join(REPO, "backend", "cmd", "dsvideo-backend", "*.go")
DOC = os.path.join(REPO, "docs", "api", "DSVideoBackendAPI.md")

SECTION_START = "## Route inventory (generated)"
SECTION_END = "## Notes / v1 limitations"


def collect_routes():
    routes = collections.defaultdict(set)
    for path in sorted(glob.glob(SRC_GLOB)):
        if path.endswith("_test.go"):
            continue
        with open(path) as fh:
            for m in ROUTE_CALL.finditer(fh.read()):
                routes[m.group(2)].add(m.group(1).upper())
    return routes


def bucket(path):
    if path.startswith("/webapi"):
        return "webapi"
    if path in ("/", "/web/*"):
        return "static"
    return "api"


def table(paths, routes, documented):
    rows = ["| Route | Methods | Documented |", "|---|---|---|"]
    for p in sorted(paths):
        methods = ", ".join(sorted(routes[p]))
        mark = "✅" if (p in documented or ("/api/v1" + p) in documented) else "—"
        rows.append("| `%s` | %s | %s |" % (p, methods, mark))
    return "\n".join(rows)


def main():
    routes = collect_routes()
    if not routes:
        print("no routes found — did the source move?", file=sys.stderr)
        return 1

    doc = open(DOC).read()
    documented = set(DOCUMENTED_HEADING.findall(doc))

    groups = collections.defaultdict(list)
    for p in routes:
        groups[bucket(p)].append(p)

    n_doc = sum(1 for p in routes if p in documented)
    section = """%s

The prose sections above document the **%d routes the iOS/tvOS clients actually call** —
the browsing, playback, progress and auth surface — with request/response shapes. That is the
contract worth describing by hand, and it is deliberately not the whole route table.

For completeness, every route the server registers is listed below, with ✅ marking the ones
documented above. Regenerate with `python3 scripts/gen-route-inventory.py`.

**%d routes total: %d client-facing, %d Synology WebAPI compatibility, %d static/player.**

### Client-facing

%s

### Synology WebAPI compatibility layer

Legacy surface for DS Video clients. The shipping apps use `/api/v1` with Bearer auth and do
not depend on these.

%s

### Static / player

%s
""" % (
        SECTION_START,
        n_doc,
        len(routes),
        len(groups["api"]),
        len(groups["webapi"]),
        len(groups["static"]),
        table(groups["api"], routes, documented),
        table(groups["webapi"], routes, documented),
        table(groups["static"], routes, documented),
    )

    if SECTION_START in doc:
        head, rest = doc.split(SECTION_START, 1)
        _, tail = rest.split(SECTION_END, 1)
        doc = head + section.strip() + "\n\n" + SECTION_END + tail
    else:
        doc = doc.replace(SECTION_END, section.strip() + "\n\n" + SECTION_END)

    open(DOC, "w").write(doc)
    print("documented %d of %d routes" % (n_doc, len(routes)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
