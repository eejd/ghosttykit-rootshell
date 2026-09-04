# GhosttyKit for rootshell

This repository is the public binary Swift package for rootshell's Zig-built
GhosttyKit. Source builds live in the public
[`ghostty-rootshell`](https://github.com/eejd/ghostty-rootshell)
repository; this repository contains only the Swift package manifest, release
tooling, and release assets.

Two products are published from the same Ghostty revision:

- `GhosttyKitAppStore`: iOS, iOS Simulator, visionOS, visionOS Simulator, and
  Mac Catalyst, compiled without private CGS APIs.
- `GhosttyKitStandalone`: Mac Catalyst only, compiled with the Standalone CGS
  implementation.

Both products expose the Clang module `GhosttyKit` and the same public C ABI.
They must be linked into different application targets; do not link both into
one target.

## Using the package

Add the package over HTTPS and pin an exact release:

```swift
.package(
    url: "https://github.com/eejd/ghosttykit-rootshell.git",
    exact: "0.2.6"
)
```

Release archives use public GitHub download URLs and do not require GitHub
credentials.

## Publishing

The release script discovers checkouts portably. Explicit options take
precedence over environment variables and sibling checkout fallbacks.

```bash
./scripts/release.sh prepare 0.2.6 \
  --repo eejd/ghosttykit-rootshell \
  --rootshell-source /path/to/rootshell \
  --ghostty-source /path/to/ghostty-rootshell
```

Environment alternatives are `ROOTSHELL_SOURCE_DIR`, `GHOSTTY_SOURCE_DIR`,
and `GHOSTTYKIT_REPOSITORY`. With sibling checkouts named `swift-rootshell`
and `ghostty-rootshell`, the path options can be omitted.

Publishing requires Zig 0.16.x, Xcode command-line tools, authenticated `git`
access, and an authenticated GitHub CLI. `prepare` builds and audits both
artifacts, creates the draft release, and updates the manifest. Commit and
review that manifest normally. After it is merged, run from the clean,
up-to-date default branch:

```bash
./scripts/release.sh publish 0.2.6 --repo eejd/ghosttykit-rootshell
```

The publish phase verifies the reviewed manifest and draft assets before it
tags the merged commit and makes the release public. It also verifies that the
local origin matches the selected repository and that each draft asset's
GitHub SHA-256 digest matches the checksum committed in `Package.swift`.

## License

Ghostty and the rootshell packaging changes are available under the MIT
License. See [LICENSE](LICENSE).
