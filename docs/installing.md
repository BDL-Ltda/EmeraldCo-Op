# Installing Emerald Co-Op

This guide is for players. Emerald Co-Op is distributed as a **`.bps` patch**
that you apply to your own Pokémon Emerald ROM. We never distribute the game
itself.

Releases are published on the repository's
[Releases page](https://github.com/BDL-Ltda/EmeraldCo-Op/releases). Each release
has two files:

- `emerald-coop-vX.Y.bps`: the ROM patch.
- `emerald-coop-vX.Y-client.zip`: the mGBA Lua scripts.

Always use the patch and scripts from the **same** release. The scripts only
work with the ROM produced by their matching patch.

## What you need

- **mGBA**, at the version pinned in the [README](../README.md). Other versions
  may not run the scripts, because mGBA's scripting API changes between
  versions.
- Your own legally dumped **Pokémon Emerald (USA)** ROM. Its SHA1 must be:

  ```text
  f3ae088181bf583e55daf962a92bb46f4f1d07b7
  ```

- [Flips](https://github.com/Alcaro/Flips) (Floating IPS), a free patch tool.

## 1. Install mGBA

Download the pinned version from [mgba.io](https://mgba.io/downloads.html) and
install it. Check the version in **Help → About**.

## 2. Patch the ROM

Download Flips from its [releases page](https://github.com/Alcaro/Flips/releases).
On Linux you can also install it from
[Flathub](https://flathub.org/apps/com.github.Alcaro.Flips).

First check your ROM's SHA1. In PowerShell:

```powershell
Get-FileHash -Algorithm SHA1 .\emerald-us.gba
```

In a macOS or Linux terminal:

```sh
sha1sum emerald-us.gba     # macOS: shasum emerald-us.gba
```

If the hash is different, your ROM is a different version or region, or it
has been modified. The patch will refuse to apply to it.

Then apply the patch. Flips never modifies your original ROM; it writes a new
file.

- **Flips window:** click **Apply Patch**, choose `emerald-coop-vX.Y.bps`,
  choose your ROM, then save the result as `emerald-coop-vX.Y.gba`.
- **Command line:**

  ```sh
  flips --apply emerald-coop-vX.Y.bps emerald-us.gba emerald-coop-vX.Y.gba
  ```

If Flips says `This patch is not intended for this ROM`, your base ROM is wrong.
Go back and check its SHA1.

Finally, check the patched ROM's SHA1 the same way. It must match the
**Patched ROM** SHA1 in the release notes. If it doesn't, don't play with it.
Re-download the patch and try again.

## 3. Set up the client scripts

Unzip `emerald-coop-vX.Y-client.zip` somewhere permanent whose path has **only
ASCII characters**, for example `C:\EmeraldCoop`. Lua in mGBA can't open files
under folders with accents, such as `C:\Users\Usuário\Downloads`. Inside its
`client/` folder, copy `config.example.lua` to `config.lua` and fill it in:

- `PLAYER_ID`: a name that is unique among the players.
- The server and join-key settings: the host sends them to you privately. See
  [playing-online.md](playing-online.md).

Keep `config.lua` to yourself. Never post your join key or the server address
in public.

## 4. Play

1. Open mGBA and load `emerald-coop-vX.Y.gba` (**File → Load ROM**).
2. Open **Tools → Scripting...**.
3. In the scripting window, choose **File → Load script...** and select
   `client/bridge.lua`.

The scripting window shows the client's log. If it reports a ROM mismatch, you
loaded a ROM that doesn't match these scripts: patch the ROM again with the
`.bps` from the same release.

Your save stays on your computer: mGBA stores it next to the patched ROM, named
after it. Emerald Co-Op only shares your position with other players.
