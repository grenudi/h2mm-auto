#!/usr/bin/env bash
# h2mm-auto: remove old CowboyBingus mods, install the latest ones.
# No subcommands needed — just run it. Optional: --verbose, --debug, --force (see README).
set -euo pipefail

# Steam injects its own runtime libraries into every launch-option command
# (LD_LIBRARY_PATH, and LD_PRELOAD for its overlay), and plain system tools
# like curl or unzip can refuse to run against them. Only this script and
# what it starts see this change — the game, launched afterwards by Steam
# itself, is untouched.
unset LD_LIBRARY_PATH LD_PRELOAD

VERBOSE=0
DEBUG=0
FORCE=0
for _arg in "$@"; do
  case "$_arg" in
    --force)   FORCE=1 ;;
    --verbose) VERBOSE=1 ;;
    --debug)   VERBOSE=1; DEBUG=1 ;;
  esac
done
unset _arg
[ "$DEBUG" -eq 1 ] && set -x

# ---- config ------------------------------------------------------------
H2MM_REPO="v4n00/h2mm-cli"
H2MM_URL="https://raw.githubusercontent.com/${H2MM_REPO}/master/h2mm"
SELF_URL="https://raw.githubusercontent.com/grenudi/h2mm-auto/main/h2mm-auto.sh"

LOADER_REPO="CowboyBingus/BingusSharedLoader"
# Anchored to the exact "Word-Word-Word-vNN.zip" shape of the real asset, not
# just "ends in .zip" — a release also ships a same-repo
# "BingusSharedLoader-source-vNN.zip" (no hyphens between words) and a
# SHA256SUMS.txt; a loose '\.zip$' matches that source zip too and only
# happened to pick the right one by asset-list order, not by actually being
# precise about it.
LOADER_PATTERN='^Bingus-Shared-Loader-[^-]+\.zip$'

MEGAPACK_REPO="CowboyBingus/VanillaPlusMegapack"
# As of v36 upstream discontinued the separate "Rows" package (its changelog:
# "Discontinues the Rows package, since Know Your Constellation v4 has a
# single layout; Rows users should switch to this pack") and now ships one
# unified "Vanilla-Plus-Megapack-vNN.zip" with no "Rows" in the name at all —
# hence the old 'Rows.*\.zip$' pattern matching nothing. Anchored the same
# way as the loader pattern above, for the same reason (there's also a
# "VanillaPlusMegapack-source-vNN.zip" to not accidentally match).
MEGAPACK_PATTERN='^Vanilla-Plus-Megapack-[^-]+\.zip$'

H2MM_AUTO_HOME="${H2MM_AUTO_HOME:-$HOME/.local/share/h2mm-auto}"
BIN_DIR="$H2MM_AUTO_HOME/bin"
H2MM_BIN="$BIN_DIR/h2mm"
DOWNLOADS="${H2MM_AUTO_DOWNLOADS:-$HOME/Downloads}"
DEPS=(curl jq unzip)

# names we already know, straight from the release filenames — used to find
# them again in `h2mm list` output (see mod_entry_in_listing below).
LOADER_NAME="Bingus-Shared-Loader"
MEGAPACK_NAME="Vanilla-Plus-Megapack"

# FIRST_RUN gates whether h2mm's own prompts (first-time "is this your HD2
# folder? (Y/n)", or a manual path entry if auto-detection can't find it at
# all, or the variant-picker on install) go to the real terminal, or get
# silently auto-accepted. Only the very first run — ever, or after deleting
# this marker — talks to the user; every run after that (including from a
# Steam launch option, which has no terminal to talk to) is silent, the same
# as it's always been. Previously EVERY run auto-accepted blind, which is
# fine once h2mm already knows where the game is — but on an environment
# where auto-detection comes back different or empty (seen from a Steam
# launch instead of a normal terminal), an unattended empty answer can steer
# h2mm onto the wrong directory (or a blank one), and the mods it "installs"
# after that aren't going anywhere real — which is exactly what silently
# wiped out an install here before.
FIRST_RUN_MARKER="$H2MM_AUTO_HOME/.first-run-done"
if [ -e "$FIRST_RUN_MARKER" ]; then FIRST_RUN=0; else FIRST_RUN=1; fi

# filled in by scan_installed_mods() with whatever was installed before
# this run, so main() can tell the user when the freshly fetched asset is a
# different version (see notify_update below).
PREV_LOADER_VERSION=""
PREV_MEGAPACK_VERSION=""
LOADER_INDEX=""
MEGAPACK_INDEX=""

# With no terminal attached (a Steam launch option), everything we print
# would vanish — so keep a copy of the last such run in a file you can read
# afterwards. Still passes everything through to the original stderr too, so
# pipes like `hd2up 2>&1 | less` keep working.
LOG_FILE="$H2MM_AUTO_HOME/last-run.log"
if [ ! -t 2 ]; then
  mkdir -p "$H2MM_AUTO_HOME"
  exec 2> >(tee "$LOG_FILE" >&2)
  echo "[$(date '+%F %T')] h2mm-auto started without a terminal (e.g. a Steam launch option)" >&2
fi

# ---- Helldivers 2 theme: yellow ALL-CAPS headlines, 2-space-indented white steps --
if [ -t 2 ]; then
  HD2_YELLOW=$'\033[33m'
  HD2_WHITE=$'\033[37m'
  HD2_BOLD=$'\033[1m'
  HD2_RESET=$'\033[0m'
else
  HD2_YELLOW=""; HD2_WHITE=""; HD2_BOLD=""; HD2_RESET=""
fi

# section(): yellow, all-caps banner for headers / major phases only.
section() { printf '%s%s%s%s\n' "$HD2_BOLD" "$HD2_YELLOW" "${*^^}" "$HD2_RESET" >&2; }

# ---- small helpers -------------------------------------------------------
# log()/warn(): 2-space indented (log only), white (log only), ALL CAPS — except
# an optional middle argument, which is left exactly as given (for the one
# thing that shouldn't get shouted at: actual filenames / command names).
# usage: log "prefix text" ["raw middle, e.g. a filename"] ["suffix text"]
log()  { local a="${1^^}" b="${2:-}" c="${3:-}"; printf '%s  %s%s%s%s\n' "$HD2_WHITE" "$a" "$b" "${c^^}" "$HD2_RESET" >&2; }
warn() { local a="${1^^}" b="${2:-}" c="${3:-}"; echo "!!  ${a}${b}${c^^}" >&2; }
die()  { warn "$1" "${2:-}" "${3:-}"; exit 1; }

# notify_update(): same style as log(), for the one spot that needs two raw
# (not all-capsed) tokens instead of log()'s one — the old and new version
# strings either side of the arrow.
notify_update() { # <old version string> <new version string>
  printf '%s  %s%s%s%s%s\n' "$HD2_WHITE" "UPDATE ACQUIRED: " "$1" " -> " "$2" "$HD2_RESET" >&2
}

# vlog()/debug(): plain, untouched by the theme/caps on purpose — these are
# diagnostic output, not part of the normal run's narration. vlog needs
# --verbose (or --debug, which implies it); debug needs --debug.
vlog()  { [ "$VERBOSE" -eq 1 ] && printf '[verbose] %s\n' "$*" >&2; return 0; }
debug() { [ "$DEBUG"   -eq 1 ] && printf '[debug] %s\n' "$*" >&2; return 0; }

h2mm_run() { # <h2mm_bin> <args...> -> runs h2mm quietly (except on FIRST_RUN).
  # h2mm logs almost everything (per-file "Removing ...", "Mod file ...
  # installed at ...", variant listings, prompts, ...) to stderr regardless
  # of severity, so on every run after the first we swallow it and only
  # print it back out if the command actually failed, with stdin fed from
  # /dev/null so an interactive prompt (e.g. "install all variants?") gets
  # the same default as pressing Enter, instead of the script hanging on it.
  local bin="$1"; shift
  debug "running: $bin $*"
  if [ "$FIRST_RUN" -eq 1 ]; then
    # first run ever: let h2mm talk to the real terminal and let the user
    # answer anything it asks, instead of guessing on their behalf.
    "$bin" "$@"
    return $?
  fi
  if [ "$DEBUG" -eq 1 ]; then
    # --debug wants to see everything h2mm itself prints, not just failures.
    "$bin" "$@" </dev/null
    return $?
  fi
  local out status=0
  out="$("$bin" "$@" </dev/null 2>&1)" || status=$?
  [ "$status" -ne 0 ] && printf '%s\n' "$out" >&2
  return "$status"
}

github_latest_asset() { # <owner/repo> <name-regex> [regex-flags] -> url, or empty if none matched
  local repo="$1" pat="$2" flags="${3:-}" api_url response url
  api_url="https://api.github.com/repos/$repo/releases/latest"
  vlog "checking latest release: $repo"
  debug "GET $api_url"
  if ! response="$(curl -fsSL "$api_url")"; then
    debug "curl failed fetching $api_url (rate-limited by GitHub? no releases? network down?)"
    return 0
  fi
  url="$(jq -r --arg pat "$pat" --arg flags "$flags" \
    '[.assets[] | select(.name | test($pat; $flags))][0].browser_download_url // empty' \
    <<< "$response")"
  if [ -z "$url" ]; then
    debug "no asset in $repo matched /$pat/$flags — assets in that release: $(jq -r '[.assets[].name] | join(", ")' <<< "$response" 2>/dev/null)"
  else
    vlog "matched: $(basename "$url")"
  fi
  echo "$url"
}

download() { # <url> <dest_dir> -> saved file path
  local url="$1" dir="$2" file
  [ -n "$url" ] || { warn "no matching supply drop located"; return 1; }
  mkdir -p "$dir"
  file="$dir/$(basename "$url")"
  log "acquiring asset: " "$(basename "$url")"
  vlog "GET $url -> $file"
  # `|| return 1` matters: this runs inside $(...) where bash switches
  # `set -e` off, so without it a failed download would carry on and hand
  # back the path of a file that was never saved.
  curl -fsSL "$url" -o "$file" || { warn "download failed: " "$(basename "$url")"; return 1; }
  echo "$file"
}

# ---- the actual steps -----------------------------------------------------
ensure_dependencies() {
  local missing=()
  for cmd in "${DEPS[@]}"; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
  [ ${#missing[@]} -eq 0 ] && return 0

  if command -v nix-shell >/dev/null 2>&1; then
    log "calling in stratagem: " "${missing[*]}"
    exec nix-shell -p "${missing[@]}" --run "curl -fsSL '$SELF_URL' | bash"
  fi

  die "missing stratagems: " "${missing[*]}" " — resupply manually and redeploy (see README)"
}

fetch_h2mm() {
  log "establishing uplink to h2mm-cli command"
  mkdir -p "$BIN_DIR"
  # download beside the real file first, so a failed/partial download can
  # never replace a working h2mm. (`|| return 1` for the same reason as in
  # download(): this runs inside $(...), where `set -e` is off.)
  curl -fsSL "$H2MM_URL" -o "$H2MM_BIN.new" || { rm -f "$H2MM_BIN.new"; warn "uplink to h2mm-cli failed"; return 1; }
  chmod +x "$H2MM_BIN.new"
  mv -f "$H2MM_BIN.new" "$H2MM_BIN"
  echo "$H2MM_BIN"
}

mod_entry_in_listing() { # <h2mm list output> <mod name> -> "<index>:<full label>", or nothing if not installed
  local listing="$1" name="$2" line
  line="$(grep -F -- "$name" <<< "$listing" | head -n1)"
  [ -n "$line" ] || return 0
  # the label is just the word starting at the mod name, up to the next
  # whitespace — h2mm pads its list lines with trailing spaces, which would
  # otherwise make "same version" look like "different version".
  printf '%s:%s\n' "$(grep -oE '[0-9]+' <<< "$line" | head -n1)" "$(grep -oE "${name}[^[:space:]]*" <<< "$line" | head -n1)"
}

scan_installed_mods() { # <h2mm_bin> -> READ-ONLY: fills LOADER_INDEX/MEGAPACK_INDEX and PREV_*_VERSION
  local bin="$1" listing
  # On a brand-new machine, h2mm doesn't know where Helldivers 2 is installed
  # yet, and THIS is the very first h2mm command we ever run — so it's the
  # one that triggers h2mm's one-time "found it here, is that correct? (Y/n)"
  # setup prompt (or, if auto-detection can't find it at all, a manual
  # "enter the path" prompt). On FIRST_RUN we let that reach the real
  # terminal so the user can actually answer it (stdin inherited, stderr
  # not discarded). Every run after the first keeps stdin /dev/null and
  # stderr discarded, so an empty answer (same as pressing Enter, which h2mm
  # treats as "yes") just confirms whatever it already knows, instead of
  # hanging on a prompt that no one can see.
  if [ "$FIRST_RUN" -eq 1 ]; then
    listing="$("$bin" list)" || die "recon sweep failed, nothing was touched"
  else
    listing="$("$bin" list </dev/null 2>/dev/null)" || die "recon sweep failed, nothing was touched"
  fi

  local loader_entry megapack_entry
  loader_entry="$(mod_entry_in_listing "$listing" "$LOADER_NAME")"
  megapack_entry="$(mod_entry_in_listing "$listing" "$MEGAPACK_NAME")"
  LOADER_INDEX="${loader_entry%%:*}"
  MEGAPACK_INDEX="${megapack_entry%%:*}"
  PREV_LOADER_VERSION="${loader_entry#*:}"
  PREV_MEGAPACK_VERSION="${megapack_entry#*:}"
}

purge_previous_mods() { # <h2mm_bin> -> removes whatever scan_installed_mods() found
  local bin="$1"
  if [ -z "$LOADER_INDEX" ] && [ -z "$MEGAPACK_INDEX" ]; then
    log "no legacy loadout detected — front is clear"
    return 0
  fi

  # highest index first: uninstalling one reindexes the ones above it, so
  # working top-down keeps the remaining index still valid.
  local i
  for i in $(printf '%s\n%s\n' "$LOADER_INDEX" "$MEGAPACK_INDEX" | grep -v '^$' | sort -rn); do
    log "purging asset #$i"
    h2mm_run "$bin" uninstall -i "$i" || die "purge failed on asset #$i"
  done
}

install_mod() { # <h2mm_bin> <zip_path>
  log "deploying asset: " "$(basename "$2")"
  # after the first run (see h2mm_run), feeding an empty stdin makes the
  # "which variants?" prompt default to installing all of them, same as
  # pressing Enter. On FIRST_RUN the prompt instead reaches the real
  # terminal, so the user picks for themselves the one time it's asked.
  h2mm_run "$1" install "$2" || die "deployment failed: " "$(basename "$2")"
}

announce_updates() { # <new loader version> <new megapack version> -> notes any mod whose version changed
  if [ -n "$PREV_LOADER_VERSION" ] && [ "$PREV_LOADER_VERSION" != "$1" ]; then
    notify_update "$PREV_LOADER_VERSION" "$1"
  fi
  if [ -n "$PREV_MEGAPACK_VERSION" ] && [ "$PREV_MEGAPACK_VERSION" != "$2" ]; then
    notify_update "$PREV_MEGAPACK_VERSION" "$2"
  fi
}

mark_run_complete() {
  mkdir -p "$H2MM_AUTO_HOME"
  touch "$FIRST_RUN_MARKER"
}

# ---- entry point: the whole thing, top to bottom ---------------------------
# Order matters: look first (read-only), compare, and only if there is
# actually something newer do we download — and only once the downloads are
# safely on disk do we remove anything.
main() {
  section "DEMOCRACY DELIVERED"
  ensure_dependencies

  local h2mm loader_url megapack_url new_loader new_megapack loader megapack
  h2mm="$(fetch_h2mm)" || die "aborting — no uplink to h2mm-cli, nothing was touched"

  section "SURVEYING THE FRONT"
  scan_installed_mods "$h2mm"
  loader_url="$(github_latest_asset "$LOADER_REPO" "$LOADER_PATTERN")"
  [ -n "$loader_url" ] || die "aborting — no loader release found, nothing was touched (rerun with --debug to see why)"
  megapack_url="$(github_latest_asset "$MEGAPACK_REPO" "$MEGAPACK_PATTERN")"
  [ -n "$megapack_url" ] || die "aborting — no megapack release found, nothing was touched (rerun with --debug to see why)"
  new_loader="$(basename "$loader_url" .zip)"
  new_megapack="$(basename "$megapack_url" .zip)"

  if [ "$FORCE" -eq 0 ] && [ "$PREV_LOADER_VERSION" = "$new_loader" ] && [ "$PREV_MEGAPACK_VERSION" = "$new_megapack" ]; then
    log "already at latest: " "$new_loader, $new_megapack"
    log "nothing to do"
    mark_run_complete
    section "MISSION SUCCESS"
    return 0
  fi

  announce_updates "$new_loader" "$new_megapack"

  section "REQUISITIONING ASSETS"
  loader="$(download "$loader_url" "$DOWNLOADS")"     || die "aborting — loader download failed, nothing was touched"
  megapack="$(download "$megapack_url" "$DOWNLOADS")" || die "aborting — megapack download failed, nothing was touched"

  section "PURGING OUTDATED LOADOUT"
  purge_previous_mods "$h2mm"

  section "DEPLOYING REINFORCEMENTS"
  install_mod "$h2mm" "$loader"
  install_mod "$h2mm" "$megapack"

  # only reached on a fully successful run — so a failed first run still
  # gets to try again interactively next time.
  mark_run_complete
  section "MISSION SUCCESS"
}

main