#!/bin/bash
set -euo pipefail
umask 077

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
signing_state="$project_dir/.mac-signing"
identity_file="$signing_state/fingerprint"
name="Hanvon Toolbox Local Code Signing"
login_keychain="$(/usr/bin/security login-keychain -d user 2>/dev/null || true)"
if [[ -z "$login_keychain" ]]; then
    login_keychain="$(/usr/bin/security default-keychain -d user)"
fi
login_keychain="$(sed -E 's/^[[:space:]]*"([^"]+)"[[:space:]]*$/\1/' <<<"$login_keychain")"
if [[ ! -f "$login_keychain" ]]; then
    printf '无法找到当前用户的钥匙串。\n' >&2
    exit 1
fi

identities="$(/usr/bin/security find-identity -p codesigning "$login_keychain")"
fingerprint="$(awk -v name="$name" 'index($0, "\"" name "\"") && length($2) == 40 { print $2 }' <<<"$identities" | sort -u)"
if [[ -z "$fingerprint" ]]; then
    if [[ -e "$identity_file" ]]; then
        printf '找不到已配置的签名身份。请先恢复钥匙串中的原身份。\n' >&2
        exit 1
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/hanvon-signing.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    cat > "$work/certificate.cnf" <<'EOF'
[req]
distinguished_name = subject
prompt = no
x509_extensions = signing
[subject]
CN = Hanvon Toolbox Local Code Signing
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
EOF
    /usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -days 3650 \
        -config "$work/certificate.cnf" -keyout "$work/private.pem" -out "$work/certificate.pem" 2>"$work/openssl.log" || {
        cat "$work/openssl.log" >&2
        exit 1
    }
    wrapping_pass="$(/usr/bin/openssl rand -hex 32)"
    HANVON_P12_PASSWORD="$wrapping_pass" /usr/bin/openssl pkcs12 -export -certpbe PBE-SHA1-3DES \
        -inkey "$work/private.pem" -in "$work/certificate.pem" -name "$name" \
        -out "$work/identity.p12" -passout env:HANVON_P12_PASSWORD
    /usr/bin/security import "$work/identity.p12" -k "$login_keychain" -f pkcs12 -x \
        -P "$wrapping_pass" -T /usr/bin/codesign
    unset wrapping_pass
    fingerprint="$(/usr/bin/openssl x509 -in "$work/certificate.pem" -noout -sha1 -fingerprint |
        cut -d= -f2 | tr -d ':')"
fi
if [[ ! "$fingerprint" =~ ^[[:xdigit:]]{40}$ ]]; then
    printf '无法唯一确认 Hanvon Toolbox 本机签名身份。\n' >&2
    exit 1
fi
if [[ -f "$identity_file" && "$(cat "$identity_file")" != "$fingerprint" ]]; then
    printf '现有配置使用另一签名证书，请确认原身份后再构建。\n' >&2
    exit 1
fi
mkdir -p "$signing_state"
printf '%s\n' "$fingerprint" > "$identity_file"
printf '已配置 Hanvon Toolbox 本机签名。\n'
