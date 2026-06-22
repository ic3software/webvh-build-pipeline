#!/usr/bin/env bash
#
# Local mirror of .github/workflows/build.yml: builds the webvh service
# binaries (did-hosting-server, webvh-witness, did-hosting-control,
# webvh-watcher, did-hosting-daemon) plus the did-hosting-ui web bundle,
# and uploads each binary to Cloudflare R2 under both `latest/` and a
# versioned path (`<crate-version>-<git-short-sha>/`).
#
# Required env vars (export them, or put them in <repo>/.env):
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   R2_ACCOUNT_ID
#   R2_BUCKET
#
# Usage:
#   .scripts/build-and-upload.sh                # build + upload everything
#   .scripts/build-and-upload.sh --build-only   # build, skip upload
#   .scripts/build-and-upload.sh --dry-run      # build + print aws cmds, don't upload
#   .scripts/build-and-upload.sh --only <name>  # build+upload a single binary
#                                                 (repeatable; one of:
#                                                  did-hosting-server,
#                                                  webvh-witness,
#                                                  did-hosting-control,
#                                                  webvh-watcher,
#                                                  did-hosting-daemon)

set -euo pipefail

BUILD_ONLY=0
DRY_RUN=0
ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) BUILD_ONLY=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --only)
      [[ $# -ge 2 ]] || { echo "--only requires a value" >&2; exit 2; }
      ONLY+=("$2"); shift 2 ;;
    -h|--help)
      sed -n '2,28p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
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
git_hash="$(git rev-parse --short HEAD)"

# Whether to act on a given binary. With no --only flags, everything runs.
want() {
  local name="$1"
  if [[ ${#ONLY[@]} -eq 0 ]]; then
    return 0
  fi
  local item
  for item in "${ONLY[@]}"; do
    [[ "$item" == "$name" ]] && return 0
  done
  return 1
}

# Validate --only values.
if [[ ${#ONLY[@]} -gt 0 ]]; then
  valid_names=(did-hosting-server webvh-witness did-hosting-control webvh-watcher did-hosting-daemon)
  for item in "${ONLY[@]}"; do
    found=0
    for name in "${valid_names[@]}"; do
      [[ "$name" == "$item" ]] && { found=1; break; }
    done
    if [[ $found -eq 0 ]]; then
      echo "unknown --only target: $item" >&2
      echo "valid targets: ${valid_names[*]}" >&2
      exit 2
    fi
  done
fi

if want did-hosting-server; then
  echo "==> building did-hosting-server ${server_version}-${git_hash}"
  cargo build --release -p did-hosting-server \
    --no-default-features --features "store-fjall,method-webvh,method-web"
fi

if want webvh-witness; then
  echo "==> building webvh-witness ${witness_version}-${git_hash}"
  cargo build --release -p webvh-witness \
    --no-default-features --features "store-fjall"
fi

# did-hosting-control and did-hosting-daemon both embed the web bundle, so
# we build the UI before either of those.
if want did-hosting-control || want did-hosting-daemon; then
  echo "==> building did-hosting-ui (npm)"
  (cd did-hosting-ui && npm install && npm run build:web)
fi

if want did-hosting-control; then
  echo "==> building did-hosting-control ${control_version}-${git_hash}"
  cargo build --release -p did-hosting-control \
    --no-default-features --features "store-fjall,ui"
fi

if want webvh-watcher; then
  echo "==> building webvh-watcher ${watcher_version}-${git_hash}"
  cargo build --release -p webvh-watcher
fi

if want did-hosting-daemon; then
  echo "==> building did-hosting-daemon ${daemon_version}-${git_hash}"
  cargo build --release -p did-hosting-daemon \
    --no-default-features --features "store-fjall,ui,did-methods"
fi

# Verify each built binary exists.
check_binary() {
  local binary="$1"
  if want "$binary"; then
    [[ -f "target/release/$binary" ]] || { echo "build succeeded but target/release/$binary missing" >&2; exit 1; }
  fi
}
check_binary did-hosting-server
check_binary webvh-witness
check_binary did-hosting-control
check_binary webvh-watcher
check_binary did-hosting-daemon

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

upload() {
  local binary="$1"
  local name="$2"
  local version="$3"
  local version_tag="${version}-${git_hash}"
  local src="target/release/${binary}"
  local latest_dest="s3://${R2_BUCKET}/${name}/latest/${binary}"
  local versioned_dest="s3://${R2_BUCKET}/${name}/${version_tag}/${binary}"

  echo "==> uploading $src -> $latest_dest"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "    [dry-run] aws s3 cp $src $latest_dest --endpoint-url $ENDPOINT"
  else
    aws s3 cp "$src" "$latest_dest" --endpoint-url "$ENDPOINT"
  fi

  echo "==> uploading $src -> $versioned_dest"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "    [dry-run] aws s3 cp $src $versioned_dest --endpoint-url $ENDPOINT"
  else
    aws s3 cp "$src" "$versioned_dest" --endpoint-url "$ENDPOINT"
  fi
}

want did-hosting-server  && upload did-hosting-server  did-hosting-server  "$server_version"
want webvh-witness       && upload webvh-witness       webvh-witness       "$witness_version"
want did-hosting-control && upload did-hosting-control did-hosting-control "$control_version"
want webvh-watcher       && upload webvh-watcher       webvh-watcher       "$watcher_version"
want did-hosting-daemon  && upload did-hosting-daemon  did-hosting-daemon  "$daemon_version"

echo "==> done."
