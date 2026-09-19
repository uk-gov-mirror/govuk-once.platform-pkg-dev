#!/bin/sh
# Bootstrap a Connect package.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/govuk-once/platform-pkg-dev/main/start.sh)" -- --dir connect-foo --name connect-foo --team identity --assumerole connect-development-admin
#
# --dir names a folder to create and work in. Without it, an empty directory is
# used as-is and a non-empty one prompts, so piping this into the wrong place
# cannot quietly scatter files over an existing project.
#
# `dev init` cannot be the first step: it lives in platform-pkg-dev, which is
# not installed until a package.json exists that depends on it. This writes a
# minimal manifest, installs, and then hands over to `dev init`, which
# overwrites that manifest with the real one.
#
# Versions here are checked against platform-pkg-dev's versions.json by its test suite,
# so this file cannot drift from the pins.
set -eu

# Overridable from the environment so the script can be exercised against a
# local checkout before platform-pkg-dev is published. The defaults are the real pins,
# and platform-pkg-dev's test suite checks them against versions.json.
NODE_MAJOR=${NODE_MAJOR:-24}
PNPM=${PNPM:-pnpm@12.4.1}
PKG_DEV=${PKG_DEV:-^0.0.5}

fail() { echo "platform-pkg-dev: $1" >&2; exit 1; }

# `[ -r /dev/tty ]` is not enough: the device can exist but be unusable, for
# example under CI or a detached shell, where writing to it aborts the script.
has_tty() { { true > /dev/tty; } 2>/dev/null; }

# `start.sh --local` resolves platform-pkg-dev from a sibling checkout instead of
# the registry.  Strip the keyword before normal arg parsing begins.
if [ "${1:-}" = "--local" ]; then
  PKG_DEV="link:../platform-pkg-dev"
  shift
fi

# Pull --dir and --assumerole out of the arguments; everything else is
# forwarded to `dev init`.
# The marker keeps quoting intact while rebuilding "$@" in POSIX sh.
DIR=""
ASSUME_ROLE=""
set -- "$@" "--end-of-args--"
while [ "$1" != "--end-of-args--" ]; do
  case "$1" in
    --dir) shift; [ "$1" != "--end-of-args--" ] || fail "--dir needs a folder name."; DIR="$1" ;;
    --dir=*) DIR="${1#--dir=}" ;;
    --assumerole) shift; [ "$1" != "--end-of-args--" ] || fail "--assumerole needs a role name."; ASSUME_ROLE="$1" ;;
    --assumerole=*) ASSUME_ROLE="${1#--assumerole=}" ;;
    *) set -- "$@" "$1" ;;
  esac
  shift
done
shift

if [ -z "$DIR" ]; then
  # .git alone still counts as empty: `git init` before bootstrapping is normal.
  if [ -z "$(ls -A . 2>/dev/null | grep -v '^\.git$' || true)" ]; then
    DIR="."
  elif has_tty; then
    echo "platform-pkg-dev: $(pwd) is not empty." >&2
    printf 'Folder to create, or press enter to use this directory: ' > /dev/tty
    read -r DIR < /dev/tty
    [ -n "$DIR" ] || DIR="."
  else
    fail "$(pwd) is not empty, and there is no terminal to ask.
  Pass --dir <folder>, or run this in an empty directory."
  fi
fi

if [ "$DIR" != "." ]; then
  [ -e "$DIR" ] && [ ! -d "$DIR" ] && fail "$DIR exists and is not a directory."
  mkdir -p "$DIR"
  cd "$DIR"
  echo "platform-pkg-dev: working in $(pwd)"
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "platform-pkg-dev: initialising git repository"
  git init
fi

command -v node >/dev/null 2>&1 || fail "node is not installed. Install Node ${NODE_MAJOR}, then re-run."

major=$(node -p 'process.versions.node.split(".")[0]')
[ "$major" -ge "$NODE_MAJOR" ] || fail "Node ${NODE_MAJOR}+ required, found $(node -v)."

if command -v corepack >/dev/null 2>&1; then
  corepack enable pnpm >/dev/null 2>&1 || true
fi

command -v pnpm >/dev/null 2>&1 || fail "pnpm is not available. Run 'corepack enable pnpm', then re-run."

want=${PNPM#pnpm@}
have=$(pnpm --version 2>/dev/null || echo unknown)
if [ "$have" != "$want" ]; then
  fail "pnpm ${want} is pinned but ${have} is running.
  corepack prepare ${PNPM} --activate"
fi

# When --assumerole is given, assume the GDS role and authorise CodeArtifact
# before writing any files.  platform-pkg-dev itself lives on CodeArtifact, so
# nothing can proceed without a valid token.  The CLI is not installed yet, so
# this calls gds-cli and the AWS CLI directly — the same commands the CLI wraps.
if [ -n "$ASSUME_ROLE" ]; then
  command -v gds-cli >/dev/null 2>&1 || fail "gds-cli is not on PATH. Install it: https://github.com/alphagov/gds-cli"
  command -v aws >/dev/null 2>&1 || fail "aws is not on PATH. Install the AWS CLI: https://aws.amazon.com/cli/"

  echo "platform-pkg-dev: assuming role $ASSUME_ROLE"
  CREDS=$(gds-cli aws "$ASSUME_ROLE" -e) || fail "Could not assume role $ASSUME_ROLE. Are you on the VPN?"

  # Parse credentials safely — no eval.
  # Strip optional `export ` prefix, split on first `=`, then strip surrounding
  # quotes (single or double) from the value.  Mirrors the Node parseCredentials
  # function in src/lib/gds.ts.
  extract_var() {
    echo "$CREDS" | sed -n "s/^\\(export \\)\\{0,1\\}$1=//p" | sed "s/;$//;s/^['\"]//;s/['\"]$//"
  }

  export AWS_ACCESS_KEY_ID="$(extract_var AWS_ACCESS_KEY_ID)"
  export AWS_SECRET_ACCESS_KEY="$(extract_var AWS_SECRET_ACCESS_KEY)"
  export AWS_SESSION_TOKEN="$(extract_var AWS_SESSION_TOKEN)"

  [ -n "$AWS_ACCESS_KEY_ID" ] || fail "gds-cli returned no usable credentials for $ASSUME_ROLE."

  echo "platform-pkg-dev: verifying credentials"
  echo "platform-pkg-dev: AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:+(set)}" >&2
  echo "platform-pkg-dev: AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:+(set)}" >&2
  echo "platform-pkg-dev: AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN:+(set)}" >&2
  STS_OUT=$(aws sts get-caller-identity 2>&1) || fail "Credentials are not usable: $STS_OUT"

  echo "platform-pkg-dev: authorising CodeArtifact"
  aws codeartifact login \
    --tool npm \
    --namespace govuk-connect \
    --repository registry-prod-repo \
    --domain registry-prod \
    --domain-owner 904690835784 \
    --region eu-west-2 || fail "Could not authorise CodeArtifact."
fi

# corepack reads packageManager from package.json, so the manifest has to exist
# before pnpm is invoked - otherwise corepack picks its own default version and
# then refuses to switch.
if [ -f package.json ]; then
  echo "platform-pkg-dev: package.json already exists, leaving it alone."
else
  echo "platform-pkg-dev: writing a temporary package.json (dev init replaces it)"
  cat > package.json <<JSON
{
  "name": "dev-bootstrap",
  "private": true,
  "packageManager": "${PNPM}",
  "devDependencies": { "@govuk-connect/dev": "${PKG_DEV}" },
  "once": { "bootstrap": true }
}
JSON
fi

echo "platform-pkg-dev: installing (pnpm ${have})"
pnpm install || fail "pnpm install failed.
  If platform-pkg-dev is not published yet, point at a local checkout instead:
    pnpm add -D platform-pkg-dev@link:/path/to/platform-pkg-dev && pnpm dev init"

# --pkg-dev first so an explicit one from the caller still wins: the spec init
# records must match the one actually installed above, or the next install
# fetches a different platform-pkg-dev than the one that just ran.
echo "platform-pkg-dev: running dev init"
INIT_ARGS="--pkg-dev $PKG_DEV"
[ -n "$ASSUME_ROLE" ] && INIT_ARGS="$INIT_ARGS --assumerole $ASSUME_ROLE"
pnpm dev init $INIT_ARGS "$@"

# init rewrites package.json with the package's real dependency set - oxlint,
# oxfmt, the type-aware engine - so the first install only ever got platform-pkg-dev.
echo "platform-pkg-dev: installing the package's dependencies"
pnpm install

echo "platform-pkg-dev: wiring git hooks"
pnpm dev hooks install

echo 'As a shortcut to govuk-connect/dev add this to your .zshrc / .bashrc:

dev() {
  ./node_modules/.bin/dev "$@"
}
'

echo "platform-pkg-dev: done."
