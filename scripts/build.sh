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

# 1) PREFER32 heap encoding on the per-platform framework build.
needle = '      -DHERMES_RELEASE_VERSION="for RN $(get_release_version)" \\\n'
flag = '      -DHERMESVM_HEAP_HV_MODE:STRING=HEAP_HV_PREFER32 \\\n'
if flag not in text:
    if needle not in text:
        raise SystemExit('could not find HERMES_RELEASE_VERSION in build-apple-framework.sh')
    text = text.replace(needle, needle + flag, 1)

# 2) Host hermesc configure lacks CMAKE_BUILD_TYPE; recent Hermes CMakeLists
#    aborts on a single-config generator without it. Add it.
host = '  cmake -S . -B build_host_hermesc -DJSI_DIR="$JSI_PATH"\n'
host_fixed = '  cmake -S . -B build_host_hermesc -DCMAKE_BUILD_TYPE=Release -DJSI_DIR="$JSI_PATH"\n'
if host in text:
    text = text.replace(host, host_fixed, 1)
elif host_fixed not in text and 'build_host_hermesc' in text and 'CMAKE_BUILD_TYPE=Release -DJSI_DIR' not in text:
    raise SystemExit('host hermesc cmake line changed; update build.sh patch')

# 3) Hermes V1 has no API/hermes/inspector headers, but the RN script copies
#    them unconditionally and `set -e` then aborts the framework build.
for line in (
    'cp API/hermes/inspector/*.h destroot/include/hermes/inspector\n',
    'cp API/hermes/inspector/chrome/*.h destroot/include/hermes/inspector/chrome\n',
):
    if line in text:
        text = text.replace(line, line.rstrip('\n') + ' 2>/dev/null || true\n', 1)

path.write_text(text)
print('using', path, 'with HEAP_HV_PREFER32 + host CMAKE_BUILD_TYPE + tolerant inspector headers')
PY

export REACT_NATIVE_PATH="$VENDOR"
export JSI_PATH="$VENDOR/ReactCommon/jsi"
export IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
export MAC_DEPLOYMENT_TARGET="${MAC_DEPLOYMENT_TARGET:-10.13}"
export RELEASE_VERSION="$RN_VERSION"
export HERMES_PATH="$WORKDIR"

# The Maven artifact version differs from the git tag. RN's podspec resolves the
# Hermes V1 pod version from version.properties (HERMES_V1_VERSION_NAME), and that
# is what appears in the download URL and in the swap script's filename.
VERSION_PROPS="$VENDOR/sdks/hermes-engine/version.properties"
MAVEN_VERSION="$(grep '^HERMES_V1_VERSION_NAME=' "$VERSION_PROPS" | cut -d= -f2 | tr -d '[:space:]')"
if [[ -z "$MAVEN_VERSION" ]]; then
  echo "error: HERMES_V1_VERSION_NAME missing in $VERSION_PROPS" >&2
  exit 1
fi

cd "$WORKDIR"
# shellcheck disable=SC1091
. ./utils/build-apple-framework.sh

# Host hermesc is configuration-independent; build it once and reuse it.
export BUILD_TYPE=Release
build_host_hermesc_if_needed

arch_for() {
  case "$1" in
    iphoneos) echo "arm64" ;;
    iphonesimulator) echo "x86_64;arm64" ;;
    *) echo "error: unsupported platform $1" >&2; exit 1 ;;
  esac
}

PLATFORMS="${HERMES_PLATFORMS:-iphoneos iphonesimulator}"
MAVEN_DIR="$ROOT/dist/maven2/com/facebook/hermes/hermes-ios/$MAVEN_VERSION"
mkdir -p "$ROOT/dist" "$MAVEN_DIR"

# Build one Hermes configuration into destroot and emit both a convenience
# tarball and the Maven-layout artifact RN downloads.
#   Debug   -> enable_debugger=true,  cmake_build_type=Release   (JS debugger on)
#   Release -> enable_debugger=false, cmake_build_type=MinSizeRel (lean)
build_config() {
  local cfg="$1"
  local maven_cfg
  maven_cfg="$(echo "$cfg" | tr '[:upper:]' '[:lower:]')"
  export BUILD_TYPE="$cfg"

  echo "=== Building Hermes ($cfg) ==="
  # Fresh per-config outputs; keep build_host_hermesc across configs.
  rm -rf destroot
  local platform
  for platform in $PLATFORMS; do
    rm -rf "build_$platform"
  done

  local xc=()
  for platform in $PLATFORMS; do
    echo "Building $cfg framework for $platform..."
    build_apple_framework "$platform" "$(arch_for "$platform")" "$IOS_DEPLOYMENT_TARGET"
    xc+=("$platform")
  done
  create_universal_framework "${xc[@]}"

  mkdir -p destroot/bin
  cp -f build_host_hermesc/bin/hermesc destroot/bin/hermesc
  chmod +x destroot/bin/hermesc

  # Hermes V1's prebuilt podspec references destroot/include/jsi/hermes.h.
  if [[ -f destroot/include/jsi/hermes-interfaces.h && ! -f destroot/include/jsi/hermes.h ]]; then
    cp destroot/include/jsi/hermes-interfaces.h destroot/include/jsi/hermes.h
  fi

  if [[ ! -d destroot/Library/Frameworks/universal/hermesvm.xcframework ]]; then
    echo "error: xcframework was not created for $cfg" >&2
    exit 1
  fi

  # Convenience copy.
  tar -C "$WORKDIR" -czf "$ROOT/dist/hermes-ios-$maven_cfg.tar.gz" destroot

  # Maven-layout artifact + optional .sha1 (RN validates it when present).
  local maven_file="$MAVEN_DIR/hermes-ios-$MAVEN_VERSION-hermes-ios-$maven_cfg.tar.gz"
  cp -f "$ROOT/dist/hermes-ios-$maven_cfg.tar.gz" "$maven_file"
  ( cd "$MAVEN_DIR" && shasum -a 1 "$(basename "$maven_file")" | awk '{print $1}' > "$maven_file.sha1" )
  echo "Wrote $maven_file ($(du -h "$maven_file" | awk '{print $1}'))"
}

build_config Release
build_config Debug

echo
echo "react-native@$RN_VERSION + facebook/hermes @$TAG + HEAP_HV_PREFER32"
echo "Maven version: $MAVEN_VERSION"
echo "Maven tree:    $ROOT/dist/maven2"
echo
echo "Publish the Maven tree to a static host that serves nested paths and 200s"
echo "(GitHub Pages, S3, etc.), then point apps at it:"
echo "  ENV['ENTERPRISE_REPOSITORY'] = 'https://<host>/maven2'   # in the app Podfile"
echo
echo "Convenience single-file tarballs (LOCAL_PREBUILT_TARBALL path) are also in:"
echo "  $ROOT/dist/hermes-ios-release.tar.gz"
echo "  $ROOT/dist/hermes-ios-debug.tar.gz"
