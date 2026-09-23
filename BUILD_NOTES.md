# Build notes — hermes-ios-prefer32

Working notes for producing the prebuilt iOS Hermes tarball. Read this before touching the build if you (or a future agent) come back cold.

## Goal

Produce `dist/hermes-ios-release.tar.gz`: a prebuilt iOS Hermes (V1) `hermesvm.xcframework` compiled with `-DHERMESVM_HEAP_HV_MODE=HEAP_HV_PREFER32`. Apps then set `HERMES_ENGINE_TARBALL_PATH` at `pod install` and skip compiling Hermes from source.

This is **not** a Hermes fork. We clone upstream `facebook/hermes` at the tag React Native pins and only pass one extra CMake option (a build flag that already exists upstream).

## Why PREFER32

- Maven's prebuilt iOS Hermes uses `HEAP_HV_64`.
- Android already gets `HEAP_HV_PREFER32` from the RN Gradle plugin.
- PREFER32 = compressed pointers + boxed doubles → roughly half the live JS heap footprint.
- Apps otherwise get this by patching `build-hermes-xcode.sh` and building Hermes from source on every clean build (slow). The tarball moves that compile out of the app.

## Version pinning

`versions.env` is the single source of truth:

- `RN_VERSION` — which `react-native` npm package to download.
- The Hermes tag is **not** hand-written; it is read from that package's `sdks/.hermesv1version`.
- `IOS_DEPLOYMENT_TARGET` — must be >= what consuming apps use (e.g. 16.4).

One tarball per RN line. Bump `RN_VERSION`, rebuild, publish a new Release tag. Keep old releases.

## Toolchain (verified on this machine)

- macOS + Xcode 26.4.1
- cmake 4.4.2 (`brew install cmake`)
- node 24 / npm 11 (for `npm pack react-native`)
- git, python3, rsync (all system-provided)
- ninja NOT required — RN's `build-apple-framework.sh` uses the default CMake generator.

## What the build does (scripts/build.sh)

1. `source versions.env`.
2. `npm pack react-native@$RN_VERSION` into `vendor/react-native` (Apple build scripts + JSI live here).
3. Read Hermes tag from `vendor/react-native/sdks/.hermesv1version`.
4. Clone `facebook/hermes` at that tag into `src/hermes`.
5. Copy Hermes source into `build/hermes-engine`, overlay RN's `sdks/hermes-engine/utils/*.sh`.
6. Inject `-DHERMESVM_HEAP_HV_MODE:STRING=HEAP_HV_PREFER32` into the copied `build-apple-framework.sh` (right after `-DHERMES_RELEASE_VERSION`).
7. Build host `hermesc`, then `iphoneos` (arm64) and `iphonesimulator` (x86_64;arm64).
8. `xcodebuild -create-xcframework` → `destroot/Library/Frameworks/universal/hermesvm.xcframework`.
9. Copy host `hermesc` into `destroot/bin` (a LOCAL tarball must ship hermesc; Maven tarballs skip it because they use the `hermes-compiler` npm package).
10. `tar` `destroot` → `dist/hermes-ios-release.tar.gz`.

Only `build/hermes-engine/utils/build-apple-framework.sh` is edited. `src/hermes` and any app's `node_modules` stay untouched.

## Tarball layout (what apps expect)

```
destroot/Library/Frameworks/universal/hermesvm.xcframework
destroot/include/...
destroot/bin/hermesc
```

## Run it

```bash
cd /path/to/hermes-ios-prefer32
chmod +x scripts/build.sh   # first time only
./scripts/build.sh
```

First run: downloads RN + clones Hermes + compiles device & simulator. Tens of minutes. Re-runs reuse `vendor/` and `src/` (see gotchas).

## Verify the artifact

```bash
tar -tzf dist/hermes-ios-release.tar.gz | grep -E 'xcframework/Info.plist|bin/hermesc'
# expect the universal xcframework and destroot/bin/hermesc
```

Confirm PREFER32 actually went in (checked during build):

```bash
grep HEAP_HV_PREFER32 build/hermes-engine/utils/build-apple-framework.sh
grep HEAP_HV build/hermes-engine/build_iphoneos/CMakeCache.txt
```

## Publish

Create the repo once (e.g. `<org>/hermes-ios-prefer32`), then attach the zip to a Release. Use the tag the script prints, do not hand-type it:

```bash
gh release create rn-<RN_VERSION>-<HERMES_TAG> \
  dist/hermes-ios-release.tar.gz \
  --title "Hermes PREFER32 for RN <RN_VERSION>"
```

Never commit `dist/` (binary). `.gitignore` already excludes `src/ build/ dist/ vendor/`.

## Use in an app

Apps that currently force from-source (Podfile sets `RCT_BUILD_HERMES_FROM_SOURCE = 'true'`) must:

1. Keep Hermes V1 on: `ENV['RCT_HERMES_V1_ENABLED'] = '1'`.
2. Set `HERMES_ENGINE_TARBALL_PATH` to the downloaded tarball BEFORE `prepare_react_native_project!`.
3. Stop forcing from-source: do not set `RCT_BUILD_HERMES_FROM_SOURCE` (delete it).
4. `bundle exec pod install`.

Success looks like:

```
[Hermes] Using pre-built binary from local path defined by HERMES_ENGINE_TARBALL_PATH
```

and the Xcode script phases `[RN] [1] Build Hermesc` / `[RN] [2] Build Hermes` are gone.

Do NOT set `REACT_NATIVE_OVERRIDE_HERMES_DIR` — it wins over the tarball and rebuilds from source.

## Gotchas / known issues

- **Stale vendor on RN bump.** `build.sh` only downloads `react-native` if `vendor/react-native` is missing. After changing `RN_VERSION`, delete `vendor/` (and ideally `src/ build/`) so it re-fetches the right RN + Hermes tag.
- **CocoaPods still cloned Hermes from git in an earlier test** even though the Podfile pointed at a tarball. If that happens: delete `ios/Pods/hermes-engine` and `ios/Pods/Local Podspecs/hermes-engine.podspec.json`, then `pod install` again. The source type is decided at podspec-eval time from the env var, so the env var must be set before pods resolve.
- **hermesc must be in the tarball.** `HERMES_ENGINE_TARBALL_PATH` (LOCAL_PREBUILT_TARBALL) does not pull the `hermes-compiler` npm binary; the podspec expects `destroot/bin/hermesc`. Step 9 handles this.
- **Config parity.** This is a Release (`MinSizeRel`) build, simulator + device only. No Debug tarball and no tvOS/visionOS slices. Add platforms via `HERMES_PLATFORMS` / a second `BUILD_TYPE=Debug` run if needed.
- **RN script drift.** On a future RN version the `-DHERMES_RELEASE_VERSION=...` anchor line in `build-apple-framework.sh` may change; the python injection in `build.sh` will error loudly (`could not find HERMES_RELEASE_VERSION`) if so. Fix the anchor, don't silently skip the flag.

## Native debug/release swap (option A) — Maven layout

`build.sh` now builds BOTH configs and emits a Maven-layout tree so apps get RN's
stock download-and-swap with zero per-config work:

- Debug tarball: `HERMES_ENABLE_DEBUGGER=true`, `CMAKE_BUILD_TYPE=Release`.
- Release tarball: `HERMES_ENABLE_DEBUGGER=false`, `CMAKE_BUILD_TYPE=MinSizeRel`.

Key facts that make this work (from RN's `hermes-utils.rb` / `hermes-engine.podspec` /
`replace_hermes_version.js`):

- The auto-swap only fires for source type `DOWNLOAD_PREBUILD_RELEASE_TARBALL`
  (Maven download), NOT for `HERMES_ENGINE_TARBALL_PATH` (that's single-file, no swap).
- Maven **version** is `HERMES_V1_VERSION_NAME` from `sdks/hermes-engine/version.properties`
  (`250829098.0.17`), which is DIFFERENT from the git tag `.hermesv1version`
  (`hermes-v250829098.0.17`). URL uses the version; clone uses the tag.
- URL shape RN builds:
  `<repo>/com/facebook/hermes/hermes-ios/<version>/hermes-ios-<version>-hermes-ios-<debug|release>.tar.gz`
- Existence check = `curl -I` → 200. `.sha1` is OPTIONAL (validation skipped if absent);
  we still emit `.sha1` for integrity.
- On downloaded-tarball path RN gets `hermesc` from the `hermes-compiler` npm package,
  so the tarballs don't strictly need `destroot/bin/hermesc` — we include it anyway so
  the same files also work via `HERMES_ENGINE_TARBALL_PATH`.
- The swap script extracts `hermes-ios-<version>-<config>.tar.gz` into `Pods/hermes-engine/`,
  so each tarball must carry the full `destroot/...` (ours does).

### Publish (host the Maven tree)

Serve `dist/maven2` from any static host that returns 200 on nested paths
(GitHub Pages, S3, Artifactory). Then in each app's Podfile (committed once):

```ruby
ENV['RCT_HERMES_V1_ENABLED'] = '1'
ENV['ENTERPRISE_REPOSITORY'] = 'https://<host>/maven2'
# do NOT set RCT_BUILD_HERMES_FROM_SOURCE; do NOT set HERMES_ENGINE_TARBALL_PATH
```

For Expo CNG/EAS apps the Podfile is regenerated by prebuild, so set
`ENTERPRISE_REPOSITORY` via `eas.json` `env` or a config plugin, not a hand edit.
Expo Go cannot use this (can't swap Hermes) — needs a dev/EAS build.

Scope: **Hermes V1 only.** Non-V1 RN lines are intentionally out.

## Build history

<!-- append one line per build: date, RN_VERSION, hermes tag, result, tarball size -->
- 2026-09-23 — RN 0.86.3, hermes-v250829098.0.17 — OK, 5.1M. Slices: ios-arm64 (device, minos 16.4) + ios-arm64_x86_64-simulator. hermesc arm64 present. CMakeCache confirms HERMESVM_HEAP_HV_MODE=HEAP_HV_PREFER32. Full clean build ~9.5 min on this Mac (Xcode 26.4.1, cmake 4.4.2).
- 2026-09-23 — RN 0.86.3, hermes-v250829098.0.17 — OK, both configs. release 5.1M (debugger off), debug 6.5M (debugger on). Maven tree at dist/maven2/com/facebook/hermes/hermes-ios/250829098.0.17/ with .sha1. Two-config build ~8 min (host hermesc reused).

## Fixes this repo's build.sh had to apply on top of RN's Apple scripts

RN 0.86.3's `sdks/hermes-engine/utils/build-apple-framework.sh` is the legacy/CI path and does not fully match Hermes V1 + modern cmake. `build.sh` patches the copied script:

1. **PREFER32** — add `-DHERMESVM_HEAP_HV_MODE:STRING=HEAP_HV_PREFER32` after `-DHERMES_RELEASE_VERSION`.
2. **Host hermesc CMAKE_BUILD_TYPE** — `build_host_hermesc` runs `cmake -S . -B build_host_hermesc -DJSI_DIR=...` with no build type; this Hermes tag's root `CMakeLists.txt` (`FATAL_ERROR "Please set CMAKE_BUILD_TYPE"`) aborts on a single-config generator. Patched to add `-DCMAKE_BUILD_TYPE=Release`.
3. **Missing inspector headers** — the script copies `API/hermes/inspector/*.h` (+ `inspector/chrome`), which don't exist in Hermes V1; under `set -e` this aborted the framework build. Patched those two `cp`s to `... 2>/dev/null || true`.
4. **jsi/hermes.h alias** — the V1 prebuilt podspec references `destroot/include/jsi/hermes.h`; the copied JSI headers only provide `jsi/hermes-interfaces.h`. `build.sh` aliases it after the build.

If a future RN bump changes these anchor lines, the python patch in `build.sh` fails loudly rather than silently dropping a fix — update the anchors and re-run.

## Operational note for background runs

Do not launch the build as a detached background job from a one-shot shell (nohup/&). It got reaped and left an empty `src/hermes`. Run `./scripts/build.sh` as a normal long-running foreground command instead.
