#!/usr/bin/env bash
#
# Installs shem_audit and the runtime it needs.
#
#   ./install.sh                     # download the latest release, verify, install
#   ./install.sh --from-source       # build the escript here instead
#   ./install.sh --with-needle       # also fetch the Needle binary
#   ./install.sh --help
#
# Three rules this script keeps, because the tool is an evidence tool and an
# installer that cut corners would undercut it:
#
#   1. Nothing is installed, downloaded, or elevated without a prompt first.
#      `--yes` answers the prompts in advance; it does not add steps.
#   2. Every download is checked against a digest before it is made executable.
#   3. The install is proved by recording and verifying a real chain, not by
#      checking that a file landed on disk.
set -euo pipefail

REPO="thephilip/shem-spolia"
PREFIX="${HOME}/.local/bin"
VERSION="latest"
FROM_SOURCE=0
WITH_NEEDLE=0
ASSUME_YES=0
# The escript is bytecode built on OTP 27. An older runtime loads it and fails
# on the beam version, so check rather than let it fail at first use.
MIN_OTP=27
# Overridable so an existing install elsewhere can be pointed at rather than
# shadowed by a second copy.
NEEDLE_DIR="${NEEDLE_DIR:-${HOME}/.local/share/needle}"
NEEDLE_URL="https://huggingface.co/Cactus-Compute/needle2/resolve/main/linux-x86_64/needle"

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --prefix DIR     where shem_audit goes (default: ~/.local/bin)
  --version TAG    release tag to install (default: latest)
  --from-source    build with mix instead of downloading a release
  --with-needle    also install the Needle model binary (linux x86_64)
  --yes            answer every prompt with yes
  -h, --help       this text
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)      PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
    --version)     VERSION="${2:?--version needs a tag}"; shift 2 ;;
    --from-source) FROM_SOURCE=1; shift ;;
    --with-needle) WITH_NEEDLE=1; shift ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown option: $1 (try --help)" ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# Prompts read from the terminal, not stdin: this script is also run as
# `curl ... | bash`, where stdin is the script itself and `read` would eat it.
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && { say "$1 ... yes (--yes)"; return 0; }
  [ -r /dev/tty ] || die "$1 — no terminal to ask on; re-run with --yes to accept in advance"
  printf '%s [y/N] ' "$1" > /dev/tty
  local reply=""
  read -r reply < /dev/tty || true
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

fetch() { # fetch URL DEST
  if   have curl; then curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1" || die "download failed ($1)"
  elif have wget; then wget -qO "$2" "$1" || die "download failed ($1)"
  else die "need curl or wget to download anything"
  fi
}

sha256_of() {
  if   have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  elif have shasum;    then shasum -a 256 "$1" | cut -d' ' -f1
  else die "need sha256sum or shasum to check what was downloaded"
  fi
}

# The command that would install a package here. Empty means we do not know
# this machine's package manager and should say so instead of guessing.
pkg_install_cmd() { # pkg_install_cmd erlang|elixir
  local what="$1"
  if have mise; then
    case "$what" in
      erlang) printf 'mise use -g erlang@27' ;;
      elixir) printf 'mise use -g erlang@27 elixir@1.17' ;;
    esac
    return
  fi
  case "$what:$(
    for m in pacman apt-get dnf zypper apk brew; do have "$m" && { printf '%s' "$m"; break; }; done
  )" in
    erlang:pacman)  printf 'sudo pacman -S --needed erlang' ;;
    elixir:pacman)  printf 'sudo pacman -S --needed elixir' ;;
    erlang:apt-get) printf 'sudo apt-get install -y erlang-nox' ;;
    elixir:apt-get) printf 'sudo apt-get install -y elixir' ;;
    erlang:dnf)     printf 'sudo dnf install -y erlang' ;;
    elixir:dnf)     printf 'sudo dnf install -y elixir' ;;
    erlang:zypper)  printf 'sudo zypper install -y erlang' ;;
    elixir:zypper)  printf 'sudo zypper install -y elixir' ;;
    erlang:apk)     printf 'sudo apk add erlang' ;;
    elixir:apk)     printf 'sudo apk add elixir' ;;
    erlang:brew)    printf 'brew install erlang' ;;
    elixir:brew)    printf 'brew install elixir' ;;
    *)              printf '' ;;
  esac
}

ensure_tool() { # ensure_tool erlang|elixir probe-binary
  local what="$1" probe="$2" cmd
  have "$probe" && return 0
  cmd="$(pkg_install_cmd "$what")"
  [ -n "$cmd" ] || die "$what is missing and this machine's package manager is not one I know. Install $what, then re-run."
  say "$what is missing. Proposed: $cmd"
  confirm "run it?" || die "$what is required. Install it and re-run."
  # Unquoted on purpose: these are the fixed strings above, not user input.
  # shellcheck disable=SC2086
  eval $cmd
  have "$probe" || die "$cmd finished but $probe is still not on PATH (a new shell may be needed)"
}

check_otp() {
  local otp
  otp="$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || true)"
  [ -n "$otp" ] || { warn "could not read the OTP release; continuing"; return 0; }
  if [ "$otp" -lt "$MIN_OTP" ] 2>/dev/null; then
    die "OTP $otp is too old — the escript is bytecode built on OTP $MIN_OTP. Upgrade Erlang and re-run."
  fi
  say "Erlang runtime: OTP $otp"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

install_from_release() {
  local tag="$VERSION" base
  if [ "$tag" = "latest" ]; then
    fetch "https://api.github.com/repos/${REPO}/releases/latest" "$TMP/rel.json"
    tag="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$TMP/rel.json" | head -1)"
    [ -n "$tag" ] || die "could not read the latest release tag from the GitHub API"
  fi
  base="https://github.com/${REPO}/releases/download/${tag}"
  say "Release: $tag"

  confirm "download shem_audit and its digest from ${base}?" || die "declined"
  fetch "${base}/shem_audit"        "$TMP/shem_audit"
  fetch "${base}/shem_audit.sha256" "$TMP/shem_audit.sha256"

  local want got
  want="$(cut -d' ' -f1 < "$TMP/shem_audit.sha256")"
  got="$(sha256_of "$TMP/shem_audit")"
  [ "$want" = "$got" ] || die "digest mismatch: expected $want, got $got. Nothing was installed."
  say "sha256 $got matches the published digest"
  # Said plainly because the tool's whole subject is what a check does and does
  # not prove: the digest ships from the same release, so this catches a
  # corrupted or truncated download, not a compromised release. CI computes it
  # from the artifact the clean-room job just proved, and the workflow that did
  # so is readable at .github/workflows/build.yml.
  say "(the digest is published alongside the binary, so it proves transport, not provenance)"
}

build_from_source() {
  [ -f mix.exs ] || die "--from-source needs to run inside a checkout of the repo"
  ensure_tool elixir mix
  confirm "run mix deps.get and build the escript here?" || die "declined"
  mix deps.get
  MIX_ENV=prod mix escript.build
  cp shem_audit "$TMP/shem_audit"
}

install_needle() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  if [ "$os" != "Linux" ] || [ "$arch" != "x86_64" ]; then
    warn "skipping Needle: the only build path this script knows is linux-x86_64, and this is ${os}-${arch}."
    warn "see https://cactuscompute.com/needle for other builds, then export NEEDLE_PATH yourself."
    return 0
  fi

  local target="$NEEDLE_DIR/needle" recorded="$NEEDLE_DIR/needle.sha256" have_digest=""
  if [ -f "$target" ]; then
    have_digest="$(sha256_of "$target")"
    say "Needle is already installed at $target (sha256 $have_digest)"
    confirm "check upstream and replace it if it differs?" || { say "kept the existing Needle binary"; return 0; }
  fi

  confirm "download the Needle binary (~14 MB) from huggingface.co?" || { say "skipped Needle"; return 0; }
  mkdir -p "$NEEDLE_DIR"
  fetch "$NEEDLE_URL" "$TMP/needle"
  local got; got="$(sha256_of "$TMP/needle")"

  # Upstream publishes no digest for this file, so there is nothing to check it
  # against on a first install. Trust on first use: record what arrived, and
  # compare on every later run so a changed binary is visible rather than
  # silently swapped underneath an audited agent.
  local want=""
  [ -f "$recorded" ] && want="$(cut -d' ' -f1 < "$recorded")"
  [ -z "$want" ] && want="$have_digest"

  if [ -n "$want" ]; then
    if [ "$want" = "$got" ]; then
      say "Needle is already up to date (sha256 $got)"
      printf '%s  needle\n' "$got" > "$recorded"
      return 0
    fi
    warn "the Needle binary upstream differs from the one installed here:"
    warn "  installed $want"
    warn "  upstream  $got"
    warn "upstream publishes no digest, so this script cannot tell a release from a swap."
    confirm "replace the installed binary?" || { say "kept the existing Needle binary"; return 0; }
  fi

  install -m 0755 "$TMP/needle" "$target"
  printf '%s  needle\n' "$got" > "$recorded"
  say "Needle installed: $target (sha256 $got, recorded in $recorded)"
  say "Add to your shell profile:  export NEEDLE_PATH=$target"
}

# Proof, not assumption: record one event into a throwaway log and verify the
# chain over it. This exercises the escript, the Erlang runtime under it, the
# DETS write path, and SHEM_SPOLIA_EVENT_LOG_PATH in one go.
prove_install() { # prove_install BINARY
  local bin="$1" out
  export SHEM_SPOLIA_EVENT_LOG_PATH="$TMP/events"
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"true"}}' \
    | "$bin" record --session install_check --quiet
  out="$("$bin" verify install_check)"
  case "$out" in
    VERIFIED*) say "post-install check: $out" ;;
    *)         die "post-install check failed: $out" ;;
  esac
  unset SHEM_SPOLIA_EVENT_LOG_PATH
}

step "Runtime"
ensure_tool erlang escript
check_otp

step "shem_audit"
if [ "$FROM_SOURCE" -eq 1 ]; then build_from_source; else install_from_release; fi

confirm "install shem_audit to ${PREFIX}?" || die "declined"
mkdir -p "$PREFIX"
install -m 0755 "$TMP/shem_audit" "$PREFIX/shem_audit"
say "installed: $PREFIX/shem_audit"

step "Checking the install"
prove_install "$PREFIX/shem_audit"

if [ "$WITH_NEEDLE" -eq 1 ]; then
  step "Needle"
  install_needle
fi

step "Done"
case ":$PATH:" in
  *":$PREFIX:"*) : ;;
  *) say "$PREFIX is not on your PATH. Add to your shell profile:"
     say "  export PATH=\"$PREFIX:\$PATH\"" ;;
esac
have python3 || say "python3 is not installed. It is not needed to run shem_audit, only to verify a bundle with verify.py."
say "Try:  shem_audit help"
say "Record an agent: see the hook snippet in README.md — the client hands over the record, so nothing here configures your agent for you."
