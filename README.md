# waired-install

Entrypoint installers for **Waired**:

* `install.sh` — Linux (Debian / Ubuntu apt).
* `install.ps1` — Windows 10 1809+ / 11 (PowerShell 5.1+).

## Quick install

Linux:

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

| Flag (Linux) | Flag (Windows) | Effect                                             |
|--------------|----------------|----------------------------------------------------|
| `--dry-run`  | `-DryRun`      | Print every privileged command without running it. |
| `-h`/`--help`| `-Help`        | Print usage and exit.                              |

## Environment variables

Shared between `install.sh` and `install.ps1`:

| Variable                  | Effect                                                                            |
|---------------------------|-----------------------------------------------------------------------------------|
| `WAIRED_VERSION`          | Pin to a specific version (Linux: `waired=1.2.3`; Windows: release tag `v1.2.3`). |
| `WAIRED_NO_TRAY`          | If non-empty, skip `waired-tray`. Use on headless servers.                        |
| `WAIRED_INSTALL_BASE_URL` | Override URL hosting `install.sh` / `install.ps1` itself (tests / mirrors).       |

Linux-only (apt repo metadata):

| Variable                  | Effect                                                                            |
|---------------------------|-----------------------------------------------------------------------------------|
| `WAIRED_APT_BASE_URL`     | Override the apt repo base URL. Default points at the AR project endpoint.        |
| `WAIRED_APT_SUITE`        | Override the apt suite. Defaults to `waired-dev-apt` (= the AR repository id).    |
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
are uploaded as release assets here. This repository hosts the
installer entrypoints (`install.sh`, `install.ps1`) and — for Windows
— the binary artifacts themselves.

## After install

### Linux

* Configure `/etc/waired/agent.env` (see `/etc/waired/agent.env.example`).
* Enroll the device: `sudo waired init --control https://<your-control-plane>`.
* Start the daemon: `sudo systemctl enable --now waired-agent`.

Diagnostics:  `journalctl -u waired-agent -e`
Uninstall:    `sudo apt purge waired waired-tray`

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
Uninstall:    `& "C:\Program Files\Waired\waired-agent.exe" uninstall` (or Settings → Apps → Waired → Uninstall if you used the Inno Setup GUI installer)

## Supported targets today

| OS family             | Status                                              |
|-----------------------|-----------------------------------------------------|
| Debian (trixie+, sid) | supported (apt)                                     |
| Ubuntu 24.04 LTS+     | supported (apt)                                     |
| Fedora / RHEL         | placeholder — exits with a clear message            |
| Alpine                | placeholder                                         |
| Arch / AUR            | placeholder                                         |
| macOS                 | placeholder (Homebrew tap planned)                  |
| Windows 10 1809+ / 11 | supported (`install.ps1` + Inno Setup GUI `.exe`)   |

Architecture matrix: `amd64`, `arm64` on Linux; `amd64` only on Windows
(arm64 deferred). Anything else exits.

## License

Apache-2.0 (see [`LICENSE`](./LICENSE)).
