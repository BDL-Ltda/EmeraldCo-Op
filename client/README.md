# mGBA Lua client

This directory will contain the Lua 5.4 client for mGBA. No runnable client exists
yet. The emulator version, frame callback, memory API and native non-blocking
sockets will be validated in
[issue #8](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/8).

Milestones 0.1-0.3 read local player state using addresses generated from our
built ROM's ELF. From 0.4, the client bridges the ROM mailbox and the TCP socket.
See the [architecture](../docs/architecture.md) and
[memory map](../docs/memory-map.md).

## Local configuration

`config.example.lua` is a placeholder for the configuration schema. Copy it to
`config.lua` when implementing or configuring the client. The local file is
ignored by Git. Set a unique `PLAYER_ID` and keep any real join key private.
Connection settings and configuration loading will be defined with the network
client in [issue #17](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/17).

Generated addresses will live in `addresses.lua` after
[issue #4](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/4). Do not create
that file by guessing addresses. Future pure modules belong in `lib/`, with a
small test runner in `tests/` added by
[issue #16](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/16).
