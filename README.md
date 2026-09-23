# hermes-ios-prefer32

Prebuilt iOS Hermes (V1) with `HEAP_HV_PREFER32` for any React Native app on the pinned RN version.

This is not a Hermes fork. The build downloads:

- `react-native` from npm (Apple scripts + JSI)
- `facebook/hermes` at the tag that package pins (`sdks/.hermesv1version`)

Then it compiles with:

```text
-DHERMESVM_HEAP_HV_MODE=HEAP_HV_PREFER32
```

Maven’s iOS Hermes is `HEAP_HV_64`. Android already gets PREFER32 from the RN Gradle plugin.

Pin the RN version in `versions.env`. Bump that file when you need a tarball for a newer RN.

## What apps consume

GitHub **Release** assets, not files in this git tree:

- `hermes-ios-release.tar.gz`

Layout inside the tarball:

```text
destroot/Library/Frameworks/universal/hermesvm.xcframework
destroot/include/...
destroot/bin/hermesc
```

Tag releases like `rn-0.86.3-hermes-v250829098.0.17`. Use that tarball only with matching React Native.

## Produce a tarball

Needs Xcode, CMake (`brew install cmake`), and npm.

```bash
./scripts/build.sh
```

Writes `dist/hermes-ios-release.tar.gz`. First run downloads RN + Hermes and compiles device + simulator (tens of minutes).

## Publish

```bash
gh release create rn-0.86.3-hermes-v250829098.0.17 \
  dist/hermes-ios-release.tar.gz \
  --title "Hermes PREFER32 for RN 0.86.3"
```

## Use in an app

React Native already supports a local tarball. In `ios/`:

```bash
export HERMES_ENGINE_TARBALL_PATH=/path/to/hermes-ios-release.tar.gz
unset RCT_BUILD_HERMES_FROM_SOURCE
bundle exec pod install
```

Do not set `REACT_NATIVE_OVERRIDE_HERMES_DIR`.
