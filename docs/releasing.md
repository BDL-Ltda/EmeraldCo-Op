# Releasing

This is the checklist for whoever cuts a release. The repository is public, so
we never commit or upload a `.gba`. Players get our ROM as a **`.bps` patch**
that they apply to their own legally dumped US Pokémon Emerald. Creating the
patch needs that retail ROM, so this is a local step and cannot run in CI.

Players follow [installing.md](installing.md) to use a release.

## What you need

- A checkout that can build the ROM with Docker. See
  [Building the ROM](../README.md#building-the-rom).
- Your own retail **Pokémon Emerald (USA)** ROM with this SHA1:

  ```text
  f3ae088181bf583e55daf962a92bb46f4f1d07b7
  ```

  Keep it outside the repository, for example `~/roms/emerald-us.gba`. Never
  commit, upload or share it.
- [Flips](https://github.com/Alcaro/Flips) (Floating IPS), the standard patch
  tool. Download a build from its
  [releases page](https://github.com/Alcaro/Flips/releases). On Linux you can
  also install it from
  [Flathub](https://flathub.org/apps/com.github.Alcaro.Flips). The commands
  below use the CLI, called `flips`. On Windows, run `flips.exe` from a terminal
  instead.

Commands below use a POSIX shell. In PowerShell, use `Get-FileHash -Algorithm
SHA1 <file>` instead of `sha1sum`.

Release versions follow the milestones: `vX.Y`, for example `v0.1`.
The first presence release is **`v1.0`**; use the
[v1 checklist and notes template](release-v1.md). v1.0 is already published;
remaining release-only acceptance and retrospective work is tracked in
[#27](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/27).

## 1. Build the ROM at the release commit

Check out the release commit on `master`, with the pinned ROM submodule and no
local changes:

```sh
git checkout master
git pull --ff-only
git submodule sync --recursive
git submodule update --init --recursive
git status --short          # must print nothing
git submodule status        # no leading '+' or '-'
```

Check that CI is green on that commit. Then build:

```sh
docker compose run --build --rm rom
```

The build prints the SHA1 of `rom/pokeemerald_modern.gba`. Write it down: it
goes in the release notes.

`client/addresses.lua` must have been generated from this exact build. The ROM
CI job already rebuilds and checks its freshness. Verify locally too:

```sh
go run ./cmd/symgen -elf rom/pokeemerald_modern.elf -rom rom/pokeemerald_modern.gba -out client/addresses.lua
git diff --exit-code -- client/addresses.lua
```

If it differs, stop: fix and review the generated file through a PR, then
restart from the merged commit. Do not publish a client archive from a dirty
checkout or tag an unmerged preparation branch.

## 2. Create the patch

Check the base ROM first:

```sh
sha1sum ~/roms/emerald-us.gba
# f3ae088181bf583e55daf962a92bb46f4f1d07b7
```

Then create the patch, replacing `X.Y` with the version:

```sh
flips --create --bps ~/roms/emerald-us.gba rom/pokeemerald_modern.gba emerald-coop-vX.Y.bps
```

`.bps` files are ignored by Git. Keep the patch outside `rom/` if you prefer,
and never commit it.

Check the patch before publishing it. Apply it to the retail ROM and confirm
the result is byte-identical to your build:

```sh
flips --apply emerald-coop-vX.Y.bps ~/roms/emerald-us.gba /tmp/emerald-coop-check.gba
sha1sum rom/pokeemerald_modern.gba /tmp/emerald-coop-check.gba   # both hashes must match
```

Delete `/tmp/emerald-coop-check.gba` when you're done.

## 3. Package the client scripts

Package the `client/` directory from the release commit. `git archive` only
includes committed files, so your private `client/config.lua` is never
included:

```sh
git archive --format=zip --prefix=emerald-coop-vX.Y-client/ -o emerald-coop-vX.Y-client.zip HEAD client
```

The zip contains `client/addresses.lua`, which only works with the ROM built
from this same commit. Always publish the patch and the client together.

## 4. Publish the GitHub Release

Prepare a **draft** release with tag `vX.Y` targeting the exact, reviewed
release commit and attach both files:

- `emerald-coop-vX.Y.bps`
- `emerald-coop-vX.Y-client.zip`

Use the GitHub web UI (**Releases → Draft a new release**, create the tag on
the release commit) or the GitHub CLI:

```sh
gh release create vX.Y --draft --target "$(git rev-parse HEAD)" --title "vX.Y" \
  --notes-file notes.md emerald-coop-vX.Y.bps emerald-coop-vX.Y-client.zip
```

The release notes must include the patched ROM's SHA1. Players use it to
confirm their patch was applied correctly. Template:

```markdown
## What's new
<short summary, link to the milestone>

## Install
Follow docs/installing.md. You need your own Pokémon Emerald (USA) ROM.

| | SHA1 |
| --- | --- |
| Base ROM (Pokémon Emerald USA) | `f3ae088181bf583e55daf962a92bb46f4f1d07b7` |
| Patched ROM (`emerald-coop-vX.Y.gba`) | `<SHA1 from step 1>` |

- Commit: `<full commit hash>`
- ROM submodule: `<output of git -C rom rev-parse HEAD>`
- mGBA version: `<version pinned in the README>`

## Acceptance status
<link to the active acceptance tracker; list observed results and pending cases>
```

Never attach a `.gba`, `.elf`, `.map`, save file or anything containing a join
key or IP address.

Inspect the draft's target commit, notes, ZIP entries and attachments. The ZIP
must contain `client/bridge.lua`, `client/addresses.lua`, `client/net.lua`,
`client/config.example.lua` and `client/lib/`, with no private `config.lua`.
Extract it in a clean ASCII-only directory and compare `addresses.lua` to the
release commit. When both assets and hashes are verified, publish the draft:

```sh
gh release edit vX.Y --draft=false
```

Creating a draft prepares the release; it does not satisfy the published-release
acceptance criterion. Do not move or replace a published tag to fix a defect;
record it and release a corrected version.

## 5. Check the release

Download both files from the release page (not your local copies), follow
[installing.md](installing.md), and confirm the SHA1 matches the release notes.
For a milestone release, ask another developer to do this too.

For **v1.0**, two developers (bernardosevero and leomayca) must install only
the downloaded release patch and client, then play together over the internet
for **20+ minutes**.
Use the [session checklist](release-v1.md#release-only-acceptance-session).
Publishing the assets can happen before that session; the session,
retrospective and v1.5 scheduling keep
[#27](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/27) open until completed.
For preparation-only PRs, reviewers use the
[closing-link check](../.claude/skills/pre-commit/SKILL.md#4-check-issue-closing-links)
to confirm GitHub will leave that tracker open.
