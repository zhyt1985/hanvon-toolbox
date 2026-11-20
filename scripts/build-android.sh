#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
java_home="${JAVA_HOME:-$(/usr/libexec/java_home -v 17)}"
export JAVA_HOME="$java_home"
tools="$sdk/build-tools/34.0.0"
platform="$sdk/platforms/android-34/android.jar"
out="$project_dir/.build/android"
signing="$project_dir/.android-signing"
umask 077
mkdir -p "$out" "$signing"
work="$(mktemp -d "$out/work.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir "$work/classes" "$work/dex"
# Reuse the existing identity. Never silently generate a replacement release key.
if [[ ! -f "$signing/companion.p12" ]]; then
    printf '缺少 Android 签名密钥，请恢复原身份；不会自动生成替代密钥。\n' >&2
    exit 1
fi
password_file="${HANVON_ANDROID_PASSWORD_FILE:-$signing/password}"
if [[ -n "${HANVON_ANDROID_KEYSTORE_PASSWORD:-}" ]]; then
    password_args=(--ks-pass env:HANVON_ANDROID_KEYSTORE_PASSWORD)
elif [[ -f "$password_file" ]]; then
    password_args=(--ks-pass "file:$password_file")
else
    printf '请设置 HANVON_ANDROID_KEYSTORE_PASSWORD 或被忽略的本地口令文件。\n' >&2
    exit 1
fi

"$java_home/bin/javac" --release 8 -encoding UTF-8 -cp "$platform" \
    -d "$work/classes" android/src/local/hanvon/companion/*.java
jar cf "$work/classes.jar" -C "$work/classes" .
"$tools/d8" --min-api 30 --lib "$platform" --output "$work/dex" "$work/classes.jar"
"$tools/aapt2" link -I "$platform" --manifest android/AndroidManifest.xml -o "$work/unsigned.apk"
(cd "$work/dex" && zip -q -0 "$work/unsigned.apk" classes.dex)
"$tools/zipalign" -f 4 "$work/unsigned.apk" "$work/aligned.apk"
version="$("$tools/aapt2" dump badging "$work/aligned.apk" | awk -F "'" '/^package:/ {print $6}')"
test -n "$version"
apk="$out/Hanvon-Companion-$version.apk"
"$tools/apksigner" sign --ks "$signing/companion.p12" "${password_args[@]}" --out "$apk" "$work/aligned.apk"
"$tools/apksigner" verify "$apk"
printf '%s\n' "$apk"
