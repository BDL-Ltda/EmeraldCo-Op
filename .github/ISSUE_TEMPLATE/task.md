---
name: Task
about: Define one scoped Emerald Co-Op task with acceptance criteria and test steps.
title: ""
labels: ""
assignees: ""
---

## Context

<!-- Explain the problem and link relevant architecture decisions or issues. -->

## Scope

<!-- List the work this issue includes. -->

## Out of scope

<!-- List related work that belongs in separate issues. -->

## Acceptance criteria

- [ ] <!-- Describe an observable requirement. -->

## How to test

<!-- Provide commands and manual steps, including expected results. -->

## Dependencies

<!-- Write "None" or "Blocked by #N" for each blocking issue. -->

## Definition of Done

<!-- Keep this checklist intact. Explain non-applicable checks in the PR;
     do not mark an unavailable or skipped check as passed. -->

- [ ] All acceptance criteria are checked
- [ ] Automated tests added or updated where it makes sense (Go: `go test`; Lua: `client/tests`; tools: golden files)
- [ ] CI is green (vet, test, luacheck, ROM build)
- [ ] Manual test steps from "How to test" done, with the result in the PR (screenshot or log for emulator work)
- [ ] For `needs:multiplayer-test`: tested with at least 2 devs, and who tested it is noted in the PR
- [ ] Docs updated (`protocol.md` / `memory-map.md` / README) if behavior, addresses or the protocol changed
- [ ] No ROMs, saves, BIOS or built `.gba` files committed
- [ ] PR reviewed and approved by one human, and merged with `Closes #N`
