# HarmonyOS / OpenHarmony support

This fork adds HarmonyOS and OpenHarmony support to `dotnet-install.sh`.
Upstream is in maintenance mode, so the changes are kept small and opt-in;
everything that only affects the Microsoft-published RIDs is unchanged.

## Platform facts this port relies on

| Item | Value |
|---|---|
| `uname -s` | `HarmonyOS` (OpenHarmony standard systems may report `Linux`) |
| `uname -m` | `aarch64` |
| RID | `openharmony-arm64` |
| `/etc/os-release` | may be missing; detection falls back to `uname` |
| `/bin/sh` | mksh; bash is not on `PATH` by default |
| `/tmp` | read-only inside the application sandbox |
| ELF execution | HarmonyOS (commercial) requires a `.codesign` section |

## Usage

HarmonyOS does not ship bash, so use the wrapper. It locates bash (for example
the one installed by harmonybrew), prepares a writable `TMPDIR`, and delegates
to `dotnet-install.sh`:

```sh
# Feed-based install (a static feed that follows the layout below)
sh src/dotnet-install-ohos.sh --version 11.0.100 --feed https://example.invalid/dotnet-feed

# Direct URL install (requires --sha256 on openharmony)
sh src/dotnet-install-ohos.sh \
  --url https://example.invalid/dotnet-sdk-11.0.100-openharmony-arm64.tar.gz \
  --sha256 <hex> \
  --version 11.0.100
```

`dotnet-install.sh` can also be invoked directly when bash is available:

```sh
bash src/dotnet-install.sh --os openharmony --arch arm64 --version 11.0.100 --feed <feed>
```

### Feed layout

The regular feed logic expects the same layout that Microsoft uses:

```
<Sdk|Runtime|aspnetcore/Runtime>/<version>/dotnet-sdk-<productVersion>-openharmony-arm64.tar.gz
<Sdk|Runtime|aspnetcore/Runtime>/<version>/productVersion.txt
<Sdk|Runtime|aspnetcore/Runtime>/<channel>/latest.version
```

`productVersion.txt` is optional; when it is missing the product version is
parsed from the archive file name.

## Options added by this fork

| Option | Purpose |
|---|---|
| `--os openharmony` (`harmonyos`, `ohos` aliases) | Force the openharmony RID. |
| `--feed <url>` | Alias for `--azure-feed`. |
| `--url <url>` | Install directly from an archive; skips feed and aka.ms resolution. |
| `--sha256 <hex>` | Verify the downloaded archive. Required for `--url` unless `--allow-unverified` is set. |
| `--sign auto\|none\|tool` | Sign installed ELF files. `auto` signs only on HarmonyOS when a tool is found. |
| `--workload-bundle <path\|url>` | Run the OpenHarmony workload bundle installer after dotnet is installed. |
| `--persist-env` | Append `DOTNET_ROOT` and `PATH` to `~/.profile` and `~/.bashrc`. |
| `--allow-unverified` | Allow `--url` installs without a checksum (insecure). |

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `TMPDIR` | `${TMPDIR:-/tmp}`, falling back to `$HOME/.tmp` when not writable | Temporary downloads and extraction. |
| `DOTNET_INSTALL_BASH` | auto-detected | Bash used by `dotnet-install-ohos.sh`. |
| `DOTNET_INSTALL_GITHUB_PROXY` | `https://gh-proxy.com` in the wrapper | Mirror tried first for `https://github.com/...` archives. Set to empty to disable. |
| `DOTNET_ROOT` | install dir on openharmony | Exported after a successful install. |

## ELF code signing

Commercial HarmonyOS refuses to execute ELF binaries that do not carry a
`.codesign` section. `--sign auto` (the default) signs every ELF file under the
install directory when all of these are true:

- `uname` reports `HarmonyOS`;
- a signing tool is found.

Tool discovery order:

1. `<install-dir>/selfsign`
2. `selfsign` on `PATH`
3. `binary-sign-tool` on `PATH`
4. `binary-sign-tool` under `~/.harmonybrew`

`--sign none` disables signing (for example on OpenHarmony, which ignores
`.codesign`). `--sign tool` fails the install when no tool is available and
re-signs every ELF, including files that already carry a signature.

In `auto` mode, files that already carry a `.codesign` section (detected with
`readelf`) are left untouched, because the release archives are usually
pre-signed; re-signing thousands of files is slow.

## Sandbox notes

- `/tmp` is mounted `noexec` on HarmonyOS devices: an installed `dotnet` host
  there fails with `Operation not permitted` even when correctly signed. Install
  into `$HOME` (the default) and keep `/tmp` only for transient files.
- `/tmp`, `DOTNET_CLI_HOME`, `NUGET_PACKAGES` and MSBuild server sockets are
  restricted inside the application sandbox. Prefer `$HOME` paths and set
  `TMPDIR` explicitly; `dotnet-install.sh` falls back to `$HOME/.tmp`.
- The installer sets `DOTNET_ROOT`, but a new shell does not inherit it. Use
  `--persist-env` or export it from the app's environment.

## Workload

The platform workload (`Microsoft.OpenHarmony.Sdk/Ref/Runtime` packs) ships as a
separate bundle:

```sh
sh src/dotnet-install-ohos.sh --version 11.0.100 --feed <feed> \
  --workload-bundle /path/to/openharmony-workload-<version>.tar.gz
```

The bundle must contain `install-ohos-workload.sh`; the installer runs it with
`DOTNET_ROOT` and `DOTNET_INSTALL_DIR` pointing at the new installation.

## Tests

```sh
# Fast, no device or network required
bash tests/ohos/test-openharmony.sh

# xunit coverage (Unix only)
dotnet test tests/Install-Scripts.Test --filter FullyQualifiedName~HarmonyOsInstallScriptTests
```

The shell suite covers OS detection, `--os` aliases, direct URL installs,
idempotency, SHA-256 enforcement, `--allow-unverified`, `--sign` validation and
the `TMPDIR` fallback.

## Relationship to the sdk-ohos installer

`sdk-ohos/eng/ohos-install/install-dotnet-ohos.sh` is the device installer: it
carries version pins, the workload bundle, profile persistence and the same
signing flow. This fork keeps `dotnet-install.sh` upstream-shaped so it can be
used from CI and cross-build hosts, where code signing is not required.
