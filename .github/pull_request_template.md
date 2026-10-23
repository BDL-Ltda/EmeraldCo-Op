<!-- Use Refs for partial work. Use Closes only when the full issue scope and
     acceptance requirements are complete. Verify actual GitHub closing links
     after opening and again before merge; the description alone is not proof. -->
Refs #<!-- Replace with the issue number. -->

## What

<!-- Describe the change and why it is needed in 1–3 sentences. -->

## How I tested

<!-- List the commands run and their results, then the issue's manual test
     steps and results. Attach a screenshot or log for emulator work.
     For needs:multiplayer-test, name the developers who tested together.
     Explain every skipped or non-applicable check and any missing tooling. -->

## Checks

<!-- Check only completed, passing checks. Leave non-applicable checks
     unchecked and explain them above. Run every check whose tooling exists:
     Go when go.mod exists; Lua when client/tests exists; ROM build and
     address generation when rom/ or the submodule pointer changed. -->

- [ ] go vet / go test -race
- [ ] Lua tests / luacheck
- [ ] ROM build + addresses.lua regenerated (if rom changed)
- [ ] Docs updated (if behavior/protocol/memory changed)
- [ ] No forbidden files or secrets
- [ ] Actual GitHub closing links match completed scope (see pre-commit skill, step 4)

## Definition of Done

<!-- Keep this checklist intact. Explain non-applicable items in How I tested.
     CI can only be checked when the applicable CI checks exist and pass.
     Leave human approval and merge unchecked until they actually happen. -->

- [ ] All acceptance criteria are checked
- [ ] Automated tests added or updated where it makes sense (Go: `go test`; Lua: `client/tests`; tools: golden files)
- [ ] CI is green (vet, test, luacheck, ROM build)
- [ ] Manual test steps from "How to test" done, with the result in the PR (screenshot or log for emulator work)
- [ ] For `needs:multiplayer-test`: tested with at least 2 devs, and who tested it is noted in the PR
- [ ] Docs updated (`protocol.md` / `memory-map.md` / README) if behavior, addresses or the protocol changed
- [ ] No ROMs, saves, BIOS or built `.gba` files committed
- [ ] PR reviewed and approved by one human, and merged with `Closes #N`
