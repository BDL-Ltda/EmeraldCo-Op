---
name: pre-commit
description: Commit message format (Conventional Commits + gitmoji) and the checks to run before committing and before opening a pull request in Emerald Co-Op. Use before every git commit and before every `gh pr create`.
---

# Pre-commit and pre-PR

## 1. Before committing

### Check for forbidden files

The repo is public. None of these can ever be committed:

```bash
git diff --cached --name-only | grep -Ei '\.(gba|sav|srm|ss[0-9]|elf|map|bps)$|gba_bios\.bin$|client/config\.lua$' \
  && echo "STOP: forbidden file staged" || echo "ok"
```

Also make sure no join key, password or IP address is in the diff.

### Commit message format

**Conventional Commits with a gitmoji after the colon:**

```
<type>(<scope>): <gitmoji> <summary in imperative mood, lowercase, no period>

<optional body: what and why, wrapped at 72 chars>

Refs #<issue>
```

Example: `feat(server): ✨ relay presence to other players`

| type | gitmoji | use for |
|---|---|---|
| `feat` | ✨ | new functionality |
| `fix` | 🐛 | bug fix |
| `docs` | 📝 | documentation only |
| `test` | ✅ | adding or fixing tests |
| `refactor` | ♻️ | code change with no behavior change |
| `perf` | ⚡️ | performance |
| `style` | 🎨 | formatting / structure, no logic change |
| `build` | 📦 | build system, Docker, ROM build |
| `ci` | 👷 | GitHub Actions |
| `chore` | 🔧 | config, tooling, repo maintenance |
| `revert` | ⏪️ | reverting a commit |

Scopes: `server`, `client`, `rom`, `tools`, `protocol`, `docs`, `infra`. Leave the scope out if the change spans many areas.

Breaking change (protocol version bump, mailbox layout change): add `!` and use 💥, e.g. `feat(protocol)!: 💥 add slot index to presence`, plus a `BREAKING CHANGE:` line in the body.

Keep commits small and focused: one logical change per commit.

## 2. Before opening a PR

Run every check that exists in the repo at this point. Some only appear as milestones land; skip the ones whose tooling doesn't exist yet and say so in the PR.

```bash
# Go (whenever go.mod exists)
go vet ./...
go test -race ./...

# Lua (whenever client/tests exists)
lua5.4 client/tests/run.lua
luacheck client/

# ROM (only if you changed rom/ or the submodule pointer)
#   build with the Docker command from the README, then:
go run ./cmd/symgen -elf rom/pokeemerald_modern.elf -rom rom/pokeemerald_modern.gba -out client/addresses.lua
git diff --exit-code client/addresses.lua || echo "addresses.lua changed: commit it in this PR"
```

**Everything must pass.** Don't open a PR with failing checks, and never skip or delete a test to make it pass.

Then do the issue's **How to test** steps (manual emulator steps included) and keep the result (log or screenshot) for the PR body.

## 3. Branch and PR

- Branch: `<type>/<issue>-<short-name>`, e.g. `feat/14-presence-relay`.
- Rebase on the latest `master` before opening the PR.
- PR title: same format as a commit message.
- Use `Refs #<issue>` for partial work. Use `Closes #<issue>` only when the PR
  completes the whole issue, including its acceptance requirements. A docs or
  packaging PR leaves a release acceptance tracker open while human testing
  remains pending. Check GitHub's actual closing links in step 4.
- PR body:

```markdown
Refs #<issue>

## What
<1–3 sentences>

## How I tested
<commands run + manual test result: log, screenshot or video>
<for needs:multiplayer-test: who tested together>

## Checks
- [ ] go vet / go test -race
- [ ] Lua tests / luacheck
- [ ] ROM build + addresses.lua regenerated (if rom changed)
- [ ] Docs updated (if behavior/protocol/memory changed)
- [ ] No forbidden files or secrets
```

- After opening the PR, move the issue to **In review** on the board (see the `pick-task` skill for the command; In review = `d1478c1a`).
- If the PR is a `feat` or `fix`, then use the `pr-walkthrough` skill (`.claude/skills/pr-walkthrough/SKILL.md`) to create the PR's walkthrough page and post it as a PR comment (it is not part of the PR's code). Skip it for every other type.
- One human approval is required before merging. Never approve or merge your own PR.
- If the PR moves the `rom` submodule pointer: the pinned commit must descend from the fork's `master` (`BDL-Ltda/pokeemerald`). After the PR merges, fast-forward the fork's `master` to it (see "Changing the ROM" in the README). Never force-push the fork.

## 4. Check issue closing links

After opening a PR and again before merge, inspect the **Development** sidebar
or run:

```bash
gh pr view <PR> --repo BDL-Ltda/EmeraldCo-Op --json closingIssuesReferences \
  --jq '.closingIssuesReferences[] | {number, url}'
```

Review each returned issue against the scope this PR actually completes.
A partial preparation PR must have **no closing reference to its incomplete
acceptance tracker**, even if its description only says `Refs #N`. Remove an
incorrect closing link in GitHub and rerun the check before merging. Record
the output in the PR; no output means no closing references. Repeat after
edits to issue links or the PR description. A reviewer confirms this check
alongside human approval; green CI alone does not establish issue completion.
