#!/usr/bin/env bash
# Download upstream RN + Hermes, build iOS with HEAP_HV_PREFER32, pack the RN tarball.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"

if ! command -v cmake >/dev/null; then
  echo "error: cmake is required (brew install cmake)" >&2
  exit 1
fi
if ! command -v npm >/dev/null; then
  echo "error: npm is required to download react-native@$RN_VERSION" >&2
  exit 1
fi

VENDOR="$ROOT/vendor/react-native"
if [[ ! -f "$VENDOR/package.json" ]]; then
  echo "Downloading react-native@$RN_VERSION from npm..."
  mkdir -p "$ROOT/vendor"
  tmp="$ROOT/vendor/npm-tmp"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  (cd "$tmp" && npm pack "react-native@$RN_VERSION" --silent)
  tar -xzf "$tmp"/react-native-*.tgz -C "$tmp"
  rm -rf "$VENDOR"
  mv "$tmp/package" "$VENDOR"
  rm -rf "$tmp"
fi

UTILS_SRC="$VENDOR/sdks/hermes-engine/utils"
TAG_FILE="$VENDOR/sdks/.hermesv1version"
if [[ ! -f "$TAG_FILE" ]]; then
  echo "error: $TAG_FILE missing in react-native@$RN_VERSION" >&2
  exit 1
fi

TAG="$(tr -d '[:space:]' < "$TAG_FILE")"
SRC="$ROOT/src/hermes"
WORKDIR="$ROOT/build/hermes-engine"

if [[ ! -d "$SRC/.git" ]]; then
  echo "Cloning facebook/hermes at $TAG..."
  mkdir -p "$ROOT/src"
  git clone --depth 1 --branch "$TAG" https://github.com/facebook/hermes.git "$SRC"
else
  git -C "$SRC" fetch --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG" || \
    git -C "$SRC" fetch --depth 1 origin tag "$TAG"
  git -C "$SRC" checkout --force "$TAG"
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
rsync -a --delete --exclude '.git' "$SRC/" "$WORKDIR/"
mkdir -p "$WORKDIR/utils"
cp "$UTILS_SRC/"*.sh "$WORKDIR/utils/"
chmod +x "$WORKDIR/utils/"*.sh

python3 - "$WORKDIR/utils/build-apple-framework.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
needle = '      -DHERMES_RELEASE_VERSION="for RN $(get_release_version)" \\\n'
flag = '      -DHERMESVM_HEAP_HV_MODE:STRING=HEAP_HV_PREFER32 \\\n'
if flag not in text:
    if needle not in text:
        raise SystemExit('could not find HERMES_RELEASE_VERSION in build-apple-framework.sh')
    path.write_text(text.replace(needle, needle + flag, 1))
print('using', path, 'with HEAP_HV_PREFER32')
PY

export REACT_NATIVE_PATH="$VENDOR"
export JSI_PATH="$VENDOR/ReactCommon/jsi"
export IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
export MAC_DEPLOYMENT_TARGET="${MAC_DEPLOYMENT_TARGET:-10.13}"
export RELEASE_VERSION="$RN_VERSION"
export BUILD_TYPE="${BUILD_TYPE:-Release}"
export HERMES_PATH="$WORKDIR"

cd "$WORKDIR"
# shellcheck disable=SC1091
. ./utils/build-apple-framework.sh

build_host_hermesc_if_needed

arch_for() {
  case "$1" in
    iphoneos) echo "arm64" ;;
    iphonesimulator) echo "x86_64;arm64" ;;
    *) echo "error: unsupported platform $1" >&2; exit 1 ;;
  esac
}

PLATFORMS="${HERMES_PLATFORMS:-iphoneos iphonesimulator}"
XC_PLATFORMS=()
for platform in $PLATFORMS; do
  echo "Building $BUILD_TYPE framework for $platform..."
  build_apple_framework "$platform" "$(arch_for "$platform")" "$IOS_DEPLOYMENT_TARGET"
  XC_PLATFORMS+=("$platform")
done

create_universal_framework "${XC_PLATFORMS[@]}"

mkdir -p destroot/bin
cp -f build_host_hermesc/bin/hermesc destroot/bin/hermesc
chmod +x destroot/bin/hermesc

if [[ ! -d destroot/Library/Frameworks/universal/hermesvm.xcframework ]]; then
  echo "error: xcframework was not created" >&2
  exit 1
fi

mkdir -p "$ROOT/dist"
TARBALL="$ROOT/dist/hermes-ios-release.tar.gz"
tar -C "$WORKDIR" -czf "$TARBALL" destroot

echo "Wrote $TARBALL ($(du -h "$TARBALL" | awk '{print $1}'))"
echo "react-native@$RN_VERSION + facebook/hermes @$TAG + HEAP_HV_PREFER32"
echo
echo "Publish:"
echo "  gh release create rn-${RN_VERSION}-${TAG} $TARBALL"
echo "Use in any RN $RN_VERSION app:"
echo "  HERMES_ENGINE_TARBALL_PATH=$TARBALL bundle exec pod install"
