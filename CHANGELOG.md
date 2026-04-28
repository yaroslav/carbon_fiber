## [0.1.1] - 2026-04-29

- Fix the macOS release build: rewrite the precompiled bundle's libruby reference to `@rpath/libruby.X.Y.dylib` and add `@executable_path/../lib` so the `arm64-darwin` gem loads on any Ruby install. Previously the install_name was a hardcoded path to the GitHub Actions tool-cache, causing dyld to refuse to load the bundle on user machines.
- A native binary that exists on disk but fails to load now raises `LoadError` instead of silently falling back to the pure-Ruby implementation.

## [0.1.0] - 2026-04-14

- Initial release. Ruby Fiber Manager, Async backend, extensive benchmarking suite.
