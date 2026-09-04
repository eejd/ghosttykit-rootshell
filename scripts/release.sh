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

ORIGIN_URL="$(git -C "$PACKAGE_DIR" remote get-url origin)"
LOCAL_REPOSITORY="$(gh repo view "$ORIGIN_URL" --json nameWithOwner --jq .nameWithOwner)"
if [[ -z "$REPOSITORY" ]]; then
    REPOSITORY="$LOCAL_REPOSITORY"
fi
if [[ ! "$REPOSITORY" =~ ^[^/]+/[^/]+$ ]]; then
    echo "ERROR: repository must be in owner/name form: $REPOSITORY" >&2
    exit 1
fi
if [[ "$LOCAL_REPOSITORY" != "$REPOSITORY" ]]; then
    echo "ERROR: local origin is $LOCAL_REPOSITORY, not $REPOSITORY" >&2
    exit 1
fi

TAG="v$VERSION"

release_id() {
    gh api "repos/$REPOSITORY/releases" \
        --jq "map(select(.tag_name == \"$TAG\" and .draft == true))[0].id // empty"
}

verify_assets() {
    local id="$1" expected_appstore="${2:-}" expected_standalone="${3:-}"
    local appstore_count standalone_count appstore_digest standalone_digest
    appstore_count="$(gh api "repos/$REPOSITORY/releases/$id" \
        --jq '[.assets[] | select(.name == "GhosttyKitAppStore.xcframework.zip")] | length')"
    standalone_count="$(gh api "repos/$REPOSITORY/releases/$id" \
        --jq '[.assets[] | select(.name == "GhosttyKitStandalone.xcframework.zip")] | length')"
    if [[ "$appstore_count" != 1 || "$standalone_count" != 1 ]]; then
        echo "ERROR: expected release assets were not uploaded exactly once" >&2
        exit 1
    fi
    if [[ -n "$expected_appstore" && -n "$expected_standalone" ]]; then
        appstore_digest="$(gh api "repos/$REPOSITORY/releases/$id" \
            --jq '.assets[] | select(.name == "GhosttyKitAppStore.xcframework.zip") | .digest')"
        standalone_digest="$(gh api "repos/$REPOSITORY/releases/$id" \
            --jq '.assets[] | select(.name == "GhosttyKitStandalone.xcframework.zip") | .digest')"
        if [[ "$appstore_digest" != "sha256:$expected_appstore" ||
              "$standalone_digest" != "sha256:$expected_standalone" ]]; then
            echo "ERROR: draft asset digests do not match reviewed package checksums" >&2
            exit 1
        fi
    fi
}

manifest_checksum() {
    local asset="$1"
    awk -v asset="$asset" '
        index($0, asset) { found = 1 }
        found && /checksum:/ {
            line = $0
            sub(/^.*checksum: "/, "", line)
            sub(/".*$/, "", line)
            print line
            exit
        }
    ' "$PACKAGE_DIR/Package.swift"
}

manifest_url_count() {
    local url="$1"
    awk -v url="$url" 'index($0, url) { count += 1 } END { print count + 0 }' \
        "$PACKAGE_DIR/Package.swift"
}

if [[ "$MODE" == prepare ]]; then
    if [[ -n "$(git -C "$PACKAGE_DIR" status --porcelain)" ]]; then
        echo "ERROR: package repository must be clean before preparing a release" >&2
        exit 1
    fi
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
    GHOSTTY_SHORT_REVISION="$(git -C "$GHOSTTY_SOURCE" rev-parse --short HEAD)"
    if [[ "$APPSTORE_ID" != "$GHOSTTY_SHORT_REVISION-"* ||
          "$STANDALONE_ID" != "$GHOSTTY_SHORT_REVISION-"* ]]; then
        echo "ERROR: selected artifacts were not both built from Ghostty $GHOSTTY_SHORT_REVISION" >&2
        exit 1
    fi
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
    verify_assets "$RELEASE_ID" "$APPSTORE_CHECKSUM" "$STANDALONE_CHECKSUM"

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
APPSTORE_URL="https://github.com/$REPOSITORY/releases/download/$TAG/GhosttyKitAppStore.xcframework.zip"
STANDALONE_URL="https://github.com/$REPOSITORY/releases/download/$TAG/GhosttyKitStandalone.xcframework.zip"
if [[ "$(manifest_url_count "$APPSTORE_URL")" != 1 ||
      "$(manifest_url_count "$STANDALONE_URL")" != 1 ]]; then
    echo "ERROR: Package.swift must reference each expected $REPOSITORY $TAG asset exactly once" >&2
    exit 1
fi

RELEASE_ID="$(release_id)"
if [[ -z "$RELEASE_ID" ]]; then
    echo "ERROR: no draft release found for $TAG" >&2
    exit 1
fi
APPSTORE_CHECKSUM="$(manifest_checksum GhosttyKitAppStore.xcframework.zip)"
STANDALONE_CHECKSUM="$(manifest_checksum GhosttyKitStandalone.xcframework.zip)"
if [[ ! "$APPSTORE_CHECKSUM" =~ ^[0-9a-f]{64}$ ||
      ! "$STANDALONE_CHECKSUM" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: could not read both SHA-256 checksums from Package.swift" >&2
    exit 1
fi
verify_assets "$RELEASE_ID" "$APPSTORE_CHECKSUM" "$STANDALONE_CHECKSUM"

HEAD_REVISION="$(git -C "$PACKAGE_DIR" rev-parse HEAD)"
if git -C "$PACKAGE_DIR" rev-parse "$TAG" >/dev/null 2>&1; then
    if [[ "$(git -C "$PACKAGE_DIR" rev-parse "$TAG^{commit}")" != "$HEAD_REVISION" ]]; then
        echo "ERROR: local $TAG does not point to reviewed commit $HEAD_REVISION" >&2
        exit 1
    fi
else
    git -C "$PACKAGE_DIR" tag "$TAG"
fi
REMOTE_TAG="$(git -C "$PACKAGE_DIR" ls-remote --tags origin "refs/tags/$TAG" | awk '{print $1}')"
if [[ -n "$REMOTE_TAG" && "$REMOTE_TAG" != "$HEAD_REVISION" ]]; then
    echo "ERROR: remote $TAG does not point to reviewed commit $HEAD_REVISION" >&2
    exit 1
fi
if [[ -z "$REMOTE_TAG" ]]; then
    git -C "$PACKAGE_DIR" push origin "$TAG"
fi
gh release edit "$TAG" --repo "$REPOSITORY" --draft=false
echo "Published GhosttyKit $VERSION from reviewed commit $HEAD_REVISION"
