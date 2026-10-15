---
name: pr-walkthrough
description: Create a knowledge-transfer walkthrough for a pull request in Emerald Co-Op, a self-contained HTML page with animated diagrams that explains what changed and why, published on the `walkthroughs` branch and linked in a PR comment. Use right after opening a PR (the last step of the pre-commit skill), or when asked to explain a PR to reviewers.
---

# PR walkthrough

Reviewers learn faster from a picture than from a diff. After opening a PR, write a single HTML page that explains it: where the change sits in the system, how it works, the decisions behind it, and how it was tested. It is **not** part of the PR's code. It lives on the `walkthroughs` branch and the PR gets a comment linking to it.

Start from [`template.html`](template.html) in this folder. It has the colors, fonts, diagram classes and scripts already set up.

## 1. Gather the facts

Everything on the page must trace to something real. Collect:

- The diff and its stats: `git diff --stat origin/master...HEAD`.
- The issue: Context, Scope, Out of scope, Dependencies.
- `docs/architecture.md` and any doc the PR touches, for the big-picture diagram.
- The decisions you made and why. Check the issue first: if a choice was already made there, say so instead of presenting it as yours.
- Output of the commands you ran to test the PR. Copy it; never retype or invent it.

**Never invent** numbers, hashes, addresses, offsets, sizes or command output. If you didn't run it or read it, leave it out.

## 2. Plan the sections

Use these in this order and drop the ones that don't apply. A small PR may need only three sections and one diagram. Don't pad it.

| Section | Contents |
|---|---|
| Header | Eyebrow `Knowledge transfer · BDL-Ltda/EmeraldCo-Op#N`, a title saying what the PR makes possible, a 1–2 sentence lede, meta (closes, branch, files, lines, milestone), table of contents. |
| Big picture | Where the change sits in the system: components from `architecture.md`, with the parts this PR adds highlighted. |
| How it works | A sequence or flow diagram of the new behavior. |
| Under the hood | One interactive explorer for the trickiest detail: message fields, struct offsets, a byte layout, states. Real values only. |
| Decisions | 1–3 non-obvious choices, each with the code or command and a **Why**. |
| How it was tested | Real terminal output, plus the manual test result. |
| What's next | Follow-up or blocking issues as a small dependency graph, if the PR leaves work open. |
| For the reviewer | Questions for the reviewer to answer, then known limits with issue numbers. |

## 3. Build the page

Copy `template.html` to a scratch location, outside the repo working tree, as `pr-<N>.html`, and fill it in.

- **One file.** Inline CSS, JS and SVG. No frameworks, no external scripts. Google Fonts is the only external resource, and the template already sets fallbacks.
- **Diagrams are inline SVG** using the template's classes:
  - `box` for components; `box pub` for what this PR adds or what is public; `box priv` (dashed) for private or local things such as ROMs, `config.lua` and saves; `box dim` for things outside this PR.
  - `edge` for arrows; `edge em` for the PR's own path; `edge ret` (dashed) for responses; `edge bad` for failure branches; add `flow` to animate the dashes along the path the PR adds.
  - `gate` (diamond) for checks, `life` for sequence lifelines, `badge` for step numbers. Number things only when the order is real.
  - Wrap each part in `<g class="step" style="--i:N">`. Parts appear in `--i` order when the reader scrolls to the diagram, and **Replay** runs it again.
- **Readable at rest.** Every diagram must make sense with animations off. The template respects `prefers-reduced-motion`.
- **Colors come from the tokens** at the top of the CSS, so the page works in light and dark mode. Don't hard-code colors.
- **Write plainly**, in English, with the repo's own terms. Short sentences and active voice.
- **It's public.** Never include join keys, IP addresses, ROM or save data, or anything AGENTS.md forbids in the repo.

Check it once in a browser (Playwright with the preinstalled Chromium is fine) in light and dark mode and at 400 px wide. There should be no console errors and no horizontal page scroll.

## 4. Publish on the `walkthroughs` branch

`walkthroughs` is an orphan branch that only holds these pages. It's never merged and has no branch protection requirements. Use a separate worktree so your PR branch is untouched:

```bash
N=40   # PR number
WT=$(mktemp -d)
if git fetch origin walkthroughs 2>/dev/null; then
  git worktree add -B walkthroughs "$WT" origin/walkthroughs
else
  git worktree add --detach "$WT" && git -C "$WT" checkout --orphan walkthroughs && git -C "$WT" rm -rfq .
fi
cp /path/to/pr-$N.html "$WT/pr-$N.html"
git -C "$WT" add "pr-$N.html"
git -C "$WT" commit -m "docs: 📝 add walkthrough for #$N"
git -C "$WT" push -u origin walkthroughs
git worktree remove "$WT"
```

To update the page after the PR changes, overwrite the same file and push again. The links stay the same.

## 5. Comment on the PR

Post one comment linking to the page. On later updates, edit that comment instead of posting a new one.

```bash
gh pr comment $N --repo BDL-Ltda/EmeraldCo-Op --body-file comment.md
```

`comment.md`:

```markdown
## 🧭 Walkthrough

<2–3 sentences: what the PR does and the one idea a reviewer should take away.>

**[Open in the browser](https://raw.githack.com/BDL-Ltda/EmeraldCo-Op/walkthroughs/pr-<N>.html)** · [Download](https://github.com/BDL-Ltda/EmeraldCo-Op/blob/walkthroughs/pr-<N>.html) (use "Download raw file", then open it locally)

Covers: <the section names you kept, separated by " · ">.

_Diagrams and numbers come from the diff, issue #<ISSUE> and the commands run for this PR._
```

The browser link goes through raw.githack.com, which serves files from public GitHub repos as web pages. If it's ever down, the download link always works.
