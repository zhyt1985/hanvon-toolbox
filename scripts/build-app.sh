#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
build_dir="$project_dir/.build"
mkdir -p "$build_dir"/{clang-cache,swiftpm-cache,swiftpm-config,swiftpm-security}
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"

swift_flags=(
    --disable-sandbox
    --cache-path "$build_dir/swiftpm-cache"
    --config-path "$build_dir/swiftpm-config"
    --security-path "$build_dir/swiftpm-security"
)
swift build "${swift_flags[@]}"
binary_dir="$(swift build "${swift_flags[@]}" --show-bin-path)"

app="$build_dir/HanvonToolbox.app"
signing_identity="${HANVON_CODESIGN_IDENTITY:-}"
signing_options=()
signing_state="$project_dir/.mac-signing"
parent_requirement=""
if [[ -z "$signing_identity" && -f "$signing_state/fingerprint" ]]; then
    signing_identity="$(cat "$signing_state/fingerprint")"
    if [[ ! "$signing_identity" =~ ^[[:xdigit:]]{40}$ ]]; then
        printf '本机签名证书指纹无效，请检查 .mac-signing/fingerprint。\n' >&2
        exit 1
    fi
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$project_dir/scripts/Info.plist")"
    parent_requirement="identifier \"$bundle_id\" and certificate leaf = H\"$signing_identity\""
    signing_options=(--options runtime --timestamp=none -r "=designated => $parent_requirement")
elif [[ -z "$signing_identity" ]]; then
    signing_identity=-
    printf '使用临时签名。要保留构建间的钥匙串授权，请先运行 scripts/setup-local-signing.sh。\n' >&2
fi

stage="$(mktemp -d "$build_dir/app-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
staged_app="$stage/HanvonToolbox.app"
contents="$staged_app/Contents"
mkdir -p "$contents/MacOS"
cp "$project_dir/scripts/Info.plist" "$contents/Info.plist"
cp "$binary_dir/HanvonToolbox" "$contents/MacOS/HanvonToolbox"

if [[ -n "$parent_requirement" ]]; then
    helper_main="$project_dir/scripts/PairingKeychainHelper.swift"
    keychain_code="$project_dir/Sources/HanvonToolbox/KeychainStore.swift"
    helper_hash="$({ cat "$helper_main" "$keychain_code"; printf '%s\n' "$parent_requirement"; } | shasum -a 256 | cut -d' ' -f1)"
    helper="$signing_state/HanvonPairingKeychain-$helper_hash"
    helper_requirement="identifier \"$bundle_id.pairing-keychain\" and certificate leaf = H\"$signing_identity\""
    if [[ ! -f "$helper" ]]; then
        printf 'let pairingParentRequirement = #"%s"#\n' "$parent_requirement" > "$stage/ParentRequirement.swift"
        xcrun swiftc -O -parse-as-library "$helper_main" "$keychain_code" "$stage/ParentRequirement.swift" \
            -o "$stage/HanvonPairingKeychain"
        codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
            -i "$bundle_id.pairing-keychain" -r "=designated => $helper_requirement" "$stage/HanvonPairingKeychain"
        mv "$stage/HanvonPairingKeychain" "$helper"
    fi
    codesign --verify --strict -R "=$helper_requirement" "$helper"
    mkdir -p "$contents/Helpers"
    cp "$helper" "$contents/Helpers/HanvonPairingKeychain"
    /usr/libexec/PlistBuddy -c 'Add HanvonUsesPairingKeychainHelper bool true' "$contents/Info.plist"
fi

# Bash 3.2 treats empty arrays as unset with nounset enabled.
codesign --force --sign "$signing_identity" ${signing_options[@]+"${signing_options[@]}"} "$staged_app"
codesign --verify --deep --strict "$staged_app"

if [[ -e "$app" ]]; then mv "$app" "$stage/previous.app"; fi
if ! mv "$staged_app" "$app"; then
    if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$app"; fi
    exit 1
fi
printf '\n%s\n' "$app"
