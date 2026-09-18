#!/usr/bin/env bash
#
# Local mirror of .github/workflows/build.yml: builds the webvh service
# binaries (did-hosting-server, webvh-witness, did-hosting-control,
# webvh-watcher, did-hosting-daemon, did-hosting-daemon-k8s) plus the did-hosting-ui web bundle,
# and uploads each binary to Cloudflare R2. A tagged release goes to
# `<tag>-<sha>/` and `latest/`; an untagged build goes to
# `<crate-version>-<sha>/` and `main/`. `<sha>` is the upstream commit the
# build came from — the tag's commit for a release, the upstream/main tip
# otherwise — not this fork's sync commit.
#
# Required env vars (export them, or put them in <repo>/.env):
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   R2_ACCOUNT_ID
#   R2_BUCKET
#
# Usage:
#   .scripts/build-and-upload.sh                # -> main/ + <version>-<sha>/
#   .scripts/build-and-upload.sh <tag>          # -> latest/ + <tag>-<sha>/
#   .scripts/build-and-upload.sh --build-only   # build, skip upload
#   .scripts/build-and-upload.sh --dry-run      # build + print aws cmds, don't upload

set -euo pipefail

BUILD_ONLY=0
DRY_RUN=0
TAG=""
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0"
      exit 0
      ;;
    -*)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
    *)
      [[ -z "$TAG" ]] || { echo "unexpected extra arg: $arg" >&2; exit 2; }
      TAG="$arg"
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

for tool in cargo git jq npm; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
if [[ $BUILD_ONLY -eq 0 ]]; then
  command -v aws >/dev/null || { echo "missing tool: aws (install aws-cli)" >&2; exit 1; }
fi

# HEAD is this fork's sync commit, which means nothing in the upstream repo, so
# identify the build by the upstream commit it was made from: the tag's commit
# for a release, the upstream/main tip otherwise.
source_ref="${TAG:+refs/tags/${TAG}}"
source_ref="${source_ref:-upstream/main}"
if ! git_hash="$(git rev-parse -q --verify --short "${source_ref}^{commit}")"; then
  git_hash="$(git rev-parse --short HEAD)"
  echo "note: cannot resolve ${source_ref}; using HEAD ${git_hash} instead" >&2
fi

metadata="$(cargo metadata --no-deps --format-version 1)"
resolve_version() {
  local pkg="$1"
  local ver
  ver="$(printf '%s' "$metadata" | jq -r --arg p "$pkg" '.packages[] | select(.name==$p) | .version')"
  if [[ -z "$ver" || "$ver" == "null" ]]; then
    echo "Failed to resolve version for $pkg" >&2
    exit 1
  fi
  printf '%s' "$ver"
}

server_version="$(resolve_version did-hosting-server)"
witness_version="$(resolve_version webvh-witness)"
control_version="$(resolve_version did-hosting-control)"
watcher_version="$(resolve_version webvh-watcher)"
daemon_version="$(resolve_version did-hosting-daemon)"

echo "==> building did-hosting-server ${server_version}-${git_hash}"
cargo build --release -p did-hosting-server \
  --no-default-features --features "store-fjall,method-webvh,method-web"

echo "==> building webvh-witness ${witness_version}-${git_hash}"
cargo build --release -p webvh-witness \
  --no-default-features --features "store-fjall"

# did-hosting-control and did-hosting-daemon both embed the web bundle, so
# we build the UI before either of them.
echo "==> building did-hosting-ui (npm)"
(cd did-hosting-ui && npm install && npm run build:web)

echo "==> building did-hosting-control ${control_version}-${git_hash}"
cargo build --release -p did-hosting-control \
  --no-default-features --features "store-fjall,ui"

echo "==> building webvh-watcher ${watcher_version}-${git_hash}"
cargo build --release -p webvh-watcher

# The k8s variant is built first and copied aside, since the plain
# did-hosting-daemon build below overwrites target/release/did-hosting-daemon.
echo "==> building did-hosting-daemon-k8s ${daemon_version}-${git_hash}"
cargo build --release -p did-hosting-daemon \
  --no-default-features --features "store-fjall,ui,did-methods,vault-secrets"
cp target/release/did-hosting-daemon target/release/did-hosting-daemon-k8s

echo "==> building did-hosting-daemon ${daemon_version}-${git_hash}"
cargo build --release -p did-hosting-daemon \
  --no-default-features --features "store-fjall,ui,did-methods"

for bin in did-hosting-server webvh-witness did-hosting-control webvh-watcher \
           did-hosting-daemon did-hosting-daemon-k8s; do
  [[ -f "target/release/$bin" ]] || { echo "build succeeded but target/release/$bin missing" >&2; exit 1; }
done

if [[ $BUILD_ONLY -eq 1 ]]; then
  echo "==> --build-only set; skipping upload."
  exit 0
fi

for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ACCOUNT_ID R2_BUCKET; do
  if [[ -z "${!var:-}" ]]; then
    echo "missing env var: $var (set in shell or in <repo>/.env)" >&2
    exit 1
  fi
done

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="us-east-1"
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

upload_one() {
  local src="$1"
  local dest="$2"
  echo "==> uploading $src -> $dest"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "    [dry-run] aws s3 cp $src $dest --endpoint-url $ENDPOINT"
  else
    aws s3 cp "$src" "$dest" --endpoint-url "$ENDPOINT"
  fi
}

# Publish one binary: a tagged release goes to <tag>-<sha>/ + latest/; an
# untagged build goes to <version>-<sha>/ + main/.
upload() {
  local binary="$1"
  local name="$2"
  local version="$3"
  local upload_filename="${4:-$binary}"
  local src="target/release/${binary}"

  if [[ -n "$TAG" ]]; then
    upload_one "$src" "s3://${R2_BUCKET}/${name}/${TAG}-${git_hash}/${upload_filename}"
    upload_one "$src" "s3://${R2_BUCKET}/${name}/latest/${upload_filename}"
  else
    upload_one "$src" "s3://${R2_BUCKET}/${name}/${version}-${git_hash}/${upload_filename}"
    upload_one "$src" "s3://${R2_BUCKET}/${name}/main/${upload_filename}"
  fi
}

upload did-hosting-server     did-hosting-server     "$server_version"
upload webvh-witness          webvh-witness          "$witness_version"
upload did-hosting-control    did-hosting-control    "$control_version"
upload webvh-watcher          webvh-watcher          "$watcher_version"
upload did-hosting-daemon     did-hosting-daemon     "$daemon_version"
upload did-hosting-daemon-k8s did-hosting-daemon-k8s "$daemon_version" did-hosting-daemon

echo "==> done."
