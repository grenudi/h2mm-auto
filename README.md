# h2mm-auto

A wrapper around [`h2mm-cli`](https://github.com/v4n00/h2mm-cli) that:

- checks/acquires runtime dependencies (`curl`, `jq`, `unzip`)
- pulls the latest `h2mm` script straight from v4n00/h2mm-cli's `master` branch
- pulls the latest [BingusSharedLoader](https://github.com/CowboyBingus/BingusSharedLoader)
  and [VanillaPlusMegapack](https://github.com/CowboyBingus/VanillaPlusMegapack) (Rows variant)
  releases and installs them
- by default, **removes old Bingus/Vanilla Plus mods first, then installs
  the latest of both** — zero flags needed

> **Note on the uninstall step:** it parses `h2mm list` output to find
> Bingus/Vanilla-Plus entries automatically. That parsing is a best-effort
> guess at the output format — if it can't find anything or the format
> doesn't match, it just skips that step and moves on to installing, rather
> than failing the whole run. For precise manual control, run the underlying
> `h2mm` binary directly — it lives at `~/.local/share/h2mm-auto/bin/h2mm`
> after the first run (e.g. `~/.local/share/h2mm-auto/bin/h2mm uninstall --index 3`).

## Dependencies

The script needs `curl`, `jq`, and `unzip`. Package names are identical
across every distro below, so these are just the install commands:

| Distro / family | Install command |
|---|---|
| Debian, Ubuntu, Mint, Pop!_OS | `sudo apt update && sudo apt install -y curl jq unzip` |
| Fedora, RHEL, CentOS Stream | `sudo dnf install -y curl jq unzip` |
| Arch, CachyOS, Manjaro, EndeavourOS | `sudo pacman -S --needed curl jq unzip` |
| openSUSE | `sudo zypper install -y curl jq unzip` |
| Alpine | `sudo apk add curl jq unzip` |
| Void | `sudo xbps-install -Sy curl jq unzip` |
| Solus | `sudo eopkg install -y curl jq unzip` |
| NixOS | Nothing to do — the script detects `nix-shell` and re-enters itself with the missing packages automatically. To do it manually anyway: `nix-shell -p curl jq unzip` |

## Setup (one line, run once)

This does not install anything permanent or touch your `$PATH`. It adds a
single `alias` line to your `~/.bashrc` that re-downloads `h2mm-auto.sh`
fresh from GitHub every time you run it — so you always get the current
version with zero update step — then runs it immediately.

Safe to paste and run again any time (it won't duplicate the line in
`.bashrc` on repeat runs):

```bash
grep -qxF "alias h2mm-auto='bash <(curl -fsSL https://raw.githubusercontent.com/grenudi/h2mm-auto/main/h2mm-auto.sh)'" ~/.bashrc 2>/dev/null || echo "alias h2mm-auto='bash <(curl -fsSL https://raw.githubusercontent.com/grenudi/h2mm-auto/main/h2mm-auto.sh)'" >> ~/.bashrc; source ~/.bashrc; h2mm-auto
```

That single line: adds the alias if it isn't already there, reloads your
`.bashrc` so it's active in the current shell too, and runs `h2mm-auto`
immediately — removing old Bingus mods and installing the latest loader +
Rows megapack in one go.

## After that

Every new terminal session just has `h2mm-auto` ready to go — running it
does the whole thing: remove old Bingus/Vanilla Plus mods, fetch the
latest loader and Rows megapack, install both.

```bash
h2mm-auto
```

Since the alias always re-fetches `h2mm-auto.sh` from `main` before running,
there's nothing to update on your end — pushing changes to the repo is the
only "release" step that exists.
