#!/usr/bin/env bash

# Source this to pin cardano tooling to the leios version.
#
#   source scripts/playground/leios-pin.sh      # pin
#   source scripts/playground/leios-pin.sh -u   # unpin
#
# Run from the repo root, the pin is read from flake.lock.
#
# Wrapped in a function so the locals do not leak into the shell. Only PATH and
# LEIOS_PATH_BACKUP are meant to survive. Never call exit here, it would kill
# the caller's shell, and never set -e or set -u, they leak too.

_leios_pin() {
  local bindir="$HOME/.local/bin"

  # A direnv reload rebuilds PATH from the devShell and drops the prepend, but
  # LEIOS_PATH_BACKUP is exported so it survives. That leaves the pin half
  # applied: the symlinks are still valid, PATH no longer points at them, and
  # the saved backup is from the previous shell instance so it is stale. Every
  # check that looks right still looks right, which is what makes it nasty.
  local pinned=false desynced=false
  if [ -n "$LEIOS_PATH_BACKUP" ]; then
    case ":$PATH:" in
      *":$bindir:"*) pinned=true ;;
      *) desynced=true ;;
    esac
  fi

  if [ "$1" = "-u" ]; then
    if [ "$pinned" = true ]; then
      export PATH="$LEIOS_PATH_BACKUP"
      unset LEIOS_PATH_BACKUP
      echo "leios pin removed"

      # The symlinks outlive the pin. If bindir is on PATH from the profile
      # they still shadow the system tools, which looks like a failed unpin.
      case ":$PATH:" in
        *":$bindir:"*)
          echo "note: $bindir is still on PATH, its leios symlinks still shadow system tools"
          echo "      cardano-cli now resolves to: $(command -v cardano-cli 2>/dev/null || echo none)"
          ;;
      esac
    elif [ "$desynced" = true ]; then
      # Do not restore the backup, it predates the reload that dropped the pin.
      # PATH is already the reload's own, so just drop the stale record.
      unset LEIOS_PATH_BACKUP
      echo "leios pin was already off PATH, discarded the stale backup"
      echo "cardano-cli now resolves to: $(command -v cardano-cli 2>/dev/null || echo none)"
    else
      echo "leios pin not active, nothing to do"
    fi
    return 0
  fi

  # Re-pinning is a no-op otherwise, so a flake.lock bump would be ignored.
  if [ "$pinned" = true ]; then
    echo "leios pin already active, source with -u first to re-pin"
    return 0
  fi

  # Desynced falls through to a full re-pin. The builds are cached so this is
  # cheap when nothing moved, and it picks up a flake.lock bump. The backup is
  # recaptured below from the current PATH, not the stale one.
  if [ "$desynced" = true ]; then
    echo "leios pin was dropped from PATH, likely a direnv reload, re-applying"
  fi

  if [ ! -f flake.lock ]; then
    echo "leios pin: no flake.lock in $PWD, run from the repo root" >&2
    return 1
  fi

  local pin
  pin=$(jq -r '.nodes[.nodes."cardano-node-leios".inputs."cardano-node-leios"].locked
               | "github:\(.owner)/\(.repo)/\(.rev)"' flake.lock) || {
    echo "leios pin: could not read the pin from flake.lock" >&2
    return 1
  }
  case "$pin" in
    ""|*null*)
      echo "leios pin: no cardano-node-leios input found in flake.lock" >&2
      return 1
      ;;
  esac
  echo "leios pin: $pin"

  # Binary name paired with its flake attr.
  local specs=(
    "cardano-cli:cardano-cli"
    "cardano-node:cardano-node"
    "db-analyser:db-analyser"
    "db-synthesizer:db-synthesizer"
    "db-truncater:db-truncater"
    "db-immutaliser:project.x86_64-linux.hsPkgs.ouroboros-consensus.components.exes.db-immutaliser"
  )

  # Build everything before linking anything. A failed build used to yield an
  # empty path and a symlink to /bin/<tool>, which then looked like a success.
  local spec name attr out
  local built=()
  for spec in "${specs[@]}"; do
    name="${spec%%:*}"
    attr="${spec#*:}"
    out=$(nix build -Lv "$pin#$attr" --no-link --print-out-paths) || {
      echo "leios pin: build failed for $attr, PATH unchanged" >&2
      return 1
    }
    if [ -z "$out" ] || [ ! -x "$out/bin/$name" ]; then
      echo "leios pin: $attr built but $out/bin/$name is missing, PATH unchanged" >&2
      return 1
    fi
    built+=("$name:$out/bin/$name")
  done

  mkdir -p "$bindir" || return 1
  for spec in "${built[@]}"; do
    ln -sf "${spec#*:}" "$bindir/${spec%%:*}" || return 1
  done

  export LEIOS_PATH_BACKUP="$PATH"
  export PATH="$bindir:$PATH"
  echo "leios pin applied, ${#built[@]} tools linked into $bindir"
  echo "cardano-cli now resolves to: $(command -v cardano-cli 2>/dev/null || echo none)"
}

# Propagate the result. A bare `unset -f` here would mask it and always report
# success. The exit fallbacks only fire if this file is run instead of sourced.
if _leios_pin "$@"; then
  unset -f _leios_pin
  return 0 2>/dev/null || exit 0
else
  unset -f _leios_pin
  return 1 2>/dev/null || exit 1
fi
