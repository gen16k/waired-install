# waired-install

Public distribution point for **Waired**'s install / uninstall
entrypoints and the Windows / macOS binary artifacts. The scripts are
developed in the upstream Waired repository and published here as
**release assets** — run them straight from the
`releases/latest/download/…` URLs below. This repository itself carries
only this README and the license, not the script sources.

* `install.sh` / `uninstall.sh` — Linux (Debian / Ubuntu apt) and macOS 13+ (arm64/amd64).
* `install.ps1` / `uninstall.ps1` — Windows 10 1809+ / 11 (PowerShell 5.1+).

## Quick install

Linux:

```sh
curl -fsSL https://github.com/gen16k/waired-install/releases/latest/download/install.sh | sh
```

macOS (run as your normal login user — `sudo` is invoked only for the
`/usr/local/bin` copy; do not run the whole script under `sudo`):

```sh
curl -fsSL https://github.com/gen16k/waired-install/releases/latest/download/install.sh | sh
```

Windows (run in a regular, non-elevated PowerShell — the script
self-elevates via UAC at the moment it needs admin):

```powershell
iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/install.ps1 | iex
```

What each does:

* **Linux** — detects distribution and CPU architecture
  (Debian / Ubuntu, amd64 / arm64), adds the Waired apt repository
  (hosted on Google Artifact Registry) and its Google-managed signing
  key, then `apt install`s the `waired` package (CLI + agent daemon)
  and, by default, `waired-tray` (desktop tray UI).
* **macOS** — downloads `waired-darwin-<arch>.tar.gz` + `.sha256` from
  this same release, verifies the SHA-256, installs `waired` +
  `waired-agent` into `/usr/local/bin`, installs **Ollama** (reuses an
  existing install, otherwise downloads the official `Ollama.app` into
  `/Applications` — no Homebrew required), and registers a per-user
  launchd LaunchAgent (`com.waired.agent`) via `waired-agent install`.
  The binaries are unsigned (ad-hoc); `curl`-downloaded executables
  carry no Gatekeeper quarantine, so they run without a right-click
  gesture. Set `WAIRED_NO_OLLAMA=1` to skip the Ollama install.
* **Windows** — verifies the host is Windows 10 1809+ / amd64,
  downloads `waired-windows-amd64.zip` + `.sha256` from this same
  release, verifies the SHA-256, self-elevates via UAC, stops any
  existing `waired-agent` service, extracts to `%ProgramFiles%\Waired\`,
  and runs `waired-agent.exe install` (which is the single source of
  truth for SCM registration, Event Log source creation, and the
  restrictive DACL on `%ProgramData%\waired\`).

GUI alternative on Windows: double-click
`WairedSetup-<version>-x64.exe` from the same release. The CLI
one-liner is the recommended path while Authenticode signing is not
yet in place.

## Edge (latest main build)

The default one-liner installs the latest **stable** release. To track
the **edge** channel instead — a build rebuilt on every merge to `main`,
**not** a stable release — pass `--edge` (Linux/macOS) or `-Edge`
(Windows), or set `WAIRED_VERSION=edge`. `--latest` / `-Latest` are
aliases.

Linux / macOS:

```sh
curl -fsSL https://github.com/gen16k/waired-install/releases/latest/download/install.sh | sh -s -- --edge
```

Windows — the `iwr | iex` pipeline cannot bind `-Edge` (same `param()`
limitation as `-DryRun`, see [Inspect before running](#inspect-before-running)),
so select the channel via the environment first:

```powershell
$env:WAIRED_VERSION = 'edge'
iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/install.ps1 | iex
```

What the edge channel does:

* **Linux** — selects the edge apt suite (`waired-dev-apt-edge`) instead
  of the stable `waired-dev-apt`, writes
  `/etc/apt/sources.list.d/waired-edge.list`, and removes the stable
  source. The two channels are mutually exclusive (a host tracks exactly
  one), so the switch is clean; `apt` then installs the newest `~edge`
  build.
* **macOS / Windows** — fetches assets from the moving `edge` **prerelease**
  tag instead of the latest `v*` release.

`--edge` is a *channel* selector, not a version pin: it always installs
the current head of `main`, and re-running it later upgrades to whatever
is newest on edge.

**Switching back to stable** — re-run the default (no-flag) one-liner
with `WAIRED_VERSION` unset. edge → stable is a normal upgrade. (The
reverse, stable → edge, is a downgrade in apt's eyes because an `~edge`
build sorts below the stable it is based on; `--edge` handles the
allow-downgrade dance for you.)

> Edge is meant for dogfooding and testing. It can break at any time —
> use a stable release for anything you depend on.

## Uninstall

Matching uninstallers ship in every release. By default they remove the
binaries and unregister the background service but **keep** your config
and state (enrollment, identity, settings) so a re-install resumes where
you left off.

Linux / macOS:

```sh
curl -fsSL https://github.com/gen16k/waired-install/releases/latest/download/uninstall.sh | sh
```

Windows (self-elevates via UAC):

```powershell
iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/uninstall.ps1 | iex
```

For a **full wipe** — also delete config + state, the apt source the
installer added, the legacy Claude-proxy trust, and Ollama (binary / app
+ downloaded models) — add `--clean` (Linux/macOS) or `-Clean` (Windows).
It is destructive and asks to confirm first; pass `--yes` / `-Yes` to skip
the prompt (required on a non-interactive / piped shell), or `--dry-run` /
`-DryRun` to preview without changing anything.

```sh
curl -fsSL https://github.com/gen16k/waired-install/releases/latest/download/uninstall.sh | sh -s -- --clean
```

```powershell
# -Clean needs the script on disk (iex strips named parameters):
iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/uninstall.ps1 -OutFile uninstall.ps1
.\uninstall.ps1 -Clean
```

The two tiers map to apt's split: the default is `apt remove` (keeps
`/etc/waired` + `/var/lib/waired`), `--clean` is `apt purge` plus repo
cleanup. If you installed Waired with the Windows GUI installer
(`WairedSetup-*.exe`), you can also remove it from **Settings → Apps →
Waired → Uninstall**; the script is safe to run either way.

## Inspect before running

Linux:

```sh
curl -fsSL https://github.com/gen16k/waired-install/releases/latest/download/install.sh -o install.sh
less install.sh                     # read it
sh install.sh --dry-run             # see every command without executing
sh install.sh                       # run it
```

Windows — `iwr | iex` cannot pass `-DryRun` directly because the
pipeline fetches the script body as text and `iex` strips `param()`
bindings. Either run from a downloaded copy:

```powershell
iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/install.ps1 -OutFile install.ps1
Get-Content install.ps1 | more                         # read it
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

…or wrap the fetched body in a call-operator scriptblock so named
parameters bind:

```powershell
$src = iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/install.ps1
Invoke-Expression "& { $($src.Content) } -DryRun"
```

The dry-run prints every download / extract / `sc.exe` / `Stop-Service`
without executing it. Every privileged step in either script is
logged (`[waired] ...`) before it runs.

## Options

| Flag (Linux)          | Flag (Windows)      | Effect                                                                              |
|-----------------------|---------------------|------------------------------------------------------------------------------------|
| `--dry-run`           | `-DryRun`           | Print every privileged command without running it.                                 |
| `--edge` / `--latest` | `-Edge` / `-Latest` | Install the latest `main` build (edge channel) instead of the latest stable release. |
| `-h`/`--help`         | `-Help`             | Print usage and exit.                                                              |

## Environment variables

Shared between `install.sh` and `install.ps1`:

| Variable                  | Effect                                                                            |
|---------------------------|-----------------------------------------------------------------------------------|
| `WAIRED_VERSION`          | Pin a specific version (Linux: `waired=1.2.3`; Windows: tag `v1.2.3`), or set to `edge` for the latest `main` build (same as `--edge` / `-Edge`). |
| `WAIRED_NO_TRAY`          | If non-empty, skip `waired-tray` (Linux). Use on headless servers.                |
| `WAIRED_INSTALL_BASE_URL` | Override URL hosting the scripts + OS binaries (tests / mirrors).                 |

macOS-only:

| Variable                   | Effect                                                                           |
|----------------------------|----------------------------------------------------------------------------------|
| `WAIRED_NO_OLLAMA`         | If non-empty, skip the Ollama install (bring your own inference engine).         |
| `WAIRED_OLLAMA_DARWIN_URL` | Override the `Ollama.app` download URL (pin a version / point at a mirror).       |
| `WAIRED_DARWIN_BINDIR`     | Override where `waired` / `waired-agent` install. Default `/usr/local/bin`.       |

Linux-only (apt repo metadata):

| Variable                  | Effect                                                                            |
|---------------------------|-----------------------------------------------------------------------------------|
| `WAIRED_APT_BASE_URL`     | Override the apt repo base URL. Default points at the AR project endpoint.        |
| `WAIRED_APT_SUITE`        | Override the apt suite. Defaults to `waired-dev-apt`; `WAIRED_VERSION=edge` auto-selects `waired-dev-apt-edge`. |
| `WAIRED_APT_COMPONENT`    | Override the apt component. Defaults to `main`. AR APT format uses `main` today.  |
| `WAIRED_APT_KEY_URL`      | Override the AR signing-key URL (region-scoped Google-managed key).               |

Windows-only:

| Variable             | Effect                                                                |
|----------------------|-----------------------------------------------------------------------|
| `WAIRED_STATE_DIR`   | Override on-disk state location. Default `%ProgramData%\waired`.      |

## Release versioning

Each `v*` tag in this repository corresponds to a Waired release of the
same version. The Linux `.deb` packages are distributed via Google
Artifact Registry; the Windows `.zip` + `.sha256` + Inno Setup `.exe`
and the macOS `waired-darwin-{amd64,arm64}.tar.gz` + `.sha256` are
uploaded as release assets here. Each release also carries the install /
uninstall entrypoints (`install.sh`, `install.ps1`, `uninstall.sh`,
`uninstall.ps1`) as assets — the one-liner URLs above resolve to them.
The scripts themselves are maintained in the upstream Waired repository
and mirrored here per release; this repo holds no script sources of its
own.

The moving `edge` **prerelease** tag carries the latest-`main`-build
assets for the [edge channel](#edge-latest-main-build); GitHub's
`releases/latest` never resolves to it, so the stable one-liner is
unaffected.

## After install

### Linux

* Configure `/etc/waired/agent.env` (see `/etc/waired/agent.env.example`).
* Enroll the device: `sudo waired init --control https://<your-control-plane>`.
* Start the daemon: `sudo systemctl enable --now waired-agent`.

Diagnostics:  `journalctl -u waired-agent -e`
Uninstall:    `curl -fsSL https://github.com/gen16k/waired-install/releases/latest/download/uninstall.sh | sh` (see [Uninstall](#uninstall); `--clean` also purges `/etc/waired` + `/var/lib/waired`)

### macOS

* Enroll the device: `waired init --control https://<your-control-plane>`.
* Start the agent now (it also auto-starts at next login):
  `launchctl kickstart -k gui/$(id -u)/com.waired.agent`.
* Ollama is installed as `Ollama.app`; launch it once (`open -a Ollama`)
  so the `127.0.0.1:11434` server starts. The agent reuses it.

Diagnostics:  `log show --predicate 'process == "waired-agent"' --last 5m`
Uninstall:    `curl -fsSL https://github.com/gen16k/waired-install/releases/latest/download/uninstall.sh | sh` (see [Uninstall](#uninstall); `--clean` also removes state + Ollama)

### Windows

* Enroll the device (or right-click the tray icon once it's running and pick "Log in..."):
  ```powershell
  & "C:\Program Files\Waired\waired.exe" init --control "https://<your-control-plane>"
  ```
* Start the service (it's installed with `AUTO_START` + `DelayedAutoStart`, so it will also come up on the next boot):
  ```powershell
  Start-Service waired-agent
  ```
* Tray: launch `C:\Program Files\Waired\waired-tray.exe` once from File Explorer or the Start menu. On first launch it registers itself in `HKCU\...\Run` so it auto-starts at each logon.

Diagnostics:  `Get-WinEvent -ProviderName waired-agent -LogName Application -MaxEvents 20`
Uninstall:    `iwr -useb https://github.com/gen16k/waired-install/releases/latest/download/uninstall.ps1 | iex` (see [Uninstall](#uninstall); download + `-Clean` to also wipe state, or Settings → Apps → Waired → Uninstall if you used the Inno Setup GUI installer)

## Supported targets today

| OS family             | Status                                              |
|-----------------------|-----------------------------------------------------|
| Debian (trixie+, sid) | supported (apt)                                     |
| Ubuntu 24.04 LTS+     | supported (apt)                                     |
| Fedora / RHEL         | placeholder — exits with a clear message            |
| Alpine                | placeholder                                         |
| Arch / AUR            | placeholder                                         |
| macOS 13+             | supported (`install.sh`, unsigned ad-hoc tarball)   |
| Windows 10 1809+ / 11 | supported (`install.ps1` + Inno Setup GUI `.exe`)   |

Architecture matrix: `amd64`, `arm64` on Linux and macOS; `amd64` only
on Windows (arm64 deferred). Anything else exits. macOS code signing /
notarization and a Homebrew formula are follow-ups.

## License

Apache-2.0 (see [`LICENSE`](./LICENSE)).
