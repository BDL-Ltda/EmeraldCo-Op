# Playing online

Status: documentation stub. Online play and hosting are not available from the repository skeleton.

[Issue #18](https://github.com/DaviAlencastro/EmeraldCo-Op/issues/18) will provide tested instructions for hosting, joining and troubleshooting. The MVP plan is for **leomayca** to host with **port forwarding**, a **shared join key** and **basic limits**. There are no accounts; v1 has one global room for up to five players. See [architecture.md](architecture.md).

Use mGBA with Lua 5.4 scripting and our built ROM from milestone 0.1 onward. The ROM is distributed as a BPS patch. Local client settings, including `PLAYER_ID`, belong in the ignored `client/config.lua`; [client/config.example.lua](../client/config.example.lua) contains placeholder settings. Configuration loading and connection settings are not implemented yet.

Keep join keys, public IPs and secrets out of the repository, issues and pull requests. Actual host addresses, ports, connection commands and troubleshooting steps will be documented only once the corresponding implementation is available and tested.
