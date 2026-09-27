#!/usr/bin/env bash
# h2mm-auto: remove old CowboyBingus mods, install the latest ones.
# No subcommands, no flags — just run it.
set -euo pipefail

# ---- config ------------------------------------------------------------
H2MM_REPO="v4n00/h2mm-cli"
H2MM_URL="https://raw.githubusercontent.com/${H2MM_REPO}/master/h2mm"
SELF_URL="https://raw.githubusercontent.com/grenudi/h2mm-auto/main/h2mm-auto.sh"

LOADER_REPO="CowboyBingus/BingusSharedLoader"
LOADER_PATTERN='\.zip$'

MEGAPACK_REPO="CowboyBingus/VanillaPlusMegapack"
MEGAPACK_PATTERN='Rows.*\.zip$'
MEGAPACK_FLAGS='i'

BIN_DIR="${H2MM_AUTO_HOME:-$HOME/.local/share/h2mm-auto}/bin"
H2MM_BIN="$BIN_DIR/h2mm"
DOWNLOADS="${H2MM_AUTO_DOWNLOADS:-$HOME/Downloads}"
DEPS=(curl jq unzip)

# ---- small helpers -------------------------------------------------------
log()  { echo "==> $*" >&2; }
warn() { echo "!!  $*" >&2; }
die()  { warn "$*"; exit 1; }

github_latest_asset() { # <owner/repo> <name-regex> [regex-flags] -> url
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" |
    jq -r --arg pat "$2" --arg flags "${3:-}" \
      '[.assets[] | select(.name | test($pat; $flags))][0].browser_download_url // empty'
}

download() { # <url> <dest_dir> -> saved file path
  local url="$1" dir="$2" file
  [ -n "$url" ] || { warn "no matching release asset found"; return 1; }
  mkdir -p "$dir"
  file="$dir/$(basename "$url")"
  log "downloading $(basename "$url")"
  curl -fsSL "$url" -o "$file"
  echo "$file"
}

# ---- the actual steps -----------------------------------------------------
ensure_dependencies() {
  local missing=()
  for cmd in "${DEPS[@]}"; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
  [ ${#missing[@]} -eq 0 ] && return 0

  if command -v nix-shell >/dev/null 2>&1; then
    log "re-entering nix-shell with: ${missing[*]}"
    exec nix-shell -p "${missing[@]}" --run "curl -fsSL '$SELF_URL' | bash"
  fi

  die "missing dependencies: ${missing[*]} — install them and re-run (see README)"
}

fetch_h2mm() {
  log "fetching latest h2mm-cli"
  mkdir -p "$BIN_DIR"
  curl -fsSL "$H2MM_URL" -o "$H2MM_BIN"
  chmod +x "$H2MM_BIN"
  echo "$H2MM_BIN"
}

fetch_loader()   { download "$(github_latest_asset "$LOADER_REPO" "$LOADER_PATTERN")" "$DOWNLOADS"; }
fetch_megapack() { download "$(github_latest_asset "$MEGAPACK_REPO" "$MEGAPACK_PATTERN" "$MEGAPACK_FLAGS")" "$DOWNLOADS"; }

remove_previous_mods() { # <h2mm_bin>
  local bin="$1" indices
  "$bin" list >/dev/null 2>&1 || { warn "'h2mm list' failed, skipping cleanup"; return 0; }

  echo "h2mm list: \n $("$bin" list)"
  indices="$("$bin" list | awk -F'[) ]+' '/[Bb]ingus|Vanilla Plus/{print $1}')"
  [ -n "$indices" ] || { log "no previous Bingus/Vanilla Plus mods found"; return 0; }

  for i in $(sort -rn <<< "$indices"); do
    log "removing mod #$i"
    "$bin" uninstall --index "$i"
  done
}

install_mod() { # <h2mm_bin> <zip_path>
  log "installing $(basename "$2")"
  "$1" install "$2"
}

# ---- entry point: the whole thing, top to bottom ---------------------------
main() {
  ensure_dependencies

  local h2mm; h2mm="$(fetch_h2mm)"
  remove_previous_mods "$h2mm"

  local loader;   loader="$(fetch_loader)"
  local megapack; megapack="$(fetch_megapack)"
  install_mod "$h2mm" "$loader"
  install_mod "$h2mm" "$megapack"

  log "done"
}

main
