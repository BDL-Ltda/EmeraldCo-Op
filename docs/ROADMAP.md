# Roadmap

This roadmap records the release sequence agreed in [issue #2](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/2). It describes planned work, not implemented features. GitHub issues and their dependencies determine which tasks are ready; completing the repository skeleton does not complete the foundation milestone.

## 0.0: Foundations

Set up the repository layout and root Go module, ROM fork/submodule, Docker ROM build, generated memory addresses, CI and release process. Foundation work is tracked in [milestone 0.0](https://github.com/BDL-Ltda/EmeraldCo-Op/milestone/1) through issues #1-#7. This skeleton is [#2](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/2); runtime server, client and tool logic are outside its scope.

## v1: Overworld presence

| Milestone | Planned result |
| --- | --- |
| [0.1: Read state](https://github.com/BDL-Ltda/EmeraldCo-Op/milestone/2) | Validate mGBA Lua scripting and read the local player's state using generated addresses. |
| [0.2: Networking](https://github.com/BDL-Ltda/EmeraldCo-Op/milestone/3) | Define the protocol, implement the Go relay and Lua client, and test online presence. |
| [0.3: Debug view](https://github.com/BDL-Ltda/EmeraldCo-Op/milestone/4) | Show remote players in a text debug view. |
| [0.4: In-game presence](https://github.com/BDL-Ltda/EmeraldCo-Op/milestone/5) | Add the ROM mailbox and remote-player rendering, then release v1. |

Milestones 0.1-0.3 read the unmodified game's state through Lua. Starting at 0.4, co-op C code in the ROM handles in-game presence, and Lua bridges the mailbox and TCP socket. Every player uses our built ROM from 0.1 onward. v1 synchronizes presence only; saves, battles and items stay local. See [architecture.md](architecture.md).

## Later versions

| Version | Planned direction |
| --- | --- |
| v1.5 | Trading. |
| v2 | PvP battles. |
| v2.5 | Duo battle against an NPC. |
| v3 | Shared profile. |
| v4 | Nuzlocke mode. |
| Unversioned | Custom sprites; no release assignment yet. |

**Each version is re-planned before it starts.** Future epics describe direction and must be broken down into scoped issues with acceptance criteria and dependencies before implementation. Custom sprites remain unversioned until that planning assigns them a place.
