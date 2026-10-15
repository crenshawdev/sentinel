## Output format

fanout.sh appends this section to every lens prompt and merge.sh parses it, so follow it exactly. Your whole reply is the findings in this shape and nothing else: no preamble, no summary, no closing remarks.

One block per finding:

```
## Finding: <one line saying what is wrong>
- location: <path relative to the repo root>:<line> or <path>:<first line>-<last line>
- severity: critical | high | medium | low
- trigger: <the input or sequence of steps that makes it happen>
- consequence: <what the attacker or the bug gets>
- related: <other path:line locations involved, comma separated, or none>
```

Rules for the fields:

- `location` is one place: where the bad thing happens or where the fix would go. Line numbers are from the files as they are now. Put every other place that matters in `related`.
- If you cannot name a concrete trigger, the value of `trigger` starts with `UNPROVEN` followed by what you would need to know to name one.
- A field may run onto following lines, including a fenced code block. It ends at the next `- <field>:` line or the next `## ` heading.
- Report each problem once. If the same mistake appears in several places, give each place its own block.

If you find nothing after a thorough search, reply with exactly this heading and a list of what you examined:

```
## No findings
- examined: <files, functions and paths you read, one per line>
```
