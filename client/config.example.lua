-- Copy this file to client/config.lua and edit it. config.lua is ignored by Git.
-- Never commit a real join key or a public server address.
return {
	SERVER_HOST = "127.0.0.1", -- server host name or IP address
	SERVER_PORT = 8765, -- server TCP port
	PLAYER_ID = "your-player-id", -- unique per player: 1-16 of a-z, A-Z, 0-9, _ and -
	JOIN_KEY = "", -- shared join key from the server host
	DEBUG = false, -- true logs state/presence detail; the debug panel stays visible either way
	-- Debug (#81): trade over the virtual link with this player once both are
	-- online and in the overworld. Use disposable saves. See docs/virtual-link.md.
	-- TRADE_LINK_PARTNER = "partner-id",
}
