---
name: pick-task
description: Choose the next GitHub issue to work on in Emerald Co-Op. Use when starting work, when asked "what should I do next", or after finishing an issue. Only picks open, unassigned, non-epic issues whose dependencies are all closed, earliest milestone first.
---

# Pick a task

Repo: `DaviAlencastro/EmeraldCo-Op`. Board: project #5 owned by `bernardosevero`.

## 1. List candidates

Open, unassigned, not epics, ordered by milestone then number:

```bash
gh issue list --repo DaviAlencastro/EmeraldCo-Op --state open --search "no:assignee -label:type:epic" \
  --limit 100 --json number,title,milestone,labels \
  --jq 'sort_by(.milestone.title, .number)[] | "#\(.number) [\(.milestone.title)] \(.title)"'
```

## 2. Check blockers for each candidate (in order)

Each issue body has a `## Dependencies` section listing the issues it's blocked by (`#N`). An issue is **ready** only if **every** one of them is closed.

```bash
N=12
gh issue view $N --repo DaviAlencastro/EmeraldCo-Op --json body --jq .body \
  | sed -n '/^## Dependencies/,/^## /p' | grep -o '#[0-9]\+' | tr -d '#' | sort -u \
  | while read d; do echo "#$d $(gh issue view $d --repo DaviAlencastro/EmeraldCo-Op --json state --jq .state)"; done
```

All `CLOSED` (or no dependencies) → ready. Any `OPEN` → skip it and check the next candidate.

Pick the **first ready issue** in the step 1 order. If none are ready, say so and stop: don't start a blocked issue.

## 3. Claim it

```bash
gh issue edit $N --repo DaviAlencastro/EmeraldCo-Op --add-assignee @me
```

(When an agent works for a human, `@me` is that human's account, which is correct.)

Move it to **In progress** on the board (board UI, or):

```bash
ITEM=$(gh project item-list 5 --owner bernardosevero --format json --limit 200 \
  --jq ".items[] | select(.content.number==$N) | .id")
gh project item-edit --project-id PVT_kwHOAxpLKs4Bm8Zo --id "$ITEM" \
  --field-id PVTSSF_lAHOAxpLKs4Bm8ZozhljRII --single-select-option-id b3796661
```

Status option IDs: Backlog `a868d679`, Ready `a50fcf54`, In progress `b3796661`, In review `d1478c1a`, Done `e7cd273c`.

## 4. Before coding

- Read the whole issue: Context, Scope, **Out of scope**, Acceptance criteria, How to test.
- Read the docs it links (at least `docs/architecture.md`).
- Create the branch: `<type>/<issue>-<short-name>`, e.g. `feat/12-protocol-codec`.

## Rules

- One issue at a time.
- Never take an assigned issue or a `type:epic` issue.
- After merging, check whether your issue unblocked others, and move them from **Backlog** to **Ready** on the board.
