-- luacheck configuration for client/. Run: luacheck client/
std = "lua54"
max_line_length = 120

-- mGBA scripting globals (https://mgba.io/docs/scripting.html). Allowed only for
-- scripts that run inside mGBA; client/lib/ must stay pure and never use them.
files["client/spike"] = {
  read_globals = { "callbacks", "console", "emu", "socket" },
}
files["client/bridge.lua"] = {
  read_globals = { "callbacks", "console", "emu", "socket" },
}
files["client/debug"] = {
  read_globals = { "callbacks", "console", "emu" },
}
