#!/usr/bin/env bash
# h2mm-auto: remove old CowboyBingus mods, install the latest ones.
# No subcommands needed — just run it. Optional: --verbose, --debug (see README).
set -euo pipefail

VERBOSE=0
DEBUG=0
for _arg in "$@"; do
  case "$_arg" in
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

BIN_DIR="${H2MM_AUTO_HOME:-$HOME/.local/share/h2mm-auto}/bin"
H2MM_BIN="$BIN_DIR/h2mm"
DOWNLOADS="${H2MM_AUTO_DOWNLOADS:-$HOME/Downloads}"
DEPS=(curl jq unzip)

# names we already know, straight from the release filenames — used to find
# them again in `h2mm list` output (see mod_index_in_listing below).
LOADER_NAME="Bingus-Shared-Loader"
MEGAPACK_NAME="Vanilla-Plus-Megapack"

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

# vlog()/debug(): plain, untouched by the theme/caps on purpose — these are
# diagnostic output, not part of the normal run's narration. vlog needs
# --verbose (or --debug, which implies it); debug needs --debug.
vlog()  { [ "$VERBOSE" -eq 1 ] && printf '[verbose] %s\n' "$*" >&2; return 0; }
debug() { [ "$DEBUG"   -eq 1 ] && printf '[debug] %s\n' "$*" >&2; return 0; }

h2mm_run() { # <h2mm_bin> <args...> -> runs h2mm quietly.
  # h2mm logs almost everything (per-file "Removing ...", "Mod file ...
  # installed at ...", variant listings, prompts, ...) to stderr regardless
  # of severity, so we swallow it and only print it back out if the command
  # actually failed. Stdin is always /dev/null so an interactive prompt
  # (e.g. "install all variants?") gets the same default as pressing Enter,
  # instead of the script hanging on it.
  local bin="$1"; shift
  debug "running: $bin $*"
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
  curl -fsSL "$url" -o "$file"
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
  curl -fsSL "$H2MM_URL" -o "$H2MM_BIN"
  chmod +x "$H2MM_BIN"
  echo "$H2MM_BIN"
}

fetch_loader()   { download "$(github_latest_asset "$LOADER_REPO" "$LOADER_PATTERN")" "$DOWNLOADS"; }
fetch_megapack() { download "$(github_latest_asset "$MEGAPACK_REPO" "$MEGAPACK_PATTERN")" "$DOWNLOADS"; }

mod_index_in_listing() { # <h2mm list output> <mod name> -> its index number, or nothing if not installed
  local listing="$1" name="$2" line
  line="$(grep -F -- "$name" <<< "$listing" | head -n1)"
  [ -n "$line" ] || return 0
  grep -oE '[0-9]+' <<< "$line" | head -n1
}

remove_previous_mods() { # <h2mm_bin>
  local bin="$1" listing
  # On a brand-new machine, h2mm doesn't know where Helldivers 2 is installed
  # yet, and THIS is the very first h2mm command we ever run — so it's the
  # one that triggers h2mm's one-time "found it here, is that correct? (Y/n)"
  # setup prompt. Stdin has to be /dev/null here too (same reasoning as
  # h2mm_run), or that prompt silently blocks forever on a terminal that
  # never shows it (its text goes out over stderr, which we discard below).
  # An empty answer is what h2mm treats as "yes, that one" — same default as
  # pressing Enter — so this just auto-accepts whatever it auto-detected
  # instead of hanging.
  listing="$("$bin" list </dev/null 2>/dev/null)" || { warn "recon sweep failed, skipping purge"; return 0; }

  local loader_index megapack_index
  loader_index="$(mod_index_in_listing "$listing" "$LOADER_NAME")"
  megapack_index="$(mod_index_in_listing "$listing" "$MEGAPACK_NAME")"

  if [ -z "$loader_index" ] && [ -z "$megapack_index" ]; then
    log "no legacy loadout detected — front is clear"
    return 0
  fi

  # highest index first: uninstalling one reindexes the ones above it, so
  # working top-down keeps the remaining index still valid.
  local i
  for i in $(printf '%s\n%s\n' "$loader_index" "$megapack_index" | grep -v '^$' | sort -rn); do
    log "purging asset #$i"
    h2mm_run "$bin" uninstall -i "$i" || die "purge failed on asset #$i"
  done
}

install_mod() { # <h2mm_bin> <zip_path>
  log "deploying asset: " "$(basename "$2")"
  # feeding an empty stdin (see h2mm_run) makes the "which variants?" prompt
  # default to installing all of them, same as pressing Enter.
  h2mm_run "$1" install "$2" || die "deployment failed: " "$(basename "$2")"
}

# ---- entry point: the whole thing, top to bottom ---------------------------
main() {
  section "DEMOCRACY DELIVERED"
  ensure_dependencies

  local h2mm; h2mm="$(fetch_h2mm)"

  section "PURGING OUTDATED LOADOUT"
  remove_previous_mods "$h2mm"

  section "REQUISITIONING ASSETS"
  local loader megapack
  loader="$(fetch_loader)"     || die "aborting — no loader asset found (rerun with --debug to see why)"
  megapack="$(fetch_megapack)" || die "aborting — no megapack asset found (rerun with --debug to see why)"
  install_mod "$h2mm" "$loader"
  install_mod "$h2mm" "$megapack"

  section "MISSION SUCCESS"
}

main