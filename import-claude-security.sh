#!/usr/bin/env bash
# Add a /claude-security scan's findings to an audit run as one more run of
# each lens, so merge.sh dedupes them against the lens runs, counts them in
# the agreement, and strips where they came from like any other run.
#
# Usage: import-claude-security.sh <CLAUDE-SECURITY-dir> [audit-run-dir]
#        With no audit-run-dir, uses the newest run under ./audit/.
#
# Reads CLAUDE-SECURITY-RESULTS.jsonl and writes <run>/<lens>/claude-security.md
# for every lens, in the shape finding-format.md describes ("No findings" for a
# lens it has nothing for). Each finding goes to a lens by its CWE ids. A
# finding whose CWEs match no lens goes to <run>/other/. Run it before merge.sh.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! -f $1/CLAUDE-SECURITY-RESULTS.jsonl ]]; then
    echo "usage: $(basename "$0") <CLAUDE-SECURITY-dir> [audit-run-dir]" >&2
    echo "the first argument must hold CLAUDE-SECURITY-RESULTS.jsonl" >&2
    exit 2
fi
run_dir=${2:-}
if [[ -z $run_dir ]]; then
    run_dir=$(find audit -mindepth 1 -maxdepth 1 -type d -name '2*' 2>/dev/null | sort | tail -n 1)
    [[ -n $run_dir ]] || { echo "import-claude-security.sh: no audit runs under ./audit/; pass the run directory" >&2; exit 2; }
fi
[[ -d $run_dir ]] || { echo "import-claude-security.sh: $run_dir is not a directory" >&2; exit 2; }
lenses_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/lenses"

python3 -I - "$1/CLAUDE-SECURITY-RESULTS.jsonl" "$run_dir" "$lenses_dir" <<'PY'
import json
import os
import re
import sys

jsonl, run_dir, lenses_dir = sys.argv[1:4]
lenses = sorted(f[:-3] for f in os.listdir(lenses_dir) if f.endswith(".md"))

# CWE ids that clearly belong to one lens. Anything else goes to "other".
CWE_LENS = {
    "data-exposure": [200, 201, 209, 212, 215, 359, 497, 532, 538, 539, 552, 598, 615],
    "path-handling": [22, 23, 24, 35, 36, 41, 59, 61, 62, 64, 65, 66, 73, 367, 377, 378, 379],
    "untrusted-input": [20, 74, 79, 89, 90, 91, 94, 95, 113, 116, 117, 134, 138, 150, 176,
                        190, 191, 502, 611, 643, 681, 704, 843, 915, 917, 1236, 1321, 1336],
    "permissions": [250, 266, 269, 272, 276, 277, 278, 279, 281, 284, 285, 732, 862, 863],
    "resource-limits": [400, 401, 404, 405, 409, 674, 770, 771, 772, 773, 774, 775, 776,
                        789, 834, 835, 1050, 1333],
    "hook-execution": [77, 78, 88, 114, 426, 427],
    "supply-chain": [494, 829, 830, 1104, 1357, 1395],
    "crypto-and-state": [208, 256, 259, 260, 261, 295, 296, 297, 310, 311, 312, 313, 321,
                         323, 324, 325, 326, 327, 328, 329, 330, 331, 335, 338, 340, 345,
                         347, 353, 354, 798, 916, 1204, 1240],
}
by_cwe = {cwe: lens for lens, cwes in CWE_LENS.items() for cwe in cwes}


def cwe_number(value):
    m = re.search(r"(\d+)", str(value or ""))
    return int(m.group(1)) if m else None


def lens_for(record):
    for value in [record.get("cwe_id")] + list(record.get("other_cwe_ids") or []):
        lens = by_cwe.get(cwe_number(value))
        if lens in lenses:
            return lens
    return "other"


def block(record):
    file = str(record.get("file") or "").strip()
    line = int(record.get("line") or 0)
    trigger = str(record.get("exploit_scenario") or record.get("description") or "").strip()
    pre = [str(p).strip() for p in record.get("preconditions") or [] if str(p).strip()]
    if pre:
        trigger += "\n  Preconditions: " + "; ".join(pre)
    consequence = str(record.get("impact") or record.get("description") or "").strip()
    return "\n".join([
        f"## Finding: {str(record.get('title') or '').strip()}",
        f"- location: {file}:{line}" if line > 0 else f"- location: {file}",
        f"- severity: {str(record.get('severity') or '').strip().lower()}",
        f"- trigger: {trigger or 'UNPROVEN no exploit scenario given'}",
        f"- consequence: {consequence}",
        "- related: none",
    ])


found = {}
with open(jsonl, encoding="utf-8") as fh:
    for n, line in enumerate(fh, 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as e:
            sys.exit(f"import-claude-security.sh: {jsonl}:{n}: not JSON: {e}")
        found.setdefault(lens_for(record), []).append(block(record))

for lens in lenses + (["other"] if "other" in found else []):
    os.makedirs(os.path.join(run_dir, lens), exist_ok=True)
    dest = os.path.join(run_dir, lens, "claude-security.md")
    with open(dest, "w", encoding="utf-8") as fh:
        if found.get(lens):
            fh.write("\n\n".join(found[lens]) + "\n")
        else:
            fh.write("## No findings\n- examined: the whole repository\n")
    print(f"{lens}: {len(found.get(lens, []))} findings")
PY
