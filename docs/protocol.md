# Protocol

Status: documentation stub. The protocol and codec are not implemented by the repository skeleton.

[Issue #12](https://github.com/DaviAlencastro/EmeraldCo-Op/issues/12) will define the message contract. The decisions already agreed are **JSON lines over TCP** and a generic envelope containing **`v`** and **`type`**, plus message-specific fields. See [architecture.md](architecture.md) for the relay, identity and v1 synchronization boundary.

The detailed message types, field schemas, version rules, validation, framing limits and examples will be documented here with the implementation. No message schema or wire behavior is specified by this stub.
