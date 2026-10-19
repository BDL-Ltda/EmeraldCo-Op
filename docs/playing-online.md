# Playing online

The MVP host is **leomayca's Windows PC**, using IPv4 port forwarding and a
private shared join key. There is one room with at most five players. The
[server](server.md) and [fakeclient](fakeclient.md) can test this path without
a ROM or emulator. The mGBA networking integration is separate work in #17;
hosting a relay does not yet make remote players appear in the game.

**Validation status:** the host confirmed no CGNAT in
[issue #18](https://github.com/BDL-Ltda/EmeraldCo-Op/issues/18#issuecomment-6256865347).
Router forwarding, the host firewall and a successful fakeclient welcome from
another developer on a different network still need to be verified. Local
checks alone do not complete #18. Never record real IPs, hostnames, keys or raw
server logs in the repository, issues or PRs.

## 1. Check the connection before opening a port

On the host's connection, with VPN/proxy disabled, compare the router's
**WAN/Internet IPv4** with the IPv4 reported by a public-IP lookup. They must
match and be publicly routable. The PC's LAN address is not the WAN address.

Stop and report the result privately if they differ, or the WAN is in:

- `100.64.0.0/10` (shared address space, RFC 6598).
- `10.0.0.0/8`, `172.16.0.0/12` or `192.168.0.0/16` (private space, RFC 1918).

These results indicate upstream NAT/possible CGNAT or double NAT; a forwarding
rule on this router alone is not enough. Follow #18's stop condition and ask
the ISP about a public IPv4. Do not substitute a VPS, tunnel or VPN: they are
out of scope. Record only **CGNAT yes/no**, and who checked it, in the issue.

## 2. Build the host tools

Use the same repository revision on both developers' machines and the Go
version pinned in `go.mod`. From the repository root, in PowerShell:

```powershell
go build -o bin/hosting/server.exe ./cmd/server
go build -o bin/hosting/fakeclient.exe ./cmd/fakeclient
```

`bin/` is ignored. Do not commit these executables. A built server does not
need Go installed to run; keep it in the same location used by the firewall
rule below. The commands in this guide assume the repository root is the
current directory.

## 3. Forward TCP 8765 to the host PC

1. Find the host PC's LAN IPv4 with `Get-NetIPConfiguration` or `ipconfig`.
   Reserve it in the router's DHCP settings so it does not change later.
2. In the router's port-forwarding/NAT/virtual-server settings, create one rule:

   | Setting | Value |
   | --- | --- |
   | Protocol | **TCP only**, not UDP or both |
   | External/WAN port | `8765` |
   | Destination | The host PC's reserved **LAN IPv4** |
   | Internal/LAN port | `8765` |

3. Apply the rule. If the router supports a source-IP restriction, limit it to
   the other developers' public IPv4s, exchanged privately.

Friends connect to the **public IPv4** (or a private-share-only DDNS hostname),
not to the PC's LAN address. Do not use the public address as the router rule's
internal destination, enable a DMZ, expose router administration, or disable
the router firewall.

## 4. Allow only this server in Windows Firewall

Do not disable Windows Firewall or change a network's trust category just to
make hosting work. In an **administrator PowerShell**, inspect the current
interface and create a rule for its existing Private or Public profile:

```powershell
Get-NetConnectionProfile | Select-Object InterfaceAlias, NetworkCategory
$hostingInterface = Read-Host 'Host interface alias from the list above'
$hostingProfile = (Get-NetConnectionProfile -InterfaceAlias $hostingInterface -ErrorAction Stop).NetworkCategory
if ("$hostingProfile" -notin @('Private', 'Public')) {
    throw 'This home-hosting guide requires one Private or Public interface; ask your administrator otherwise.'
}
$serverProgram = (Resolve-Path -LiteralPath '.\bin\hosting\server.exe').Path
New-NetFirewallRule -Name 'EmeraldCoOp-TCP-8765' -DisplayName 'Emerald Co-Op TCP 8765' `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8765 `
    -Program $serverProgram -Profile $hostingProfile -InterfaceAlias $hostingInterface
```

The rule is limited by executable, interface, profile and TCP port. For a
stricter rule, add `-RemoteAddress` with only the friends' public IPv4s, entered
privately. If that rule name already exists, inspect it with
`Get-NetFirewallRule -Name 'EmeraldCoOp-TCP-8765'`; do not create broad fallback
rules. A changed executable path or network profile requires reviewing this
rule. Managed firewall policy may require an administrator's help.

Microsoft documents [rule creation](https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallrule),
[network profiles](https://learn.microsoft.com/en-us/powershell/module/netconnection/get-netconnectionprofile)
and [rule inspection](https://learn.microsoft.com/en-us/powershell/module/netsecurity/get-netfirewallrule).

## 5. Start the server with a private key

Create a fresh, unpredictable key for this project, 1–64 characters with no
control characters. Share it and the host address only in your trusted private
group or password manager. Do not reuse a password from another service.
The protocol is plain TCP, **not encrypted**; the key is an access check, not
transport encryption. Use this MVP only with trusted friends, not as a public
service. See the server's [limits](server.md#presence-liveness-and-limits).

On Windows, double-click [`start-server.bat`](../start-server.bat) at the
repository root. It opens a visible PowerShell window, asks for the key at a
masked prompt and runs `bin/hosting/server.exe` in the foreground. Keep that
window open to see the logs; **Ctrl+C** stops the server, and the window stays
open so errors remain visible. Close it when finished. Run it as a normal user,
not as administrator. Build the executable in step 2 first; the launcher does
not build/download tools, configure the router or change firewall rules.

The launcher passes the key through the child environment, removes it when
the server stops, and never saves it to a file. Its execution-policy override
applies only to the new PowerShell process; it does not change machine policy.
Managed policy can still prevent scripts from running; ask your administrator
instead of changing that policy.

Alternatively, use a normal (non-administrator) PowerShell. Enter the key at
the masked prompt so it is not a literal command-line argument or history entry:

```powershell
$hostingKey = Read-Host 'Server join key (shared privately)' -AsSecureString
$env:SERVER_JOIN_KEY = [System.Net.NetworkCredential]::new('', $hostingKey).Password
Remove-Variable hostingKey
try {
    & .\bin\hosting\server.exe -addr '0.0.0.0:8765' -max-players 5
} finally {
    Remove-Item Env:SERVER_JOIN_KEY -ErrorAction SilentlyContinue
}
```

`0.0.0.0:8765` binds IPv4 on the host's interfaces; it is not an address to send
to friends. Do not bind to the public IPv4 when it belongs to the router, or
to `localhost` for external hosting. Keep the PC awake and this terminal open.
Ctrl+C stops the listener and its clients. Keys also exist in process memory
and the child environment; a masked prompt does not protect a compromised PC.

In a second terminal, check that a listener exists:

```powershell
Get-NetTCPConnection -State Listen -LocalPort 8765 |
    Select-Object LocalAddress, LocalPort, OwningProcess
```

The expected local address is `0.0.0.0`. This is a local listener check, not
proof that Internet traffic can reach it.

## 6. Test from another developer's network

Another developer must connect from a **different network**, not another PC on
the host's Wi-Fi. A same-LAN test, a port-check website or a connection from
the host to its own public address does not satisfy #18; NAT loopback support
varies by router.

The other developer builds fakeclient as above, then uses their own terminal:

```powershell
$hostAddress = Read-Host 'Host public IPv4 or DDNS name (shared privately)'
$clientKey = Read-Host 'Join key (shared privately)' -AsSecureString
$env:FAKECLIENT_JOIN_KEY = [System.Net.NetworkCredential]::new('', $clientKey).Password
Remove-Variable clientKey
try {
    & .\bin\hosting\fakeclient.exe -addr ("{0}:8765" -f $hostAddress) -id external-test -pattern idle
} finally {
    Remove-Item Env:FAKECLIENT_JOIN_KEY -ErrorAction SilentlyContinue
}
```

Success means fakeclient prints `[welcome] players=...`, then periodic `[pong]`
messages. Stop it with Ctrl+C. If a host-side fakeclient is also connected
(use `-addr 127.0.0.1:8765`, a different ID and the same private key), it sees
the remote join and leave. See [fakeclient.md](fakeclient.md) for movement tests.

Record the tested Git revision, tester's name, confirmation that they used a
different network, and a sanitized welcome/pong result in #18 and the PR.
Do not paste the address, key, full command history or raw server logs: server
logs contain remote addresses, and transport errors can contain host addresses.
Until this test succeeds, external reachability remains **unverified**.

## Player settings for the mGBA client

The installed Lua scripts and patched ROM must match; see
[installing.md](installing.md). Copy `client/config.example.lua` to the ignored
`client/config.lua`, then set these values locally:

- `SERVER_HOST`: the host's public IPv4 or DDNS name, supplied privately.
- `SERVER_PORT`: `8765`.
- `PLAYER_ID`: a unique 1–16 character name using `a-z`, `A-Z`, `0-9`, `_` or `-`.
- `JOIN_KEY`: the private shared key. Never commit or post this file.
- `DEBUG`: normally `false`; sanitize any logs before sharing.

The host's own client can use `127.0.0.1`; peers on another network cannot.
Configuration loading and memory reads are implemented, but this checkout's
bridge does **not yet connect to the relay** (#17). Use fakeclient for #18's
network acceptance test; changing Lua settings alone is not that test.

## Dynamic addresses and troubleshooting

If the **public IPv4** changes, privately send the new address to friends;
update `SERVER_HOST` or restart fakeclient with the new `-addr`. Optionally use
a DDNS hostname kept current by the router/provider's updater, and share that
name privately. DDNS only tracks an address: it does not bypass CGNAT, open a
port or configure the firewall. Recheck CGNAT after an ISP/router change.

If the **LAN IPv4** changes, fix the DHCP reservation and forwarding target.
If friends' addresses are allowlisted, update those restrictions when needed.

| Symptom | Check |
| --- | --- |
| No local listener | Server process still running; valid join key; port not occupied. |
| Local client works, external connection times out/refuses | Current public IPv4, router TCP rule, LAN destination, Windows profile/program rule, ISP inbound filtering. Recheck the WAN comparison; do not disable either firewall. |
| `bad_key` | Share the same key privately and restart the server/clients after rotation. |
| `room_full` or a peer is replaced | At most five connections; use distinct player IDs. |
| `version_mismatch` | Both developers should use compatible code from the same revision. |
| Fakeclient works but no remote avatar in mGBA | Network bridge/rendering milestones are not completed by this hosting guide. |

## Stop hosting and clean up

Stop server and fakeclients with Ctrl+C; remove the environment variables if
you entered them outside the `try/finally` blocks. Disable/remove the router's
TCP forwarding rule when not hosting. To remove only the rule created above,
use an administrator PowerShell:

```powershell
Remove-NetFirewallRule -Name 'EmeraldCoOp-TCP-8765'
```

Do not delete unrelated firewall rules. If a key or address is accidentally
published, remove the exposure, stop hosting, rotate the key, and tell the
group privately. Deleting a public comment does not make a leaked key safe.

Address-space references: [RFC 6598](https://www.rfc-editor.org/rfc/rfc6598)
and [RFC 1918](https://www.rfc-editor.org/rfc/rfc1918). Windows cleanup:
[Remove-NetFirewallRule](https://learn.microsoft.com/en-us/powershell/module/netsecurity/remove-netfirewallrule).
