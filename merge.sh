#!/usr/bin/env bash
# Merge the per-run lens reports of one audit into merged.md for the adjudicator
# and agreement.md for the user.
#
# Usage: merge.sh [audit-run-dir]      e.g. merge.sh audit/20261015T120000Z
#        With no argument, merges the newest run under ./audit/.
#
# Reads <audit-run-dir>/<lens>/*.md and puts reports of the same lens and file
# under one finding only when their line ranges all overlap and none covers
# more than 30 lines. Each report keeps its own title, trigger and consequence.
# merged.md removes which run (and so which model) wrote each report and holds
# no agreement counts; agreement.md holds the counts and is never given to the
# adjudicator. Run outputs that do not follow finding-format.md are named on
# stderr and counted in agreement.md, never dropped silently.
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "usage: $(basename "$0") [audit-run-dir]" >&2
    exit 2
fi
run_dir=${1:-}
if [[ -z $run_dir ]]; then
    run_dir=$(find audit -mindepth 1 -maxdepth 1 -type d -name '2*' 2>/dev/null | sort | tail -n 1)
    [[ -n $run_dir ]] || { echo "merge.sh: no audit runs under ./audit/; pass the run directory" >&2; exit 2; }
fi
[[ -d $run_dir ]] || { echo "merge.sh: $run_dir is not a directory" >&2; exit 2; }
command -v python3 >/dev/null || { echo "merge.sh: python3 not found" >&2; exit 2; }

python3 -I - "$run_dir" <<'PY'
import os
import re
import sys

SEVERITIES = ["critical", "high", "medium", "low"]
FIELDS = ("location", "severity", "trigger", "consequence", "related")

run_dir = sys.argv[1]
finding_re = re.compile(r"^##\s+Finding:\s*(.*)$")
none_re = re.compile(r"^##\s+No findings\s*$", re.I)
heading_re = re.compile(r"^##\s")
# Any heading that looks like a finding but is not exactly "## Finding:".
finding_like_re = re.compile(r"^#{1,6}\s*Finding\b", re.I)
# Fields start at column 0, so an indented line inside a field's text can
# never be taken for a new field.
field_re = re.compile(r"^[-*]\s*(" + "|".join(FIELDS) + r")\s*:\s?(.*)$", re.I)
# path:line, path:line-line, with an optional :column after either line.
loc_re = re.compile(r"^(.+?):L?(\d+)(?::\d+)?(?:\s*[-–]\s*L?(\d+)(?::\d+)?)?$")
# A report covering more than this many lines is never merged with another:
# one wide range would otherwise swallow every finding inside it.
WIDE = 30

# fanout.sh records where the reviewers' snapshot was, so an absolute path
# into it can be made relative again.
snapshot = None
try:
    with open(os.path.join(run_dir, "run.txt"), encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("snapshot: "):
                snapshot = line[len("snapshot: "):].strip().rstrip("/") + "/"
except FileNotFoundError:
    pass


def strip_outer_fence(text):
    lines = text.strip().splitlines()
    if len(lines) >= 2 and lines[0].startswith("```") and lines[-1].strip() == "```":
        return "\n".join(lines[1:-1])
    return text


def parse(text):
    """Return (findings, saw_no_findings_marker, problems).

    problems names every block that did not follow finding-format.md, so a
    malformed finding is reported instead of silently dropped or merged into
    the finding before it."""
    findings, cur, field, fenced, none_marker, problems = [], None, None, False, False, []
    for line in strip_outer_fence(text).splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
        elif not fenced:
            m = finding_re.match(line)
            if m:
                cur = {"title": m.group(1).strip()}
                findings.append(cur)
                field = None
                continue
            if none_re.match(line):
                none_marker, cur, field = True, None, None
                continue
            if finding_like_re.match(line):
                problems.append(f"finding heading not in the expected form: {line.strip()!r}")
                cur, field = None, None
                continue
            if heading_re.match(line):
                cur, field = None, None
                continue
            m = field_re.match(line)
            if m and cur is not None:
                name = m.group(1).lower()
                if name in cur:
                    # A second "- location:" and so on means a second finding
                    # without its own heading; keep the first one intact.
                    problems.append(f"field {name!r} repeated after finding {cur.get('title', '')!r}; the rest of that block was not read")
                    cur, field = None, None
                    continue
                field = name
                cur[field] = m.group(2).rstrip()
                continue
        if cur is not None and field is not None:
            cur[field] = cur[field] + "\n" + line.rstrip()
    return findings, none_marker, problems


def parse_location(raw):
    loc = raw.strip().strip("`").strip()
    if snapshot and loc.startswith(snapshot):
        loc = loc[len(snapshot):]
    m = loc_re.match(loc)
    if not m:
        return loc, None, None
    path = m.group(1).strip().strip("`")
    while path.startswith("./"):
        path = path[2:]
    start = int(m.group(2))
    end = int(m.group(3)) if m.group(3) else start
    return path, min(start, end), max(start, end)


def norm(text):
    return "\n".join(l.rstrip() for l in text.strip().splitlines())


lenses = sorted(d for d in os.listdir(run_dir) if os.path.isdir(os.path.join(run_dir, d)))
if not lenses:
    sys.exit(f"merge.sh: no lens directories in {run_dir}")

stats = {}
reports = []  # one entry per reported finding
unparsed_total = 0
malformed_total = 0
for lens in lenses:
    runs = sorted(f for f in os.listdir(os.path.join(run_dir, lens)) if f.endswith(".md"))
    s = {"runs": len(runs), "none": 0, "unparsed": 0, "malformed": 0, "reports": 0}
    for run in runs:
        path = os.path.join(run_dir, lens, run)
        with open(path, encoding="utf-8", errors="replace") as fh:
            found, none_marker, problems = parse(fh.read())
        for problem in problems:
            print(f"merge.sh: {path}: {problem}", file=sys.stderr)
        s["malformed"] += len(problems)
        if not found:
            if none_marker:
                s["none"] += 1
            else:
                s["unparsed"] += 1
                print(f"merge.sh: {path}: no findings in the expected format and no 'No findings' marker", file=sys.stderr)
            continue
        for f in found:
            file, start, end = parse_location(f.get("location", ""))
            if start is None:
                print(f"merge.sh: {path}: unparsed location {f.get('location', '')!r}, kept as its own finding", file=sys.stderr)
            sev = f.get("severity", "").strip().strip("`").lower()
            reports.append({
                "lens": lens, "run": run, "file": file, "start": start, "end": end,
                "severity": sev if sev in SEVERITIES else "unknown",
                "title": norm(f.get("title", "")),
                "trigger": norm(f.get("trigger", "")),
                "consequence": norm(f.get("consequence", "")),
                "related": [r.strip().strip("`") for r in f.get("related", "").replace("\n", ",").split(",")
                            if r.strip() and r.strip().lower() != "none"],
            })
            s["reports"] += 1
    unparsed_total += s["unparsed"]
    malformed_total += s["malformed"]
    stats[lens] = s

# Group by lens and file. A report joins a group only when its range overlaps
# every report already in it, so ranges never chain, and a wide report stays on
# its own. Splitting too much costs the adjudicator one "duplicate of" line;
# merging too much loses a finding.
def overlaps(a, b):
    return a["start"] <= b["end"] and b["start"] <= a["end"]


def wide(r):
    return r["end"] - r["start"] + 1 > WIDE


groups = []
by_key = {}
for r in reports:
    by_key.setdefault((r["lens"], r["file"]), []).append(r)
for (lens, file), rs in by_key.items():
    for r in (r for r in rs if r["start"] is None):
        groups.append([r])
    file_groups = []
    for r in sorted((r for r in rs if r["start"] is not None), key=lambda r: (r["start"], r["end"])):
        home = None
        if not wide(r):
            home = next((g for g in file_groups
                         if not wide(g[0]) and all(overlaps(r, m) for m in g)), None)
        if home is None:
            file_groups.append([r])
        else:
            home.append(r)
    groups += file_groups


def sev_rank(s):
    return SEVERITIES.index(s) if s in SEVERITIES else len(SEVERITIES)


def span(file, start, end):
    if start is None:
        return file
    return f"{file}:{start}" if start == end else f"{file}:{start}-{end}"


def summarize(g):
    lens, file = g[0]["lens"], g[0]["file"]
    if g[0]["start"] is None:
        loc, first = file, 0
    else:
        first, last = min(r["start"] for r in g), max(r["end"] for r in g)
        loc = span(file, first, last)
    counts = {}
    for r in g:
        counts[r["severity"]] = counts.get(r["severity"], 0) + 1
    return {
        "lens": lens, "file": file, "first": first, "loc": loc,
        "severity": min((r["severity"] for r in g), key=sev_rank),
        "sev_counts": sorted(counts.items(), key=lambda kv: sev_rank(kv[0])),
        "runs": len({r["run"] for r in g}),
        "total_runs": stats[lens]["runs"],
        # Each report kept whole, sorted so their order says nothing about
        # which run wrote them.
        "reports": sorted(g, key=lambda r: (r["title"], r["trigger"], r["consequence"], r["severity"])),
        "unproven": sum(1 for r in g if r["trigger"].upper().startswith("UNPROVEN")),
        "unparsed_location": g[0]["start"] is None,
    }


merged = sorted((summarize(g) for g in groups),
                key=lambda m: (sev_rank(m["severity"]), m["lens"], m["file"], m["first"]))


def field(name, text):
    lines = text.splitlines() or ["(none given)"]
    return [f"- {name}: {lines[0]}"] + ["  " + l if l else "" for l in lines[1:]]


def report_lines(r, with_location):
    out = [f"- location: {span(r['file'], r['start'], r['end'])}"] if with_location else []
    return out + (field("title", r["title"]) + [f"- severity: {r['severity']}"]
                  + field("trigger", r["trigger"]) + field("consequence", r["consequence"])
                  + [f"- related: {', '.join(r['related']) if r['related'] else 'none'}"])


audit = os.path.basename(os.path.normpath(run_dir))

# merged.md, for the adjudicator: the findings and nothing about how often each
# was reported.
out = [
    "# Merged findings",
    "",
    f"Audit: {audit}",
    "",
    f"{len(merged)} findings. Reports of the same lens in the same file are listed under one finding only when",
    f"their line ranges all overlap and none covers more than {WIDE} lines. Each report is kept whole, in title",
    "order, and which reviewer or model wrote it has been removed.",
]
for i, m in enumerate(merged, 1):
    fid = f"F{i:03d}"
    out += ["", f"## {fid}", f"- lens: {m['lens']}", f"- location: {m['loc']}"]
    if len(m["reports"]) == 1:
        out += report_lines(m["reports"][0], with_location=False)
    else:
        for j, r in enumerate(m["reports"], 1):
            out += ["", f"### {fid}.{j}"] + report_lines(r, with_location=True)

# agreement.md, for the user: how often each finding came back.
low = sum(1 for m in merged if m["runs"] == 1)
ag = [
    "# Agreement",
    "",
    f"Audit: {audit}",
    "",
    "How often each finding in merged.md was reported. Agreement says how often a finding came back, not whether",
    "it is true, so this file is never given to the adjudicator.",
    "",
    "| lens | runs | runs with no findings | runs not parsed | malformed blocks | reports | merged findings |",
    "|------|------|-----------------------|-----------------|------------------|---------|-----------------|",
]
for lens in lenses:
    s = stats[lens]
    n = sum(1 for m in merged if m["lens"] == lens)
    ag.append(f"| {lens} | {s['runs']} | {s['none']} | {s['unparsed']} | {s['malformed']} | {s['reports']} | {n} |")
if malformed_total:
    ag += ["", f"Finding blocks that did not follow the finding format and are not in merged.md: {malformed_total}. "
               "merge.sh named them on stderr; read those run outputs by hand."]
if unparsed_total:
    ag += ["", f"Run outputs that did not follow the finding format and are not in merged.md: {unparsed_total}. "
               "merge.sh named them on stderr; read them by hand."]
ag += [
    "",
    f"{len(merged)} findings, {low} of them low-agreement (reported by one run only).",
    "",
    "| finding | lens | location | runs | severities reported | notes |",
    "|---------|------|----------|------|---------------------|-------|",
]
for i, m in enumerate(merged, 1):
    notes = []
    if m["runs"] == 1:
        notes.append("low-agreement")
    if m["unparsed_location"]:
        notes.append("location-unparsed")
    if m["unproven"]:
        notes.append(f"trigger UNPROVEN in {m['unproven']} of {len(m['reports'])} reports")
    sevs = ", ".join(f"{s} {c}" for s, c in m["sev_counts"])
    loc = m["loc"].replace("|", "\\|")
    ag.append(f"| F{i:03d} | {m['lens']} | {loc} | {m['runs']} of {m['total_runs']} | {sevs} | {', '.join(notes)} |")

for name, lines in (("merged.md", out), ("agreement.md", ag)):
    dest = os.path.join(run_dir, name)
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print(dest)
PY
