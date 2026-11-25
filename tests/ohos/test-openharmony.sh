#!/usr/bin/env bash
# Copyright (c) .NET Foundation and contributors. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# HarmonyOS/OpenHarmony support tests for dotnet-install.sh.
#
# These tests do not need a device or network access: they use a fake `uname`,
# a file:// feed and a synthetic SDK tarball.
#
# Usage: bash tests/ohos/test-openharmony.sh

set -u

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$repo_root/src/dotnet-install.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/dotnet-ohos-tests.XXXXXXXXX")"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        openssl dgst -sha256 "$1" | sed 's/.*[ =]//'
    fi
}

run_install() {
    # Runs dotnet-install.sh with a fake HarmonyOS uname on PATH.
    PATH="$work/shim:$PATH" bash "$script" "$@"
}

make_uname_shim() {
    mkdir -p "$work/shim"
    cat > "$work/shim/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -m) echo aarch64 ;;
  -s) echo HarmonyOS ;;
  *)  echo HarmonyOS ;;
esac
EOF
    chmod +x "$work/shim/uname"
}

make_feed() {
    mkdir -p "$work/feed/Sdk/11.0.100"
    printf '11.0.100\n' > "$work/feed/Sdk/11.0.100/productVersion.txt"
}

make_tarball() {
    mkdir -p "$work/tarroot/sdk/11.0.100"
    printf '11.0.100\n' > "$work/tarroot/sdk/11.0.100/.version"
    printf 'fake payload\n' > "$work/tarroot/sdk/11.0.100/fake.txt"
    tar -czf "$work/dotnet-sdk-11.0.100-openharmony-arm64.tar.gz" -C "$work/tarroot" .
    sha256_of "$work/dotnet-sdk-11.0.100-openharmony-arm64.tar.gz"
}

make_uname_shim
make_feed
tarball_sha="$(make_tarball)"
tarball="file://$work/dotnet-sdk-11.0.100-openharmony-arm64.tar.gz"

# 1. HarmonyOS uname is detected as the openharmony RID.
if output="$(run_install --dry-run --version 11.0.100 --feed "file://$work/feed" --install-dir "$work/inst-detect" 2>&1)"; then
    if printf '%s' "$output" | grep -q 'dotnet-sdk-11\.0\.100-openharmony-arm64\.tar\.gz'; then
        ok "HarmonyOS uname resolves to openharmony-arm64"
    else
        bad "unexpected dry-run output: $output"
    fi
else
    bad "dry-run failed: $output"
fi

# 2. --os accepts the harmonyos/ohos aliases.
for alias in harmonyos ohos openharmony; do
    if output="$(run_install --dry-run --version 11.0.100 --os "$alias" --feed "file://$work/feed" --install-dir "$work/inst-os-$alias" 2>&1)"; then
        if printf '%s' "$output" | grep -q 'openharmony-arm64'; then
            ok "--os $alias maps to openharmony"
        else
            bad "--os $alias produced: $output"
        fi
    else
        bad "--os $alias failed: $output"
    fi
done

# 3. Direct URL install with a matching SHA-256.
if output="$(run_install --url "$tarball" --sha256 "$tarball_sha" --version 11.0.100 \
        --install-dir "$work/inst-direct" --sign none --no-path 2>&1)"; then
    if [ -f "$work/inst-direct/sdk/11.0.100/.version" ]; then
        ok "direct URL install extracts the SDK layout"
    else
        bad "direct URL install did not extract sdk/11.0.100"
    fi
else
    bad "direct URL install failed: $output"
fi

# 4. Re-running the same install is idempotent.
if output="$(run_install --url "$tarball" --sha256 "$tarball_sha" --version 11.0.100 \
        --install-dir "$work/inst-direct" --sign none --no-path 2>&1)"; then
    if printf '%s' "$output" | grep -q 'already installed'; then
        ok "second install is a no-op"
    else
        bad "second install did not report an existing installation: $output"
    fi
else
    bad "second install failed: $output"
fi

# 5. A SHA-256 mismatch aborts before extraction.
if output="$(run_install --url "$tarball" --sha256 "0000000000000000000000000000000000000000000000000000000000000000" \
        --version 11.0.100 --install-dir "$work/inst-badsha" --sign none --no-path 2>&1)"; then
    bad "install with a wrong SHA-256 unexpectedly succeeded"
else
    if printf '%s' "$output" | grep -q 'SHA-256 mismatch'; then
        ok "SHA-256 mismatch is refused"
    else
        bad "unexpected failure output: $output"
    fi
fi

# 6. --url without --sha256 is refused on openharmony.
if output="$(run_install --url "$tarball" --version 11.0.100 \
        --install-dir "$work/inst-nosha" --sign none --no-path 2>&1)"; then
    bad "--url without --sha256 unexpectedly succeeded"
else
    if printf '%s' "$output" | grep -q 'without --sha256'; then
        ok "--url without --sha256 is refused"
    else
        bad "unexpected failure output: $output"
    fi
fi

# 7. --allow-unverified permits an unverified direct install.
if output="$(run_install --url "$tarball" --version 11.0.100 --allow-unverified \
        --install-dir "$work/inst-unverified" --sign none --no-path 2>&1)"; then
    ok "--allow-unverified permits an unverified install"
else
    bad "--allow-unverified install failed: $output"
fi

# 8. Invalid --sign values are rejected.
if output="$(run_install --dry-run --version 11.0.100 --sign bogus --install-dir "$work/inst-sign" 2>&1)"; then
    bad "invalid --sign value unexpectedly succeeded"
else
    if printf '%s' "$output" | grep -q 'Unsupported value for --sign'; then
        ok "invalid --sign value is rejected"
    else
        bad "unexpected failure output: $output"
    fi
fi

# 9. An unwritable TMPDIR falls back to $HOME/.tmp instead of failing.
if output="$(TMPDIR="$work/does-not-exist" HOME="$work/home" run_install --dry-run --version 11.0.100 \
        --feed "file://$work/feed" --install-dir "$work/inst-tmp" 2>&1)"; then
    if [ -d "$work/home/.tmp" ]; then
        ok "unwritable TMPDIR falls back to HOME/.tmp"
    else
        bad "TMPDIR fallback did not create HOME/.tmp"
    fi
else
    bad "TMPDIR fallback run failed: $output"
fi

# 10. Prerelease asset names keep the full product version.
mkdir -p "$work/tarroot-pre/sdk/11.0.100-rc.1.99999.1"
printf '11.0.100-rc.1.99999.1\n' > "$work/tarroot-pre/sdk/11.0.100-rc.1.99999.1/.version"
tar -czf "$work/dotnet-sdk-11.0.100-rc.1.99999.1-ohos-arm64-realrt.tar.gz" -C "$work/tarroot-pre" .
pre_sha="$(sha256_of "$work/dotnet-sdk-11.0.100-rc.1.99999.1-ohos-arm64-realrt.tar.gz")"
if output="$(run_install --url "file://$work/dotnet-sdk-11.0.100-rc.1.99999.1-ohos-arm64-realrt.tar.gz" \
        --sha256 "$pre_sha" --version 11.0.100-rc.1.99999.1 \
        --install-dir "$work/inst-pre" --sign none --no-path 2>&1)"; then
    if [ -d "$work/inst-pre/sdk/11.0.100-rc.1.99999.1" ]; then
        ok "prerelease asset names keep the full product version"
    else
        bad "prerelease install landed in the wrong directory"
    fi
else
    bad "prerelease install failed: $output"
fi

# 11. --workload-bundle runs the bundle installer with DOTNET_ROOT set.
mkdir -p "$work/wl"
cat > "$work/wl/install-ohos-workload.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "${DOTNET_ROOT:-}" > "$(dirname "$0")/root.txt"
EOF
chmod +x "$work/wl/install-ohos-workload.sh"
if output="$(run_install --url "$tarball" --sha256 "$tarball_sha" --version 11.0.100 \
        --install-dir "$work/inst-wl" --sign none --no-path --workload-bundle "$work/wl" 2>&1)"; then
    if [ -f "$work/wl/root.txt" ] && grep -qx "$work/inst-wl" "$work/wl/root.txt"; then
        ok "--workload-bundle runs the bundle with DOTNET_ROOT"
    else
        bad "workload bundle did not receive DOTNET_ROOT"
    fi
else
    bad "workload bundle install failed: $output"
fi

# 12. --persist-env appends DOTNET_ROOT and PATH to the profile.
mkdir -p "$work/persist-home"
touch "$work/persist-home/.profile"
if output="$(HOME="$work/persist-home" run_install --url "$tarball" --sha256 "$tarball_sha" \
        --version 11.0.100 --install-dir "$work/inst-persist" --sign none --no-path \
        --persist-env 2>&1)"; then
    if grep -q "DOTNET_ROOT=\"$work/inst-persist\"" "$work/persist-home/.profile"; then
        ok "--persist-env writes DOTNET_ROOT to the profile"
    else
        bad "--persist-env did not update the profile"
    fi
else
    bad "--persist-env install failed: $output"
fi

# 13. Feed-based install resolves the openharmony asset from the feed.
mkdir -p "$work/feed2/Sdk/11.0.100"
printf '11.0.100\n' > "$work/feed2/Sdk/11.0.100/productVersion.txt"
cp "$work/dotnet-sdk-11.0.100-openharmony-arm64.tar.gz" "$work/feed2/Sdk/11.0.100/"
if output="$(run_install --version 11.0.100 --feed "file://$work/feed2" \
        --install-dir "$work/inst-feed" --sign none --no-path 2>&1)"; then
    if [ -d "$work/inst-feed/sdk/11.0.100" ]; then
        ok "feed install resolves the openharmony asset"
    else
        bad "feed install did not extract sdk/11.0.100"
    fi
else
    bad "feed install failed: $output"
fi

# 14. Channel resolution reads <feed>/Sdk/<channel>/latest.version.
mkdir -p "$work/feed2/Sdk/LTS"
printf '11.0.100\n' > "$work/feed2/Sdk/LTS/latest.version"
if output="$(run_install --channel LTS --feed "file://$work/feed2" \
        --install-dir "$work/inst-channel" --sign none --no-path 2>&1)"; then
    if [ -d "$work/inst-channel/sdk/11.0.100" ]; then
        ok "channel LTS resolves through latest.version"
    else
        bad "channel install did not extract sdk/11.0.100"
    fi
else
    bad "channel install failed: $output"
fi

# 15. The versions.env wrapper installs the pinned SDK with the shared installer.
mkdir -p "$work/pins"
cat > "$work/pins/versions.env" <<EOF
: "\${SDK_VERSION:=11.0.100}"
: "\${RID:=openharmony-arm64}"
: "\${GH_USER:=springmin}"
: "\${SDK_TARBALL_SHA256:=$tarball_sha}"
EOF
if output="$(PATH="$work/shim:$PATH" SDK_TARBALL_URL="file://$work/dotnet-sdk-11.0.100-openharmony-arm64.tar.gz" \
        INSTALL_DIR="$work/inst-pins" PERSIST_ENV=0 \
        sh "$repo_root/src/ohos-install-from-pins.sh" --versions "$work/pins/versions.env" --sign none 2>&1)"; then
    if [ -d "$work/inst-pins/sdk/11.0.100" ]; then
        ok "versions.env wrapper installs the pinned SDK"
    else
        bad "versions.env wrapper did not extract sdk/11.0.100"
    fi
else
    bad "versions.env wrapper failed: $output"
fi

# 16. The versions.env wrapper refuses an install without a pinned digest.
cat > "$work/pins/versions-nosha.env" <<'EOF'
: "${SDK_VERSION:=11.0.100}"
: "${RID:=openharmony-arm64}"
: "${GH_USER:=springmin}"
EOF
if output="$(PATH="$work/shim:$PATH" SDK_TARBALL_URL="file://$work/dotnet-sdk-11.0.100-openharmony-arm64.tar.gz" \
        INSTALL_DIR="$work/inst-pins-nosha" PERSIST_ENV=0 \
        sh "$repo_root/src/ohos-install-from-pins.sh" --versions "$work/pins/versions-nosha.env" --sign none 2>&1)"; then
    bad "versions.env wrapper without a digest unexpectedly succeeded"
else
    if printf '%s' "$output" | grep -q 'SDK_TARBALL_SHA256 is not set'; then
        ok "versions.env wrapper refuses an unpinned install"
    else
        bad "unexpected failure output: $output"
    fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
