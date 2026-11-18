# hermes-custom

Hermes for React Native iOS, built from the official `facebook/hermes` tags with the patches in `patches/`, and served in Maven's layout so apps can use it through `ENTERPRISE_REPOSITORY`.

Current patch: `HERMESVM_HEAP_HV_MODE=HEAP_HV_PREFER32` (compressed pointers, smaller JavaScript heap). Everything else matches the official Maven build: Debug and Release, all 8 Apple slices, dSYMs as separate files.

## Use in an app

```ruby
# ios/Podfile, before prepare_react_native_project!
ENV['RCT_HERMES_V1_ENABLED'] = '1'
ENV['ENTERPRISE_REPOSITORY'] = 'https://karkakol.github.io/hermes-custom/maven2'
```

Don't set `RCT_BUILD_HERMES_FROM_SOURCE` or `HERMES_ENGINE_TARBALL_PATH`. `ENTERPRISE_REPOSITORY` applies to every artifact React Native downloads, so apps that use React Native's prebuilt dependencies (`RCT_USE_RN_DEP`) need those listed in `hosting.txt` too.

## Add a Hermes version

1. Find the tag in `node_modules/react-native/sdks/.hermesv1version`.
2. Run **Build Hermes** with that tag. It publishes the release `<tag>-custom.<revision>` and fails if any slice is missing a setting from `expected-cmake.txt`.
3. Add the release to `hosting.txt`. Pushing it redeploys the site.

GitHub Pages allows 1 GB per site; dSYMs are about 810 MB per version, so host them for one version at most here.
