#!/bin/sh
# Copyright (c) .NET Foundation and contributors. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Thin wrapper that installs the OpenHarmony SDK pinned in a sdk-ohos
# `versions.env`, using the shared dotnet-install.sh instead of a bespoke
# downloader.
#
# It reads the same pins the sdk-ohos installer uses:
#   GH_USER, SDK_VERSION, RID, SDK_TARBALL_SHA256
# and forwards everything else to dotnet-install-ohos.sh.
#
# Usage:
#   sh src/ohos-install-from-pins.sh [--versions <versions.env>] [dotnet-install options]
#
# Environment:
#   INSTALL_DIR          install root (default: $HOME/.dotnet)
#   SDK_TARBALL_URL      override the release URL (file:// or https://)
#   SDK_TARBALL_SHA256   pinned digest (required unless ALLOW_UNVERIFIED=1)
#   WORKLOAD_BUNDLE      optional workload bundle path or URL
#   INSTALL_WORKLOAD=0   skip the workload even when WORKLOAD_BUNDLE is set
#   PERSIST_ENV=0        do not write DOTNET_ROOT/PATH to the shell profiles
#   ALLOW_UNVERIFIED=1   pass --allow-unverified (insecure; local experiments only)
#
# The sdk-ohos installer remains the full device installer until the workload
# release resolution moves here; this wrapper covers the SDK/runtime path that
# both installers share.

set -u

script_dir=$(cd "$(dirname "$0")" && pwd)
versions_file=""
forward_args=""

while [ $# -gt 0 ]; do
    case "$1" in
        --versions)
            shift
            versions_file="$1"
            ;;
        *)
            # Keep the remaining options for dotnet-install.
            forward_args="$forward_args $1"
            ;;
    esac
    shift
done

if [ -z "$versions_file" ]; then
    for candidate in \
        "$PWD/versions.env" \
        "$PWD/eng/ohos-install/versions.env" \
        "$script_dir/../eng/ohos-install/versions.env"; do
        if [ -f "$candidate" ]; then
            versions_file="$candidate"
            break
        fi
    done
fi

if [ -n "$versions_file" ]; then
    [ -f "$versions_file" ] || { printf 'ERROR: versions file not found: %s\n' "$versions_file" >&2; exit 1; }
    # versions.env uses ${VAR:=default}, so exported values still win.
    # shellcheck disable=SC1090
    . "$versions_file"
fi

sdk_version="${SDK_VERSION:-}"
rid="${RID:-openharmony-arm64}"
gh_user="${GH_USER:-springmin}"
install_dir="${INSTALL_DIR:-$HOME/.dotnet}"
sha="${SDK_TARBALL_SHA256:-}"
url="${SDK_TARBALL_URL:-}"

if [ -z "$sdk_version" ]; then
    printf 'ERROR: SDK_VERSION is not set (pass --versions <versions.env> or export it).\n' >&2
    exit 1
fi

if [ -z "$url" ]; then
    url="https://github.com/${gh_user}/sdk-ohos/releases/download/v${sdk_version}-ohos/dotnet-sdk-${sdk_version}-${rid}.tar.gz"
fi

if [ -z "$sha" ] && [ "${ALLOW_UNVERIFIED:-0}" != "1" ]; then
    printf 'ERROR: SDK_TARBALL_SHA256 is not set; refusing an unverified install.\n' >&2
    printf '       Pass ALLOW_UNVERIFIED=1 only for local experiments.\n' >&2
    exit 1
fi

set -- --url "$url" --version "$sdk_version" --install-dir "$install_dir" --sign "${SIGN_MODE:-auto}"

if [ -n "$sha" ]; then
    set -- "$@" --sha256 "$sha"
fi
if [ "${ALLOW_UNVERIFIED:-0}" = "1" ]; then
    set -- "$@" --allow-unverified
fi
if [ "${PERSIST_ENV:-1}" = "1" ]; then
    set -- "$@" --persist-env
fi
if [ -n "${WORKLOAD_BUNDLE:-}" ] && [ "${INSTALL_WORKLOAD:-1}" != "0" ]; then
    set -- "$@" --workload-bundle "$WORKLOAD_BUNDLE"
fi

# shellcheck disable=SC2086
exec sh "$script_dir/dotnet-install-ohos.sh" "$@" $forward_args
