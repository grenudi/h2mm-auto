# h2mm-auto

A wrapper around [`h2mm-cli`](https://github.com/v4n00/h2mm-cli) that:

- checks/acquires runtime dependencies (`curl`, `jq`, `unzip`)
- pulls the latest `h2mm` script straight from v4n00/h2mm-cli's `master` branch
- pulls the latest [BingusSharedLoader](https://github.com/CowboyBingus/BingusSharedLoader)
  and [VanillaPlusMegapack](https://github.com/CowboyBingus/VanillaPlusMegapack) releases and
  installs them
- compares your installed versions to the latest releases and, **only if
  something is newer, removes the old mods and installs the latest of
  both** — zero flags needed

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

This downloads `h2mm-auto.sh` once to `~/.local/share/h2mm-auto/h2mm-auto.sh`
and adds a single `alias` line to your `~/.bashrc` that runs *that local
copy*, then runs it immediately.

It deliberately does **not** re-download and execute the script fresh from
GitHub on every run. An alias that does `bash <(curl ... | main branch)`
means every future `hd2up` silently runs whatever is on `main` at that
moment — if the repo (or my GitHub account) were ever compromised, or a bad
change slipped in after you'd already looked at the script once, you'd
re-execute it without ever knowing. Caching a local copy means new code
from the repo only ever runs when you explicitly re-run this same setup
line to pull it — an update is a deliberate action, not something that
happens invisibly the next time you type `hd2up`.

The alias is named `hd2up` rather than `h2mm-auto` just to keep it visibly
distinct from the script's own filename in the alias definition below.

Safe to paste and run again any time — this is also how you update: it
won't duplicate the alias line in `.bashrc`, but it does overwrite the
local copy with whatever is currently on `main`:

```bash
mkdir -p ~/.local/share/h2mm-auto && curl -fsSL https://raw.githubusercontent.com/grenudi/h2mm-auto/main/h2mm-auto.sh -o ~/.local/share/h2mm-auto/h2mm-auto.sh && chmod +x ~/.local/share/h2mm-auto/h2mm-auto.sh && (grep -qxF 'alias hd2up="$HOME/.local/share/h2mm-auto/h2mm-auto.sh"' ~/.bashrc 2>/dev/null || echo 'alias hd2up="$HOME/.local/share/h2mm-auto/h2mm-auto.sh"' >> ~/.bashrc); source ~/.bashrc; ~/.local/share/h2mm-auto/h2mm-auto.sh
```

That single line: downloads the script to its permanent local path, makes
it executable, adds the alias if it isn't already there, reloads your
`.bashrc`, and runs the script directly (not via `hd2up`) for this first
time — removing old Bingus mods and installing the latest loader +
megapack in one go.

It calls the script by its full path instead of `hd2up` here on purpose:
bash resolves aliases when it parses a line, before running any of it, so
an alias defined earlier in that *same* pasted line (by the `source` just
before it) isn't recognized yet by the end of that same line — you'd get
`hd2up: command not found` even though the alias was just added correctly.
From the next terminal (or just typing `hd2up` again right after), it's
there.

## After that

Every new terminal session just has `hd2up` ready to go — running it does
the whole thing: remove old Bingus/Vanilla Plus mods, fetch the latest
loader and megapack, install both.

```bash
hd2up
```

`hd2up` on its own always runs the local copy at
`~/.local/share/h2mm-auto/h2mm-auto.sh` as-is — it does not check GitHub or
update itself. To pull in script changes, re-run the one-liner from
**Setup** above.

## If something goes wrong: `--verbose` / `--debug`

```bash
hd2up --verbose   # extra lines: which GitHub release it checked, what matched, which URL it's downloading
hd2up --debug     # all of the above, plus a full shell trace (set -x) and h2mm's own raw output
```

Normal runs are deliberately quiet (see **Running it from a Steam launch
option** above for why), so if a step fails — most likely
`!! NO MATCHING SUPPLY DROP LOCATED`, meaning a release's assets didn't
match what the script expects — `--debug` is what tells you why: it prints
the exact list of asset filenames GitHub actually returned for that
release, so you can see at a glance whether the repo renamed something,
dropped a variant, or GitHub just rate-limited the (unauthenticated)
API call.

## Running it from a Steam launch option

Yes — chaining it in front of `%command%` works. No separate install needed:
it reuses the exact same local copy the **Setup** one-liner already put at
`~/.local/share/h2mm-auto/h2mm-auto.sh`, just called by its full path instead
of through the `hd2up` alias — Steam's launch command isn't an interactive
shell, so it never sources `.bashrc` and wouldn't see the alias anyway. No
`$PATH`, no second copy of the script, no NixOS-vs-everyone-else PATH
weirdness to work around, nothing to name-collide with `hd2up`.

```
~/.local/share/h2mm-auto/h2mm-auto.sh; MANGOHUD=1 PROTON_USE_NTSYNC=1 gamemoderun game-performance %command% --use-d3d11
```

Steam runs the whole launch-options string through a shell, so `;` just
means "run the script, then (regardless of whether it succeeded) launch the
game." That's deliberate — use `;`, not `&&`. If you're offline, or a
release temporarily 404s, you still want the game to start.

On CachyOS, `game-performance` (from `cachyos-gaming-meta`) is a wrapper
around `%command%` that uses `power-profiles-daemon` to force the
`performance` power profile — governor included, plus switching an active
scx scheduler to its gaming profile if there is one — for as long as the
game runs, then restores whatever profile was active before. It's not
needed on other distros; drop it there.

One prerequisite: run the **Setup** one-liner above at least once, normally,
in an actual terminal, before wiring this into Steam. That first run is also
what makes `h2mm` ask where your Helldivers 2 install lives — a prompt that
has nowhere to go when launched from Steam later (no terminal attached).
Once you've answered it that one time, it's cached to `~/.config/h2mm/h2path`
and every later run, including from the Steam launch option, reuses it
silently. If you've already run `hd2up` at least once, you're already done —
just paste the line above into **Properties → Launch Options** for the game.

Worth knowing: on every launch it first checks (read-only) which versions
you have installed against the latest releases. If both match, it does
nothing at all — nothing is downloaded or removed, so it adds well under a
second. Only when a newer version exists does it download, remove the old
mods and install the new ones, and it prints a line like
`UPDATE ACQUIRED: Vanilla-Plus-Megapack-v37 -> Vanilla-Plus-Megapack-v38`.
Downloads happen before anything is removed, so if a launch happens offline
or GitHub hiccups, your installed mods are left exactly as they were.

If you ever want to reinstall even though the versions match (say a game
patch wiped the mod files), run `hd2up --force`.

A Steam launch has no terminal to print to, so the output of the most recent
run without a terminal is kept in a file you can read afterwards — this is
the first place to look if mods aren't what you expect after launching:

```bash
cat ~/.local/share/h2mm-auto/last-run.log
```

(The script also clears `LD_LIBRARY_PATH` / `LD_PRELOAD` for itself, since
Steam sets those for the game and they can break system `curl`/`unzip`
when inherited. The game itself is not affected.)