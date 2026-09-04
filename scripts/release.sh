#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    cat >&2 <<'EOF'
Usage:
  release.sh prepare <version> [--repo <owner/name>] [--rootshell-source <path>]
      [--ghostty-source <path>] [--zig <path>] [--skip-build]
  release.sh publish <version> [--repo <owner/name>]

prepare builds and uploads both XCFrameworks to a draft release, then updates
Package.swift. Commit that manifest through review before running publish.

publish must run from the clean, up-to-date default branch. It tags the reviewed
manifest commit and publishes the existing draft release.
EOF
    exit 1
}

MODE="${1:-}"
VERSION="${2:-}"
if [[ "$MODE" != prepare && "$MODE" != publish ]] ||
   [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    usage
fi
shift 2

REPOSITORY="${GHOSTTYKIT_REPOSITORY:-}"
ROOTSHELL_SOURCE="${ROOTSHELL_SOURCE_DIR:-}"
GHOSTTY_SOURCE="${GHOSTTY_SOURCE_DIR:-}"
ZIG_BIN="${ZIG_BIN:-}"
SKIP_BUILD=false
PREPARE_ONLY_OPTION=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPOSITORY="${2:-}"
            shift 2
            ;;
        --rootshell-source)
            ROOTSHELL_SOURCE="${2:-}"
            PREPARE_ONLY_OPTION=true
            shift 2
            ;;
        --ghostty-source)
            GHOSTTY_SOURCE="${2:-}"
            PREPARE_ONLY_OPTION=true
            shift 2
            ;;
        --zig)
            ZIG_BIN="${2:-}"
            PREPARE_ONLY_OPTION=true
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            PREPARE_ONLY_OPTION=true
            shift
            ;;
        *)
            usage
            ;;
    esac
done

if [[ "$MODE" == publish && "$PREPARE_ONLY_OPTION" == true ]]; then
    echo "ERROR: build options are only valid with prepare" >&2
    exit 1
fi

for command in git gh swift; do
    if ! command -v "$command" >/dev/null; then
        echo "ERROR: required command not found: $command" >&2
        exit 1
    fi
done
gh auth status >/dev/null

if [[ -z "$REPOSITORY" ]]; then
    REPOSITORY="$(cd "$PACKAGE_DIR" && gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi
if [[ ! "$REPOSITORY" =~ ^[^/]+/[^/]+$ ]]; then
    echo "ERROR: repository must be in owner/name form: $REPOSITORY" >&2
    exit 1
fi

TAG="v$VERSION"

release_id() {
    gh api "repos/$REPOSITORY/releases" \
        --jq "map(select(.tag_name == \"$TAG\" and .draft == true))[0].id // empty"
}

verify_assets() {
    local id="$1" appstore_count standalone_count
    appstore_count="$(gh api "repos/$REPOSITORY/releases/$id" \
        --jq '[.assets[] | select(.name == "GhosttyKitAppStore.xcframework.zip")] | length')"
    standalone_count="$(gh api "repos/$REPOSITORY/releases/$id" \
        --jq '[.assets[] | select(.name == "GhosttyKitStandalone.xcframework.zip")] | length')"
    if [[ "$appstore_count" != 1 || "$standalone_count" != 1 ]]; then
        echo "ERROR: expected release assets were not uploaded exactly once" >&2
        exit 1
    fi
}

if [[ "$MODE" == prepare ]]; then
    if [[ -z "$ROOTSHELL_SOURCE" && -x "$PACKAGE_DIR/../swift-rootshell/scripts/build-framework.sh" ]]; then
        ROOTSHELL_SOURCE="$PACKAGE_DIR/../swift-rootshell"
    fi
    if [[ -z "$GHOSTTY_SOURCE" && -f "$PACKAGE_DIR/../ghostty-rootshell/build.zig" ]]; then
        GHOSTTY_SOURCE="$PACKAGE_DIR/../ghostty-rootshell"
    fi
    if [[ -z "$ROOTSHELL_SOURCE" || ! -x "$ROOTSHELL_SOURCE/scripts/build-framework.sh" ]]; then
        echo "ERROR: pass --rootshell-source or set ROOTSHELL_SOURCE_DIR" >&2
        exit 1
    fi
    if [[ -z "$GHOSTTY_SOURCE" || ! -f "$GHOSTTY_SOURCE/build.zig" ]]; then
        echo "ERROR: pass --ghostty-source or set GHOSTTY_SOURCE_DIR" >&2
        exit 1
    fi
    if ! command -v ditto >/dev/null; then
        echo "ERROR: required command not found: ditto" >&2
        exit 1
    fi

    ROOTSHELL_SOURCE="$(cd "$ROOTSHELL_SOURCE" && pwd)"
    GHOSTTY_SOURCE="$(cd "$GHOSTTY_SOURCE" && pwd)"
    if [[ -n "$(git -C "$GHOSTTY_SOURCE" status --porcelain)" ]]; then
        echo "ERROR: Ghostty source repository must be clean before publishing" >&2
        exit 1
    fi

    if [[ "$SKIP_BUILD" == false ]]; then
        BUILD_ARGS=(all --ghostty-source "$GHOSTTY_SOURCE" --clean)
        if [[ -n "$ZIG_BIN" ]]; then
            BUILD_ARGS+=(--zig "$ZIG_BIN")
        fi
        "$ROOTSHELL_SOURCE/scripts/build-framework.sh" "${BUILD_ARGS[@]}"
    fi

    LOCAL_PACKAGE="$ROOTSHELL_SOURCE/.local-packages/ghosttykit-rootshell"
    APPSTORE_ID="$(<"$LOCAL_PACKAGE/Artifacts/AppStore/current")"
    STANDALONE_ID="$(<"$LOCAL_PACKAGE/Artifacts/Standalone/current")"
    APPSTORE_XCF="$LOCAL_PACKAGE/Artifacts/AppStore/$APPSTORE_ID/GhosttyKitAppStore.xcframework"
    STANDALONE_XCF="$LOCAL_PACKAGE/Artifacts/Standalone/$STANDALONE_ID/GhosttyKitStandalone.xcframework"

    STAGE="$PACKAGE_DIR/.build/releases/$VERSION"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    APPSTORE_ZIP="$STAGE/GhosttyKitAppStore.xcframework.zip"
    STANDALONE_ZIP="$STAGE/GhosttyKitStandalone.xcframework.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APPSTORE_XCF" "$APPSTORE_ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$STANDALONE_XCF" "$STANDALONE_ZIP"

    APPSTORE_CHECKSUM="$(swift package compute-checksum "$APPSTORE_ZIP")"
    STANDALONE_CHECKSUM="$(swift package compute-checksum "$STANDALONE_ZIP")"
    GHOSTTY_REVISION="$(git -C "$GHOSTTY_SOURCE" rev-parse HEAD)"

    RELEASE_ID="$(release_id)"
    if [[ -z "$RELEASE_ID" ]]; then
        gh release create "$TAG" "$APPSTORE_ZIP" "$STANDALONE_ZIP" \
            --repo "$REPOSITORY" \
            --draft \
            --title "GhosttyKit $VERSION" \
            --notes "Zig Ghostty revision: $GHOSTTY_REVISION"
        RELEASE_ID="$(release_id)"
    else
        gh release upload "$TAG" "$APPSTORE_ZIP" "$STANDALONE_ZIP" \
            --repo "$REPOSITORY" --clobber
        gh release edit "$TAG" --repo "$REPOSITORY" \
            --notes "Zig Ghostty revision: $GHOSTTY_REVISION"
    fi
    if [[ -z "$RELEASE_ID" ]]; then
        echo "ERROR: could not determine GitHub draft release ID" >&2
        exit 1
    fi
    verify_assets "$RELEASE_ID"

    cat > "$PACKAGE_DIR/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ghosttykit-rootshell",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .visionOS(.v1)],
    products: [
        .library(name: "GhosttyKitAppStore", targets: ["GhosttyKitAppStore"]),
        .library(name: "GhosttyKitStandalone", targets: ["GhosttyKitStandalone"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKitAppStore",
            url: "https://github.com/$REPOSITORY/releases/download/$TAG/GhosttyKitAppStore.xcframework.zip",
            checksum: "$APPSTORE_CHECKSUM"
        ),
        .binaryTarget(
            name: "GhosttyKitStandalone",
            url: "https://github.com/$REPOSITORY/releases/download/$TAG/GhosttyKitStandalone.xcframework.zip",
            checksum: "$STANDALONE_CHECKSUM"
        ),
    ]
)
EOF

    swift package --package-path "$PACKAGE_DIR" dump-package >/dev/null
    echo "Prepared GhosttyKit $VERSION from Ghostty $GHOSTTY_REVISION"
    echo "Commit and review Package.swift, merge it, then run: $0 publish $VERSION --repo $REPOSITORY"
    exit 0
fi

if [[ -n "$(git -C "$PACKAGE_DIR" status --porcelain)" ]]; then
    echo "ERROR: package repository must be clean before publishing" >&2
    exit 1
fi
if git -C "$PACKAGE_DIR" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "ERROR: tag already exists: $TAG" >&2
    exit 1
fi

DEFAULT_BRANCH="$(gh repo view "$REPOSITORY" --json defaultBranchRef --jq .defaultBranchRef.name)"
BRANCH="$(git -C "$PACKAGE_DIR" branch --show-current)"
if [[ "$BRANCH" != "$DEFAULT_BRANCH" ]]; then
    echo "ERROR: publish must run from the default branch ($DEFAULT_BRANCH), not $BRANCH" >&2
    exit 1
fi
git -C "$PACKAGE_DIR" fetch origin "$DEFAULT_BRANCH"
if [[ "$(git -C "$PACKAGE_DIR" rev-parse HEAD)" != "$(git -C "$PACKAGE_DIR" rev-parse "origin/$DEFAULT_BRANCH")" ]]; then
    echo "ERROR: local $DEFAULT_BRANCH must exactly match origin/$DEFAULT_BRANCH" >&2
    exit 1
fi
if ! grep -Fq "github.com/$REPOSITORY/releases/download/$TAG/" "$PACKAGE_DIR/Package.swift"; then
    echo "ERROR: Package.swift does not reference $REPOSITORY $TAG" >&2
    exit 1
fi

RELEASE_ID="$(release_id)"
if [[ -z "$RELEASE_ID" ]]; then
    echo "ERROR: no draft release found for $TAG" >&2
    exit 1
fi
verify_assets "$RELEASE_ID"

git -C "$PACKAGE_DIR" tag "$TAG"
git -C "$PACKAGE_DIR" push origin "$TAG"
gh release edit "$TAG" --repo "$REPOSITORY" --draft=false
echo "Published GhosttyKit $VERSION from reviewed commit $(git -C "$PACKAGE_DIR" rev-parse HEAD)"
