# waired-install

Entrypoint installer (`install.sh`) for the **Waired** Linux agent.

## Quick install

```sh
curl -fsSL https://github.com/gen16k/waired-install/releases/latest/download/install.sh | sh
```

What it does:

1. Detects your Linux distribution and CPU architecture (Debian / Ubuntu, amd64 / arm64).
2. Adds the Waired apt repository (hosted on Google Artifact Registry) and its Google-managed signing key.
3. `apt install`s the `waired` package (CLI + agent daemon) and, by default, `waired-tray` (desktop tray UI).

## Inspect before running

```sh
curl -fsSL https://github.com/gen16k/waired-install/releases/latest/download/install.sh -o install.sh
less install.sh                     # read it
sh install.sh --dry-run             # see every command without executing
sh install.sh                       # run it
```

`install.sh` is a single POSIX `sh` file. Every privileged step is logged (`[waired] ...`) before it runs, and `--dry-run` prints each command without executing.

## Options

| Flag         | Effect                                             |
|--------------|----------------------------------------------------|
| `--dry-run`  | Print every privileged command without running it. |
| `-h`/`--help`| Print usage and exit.                              |

## Environment variables

| Variable                  | Effect                                                                  |
|---------------------------|-------------------------------------------------------------------------|
| `WAIRED_VERSION`          | Pin to a specific apt version (`waired=1.2.3`).                         |
| `WAIRED_NO_TRAY`          | If non-empty, skip `waired-tray`. Use on headless servers.              |
| `WAIRED_APT_BASE_URL`     | Override the apt repo base URL (mirrors / tests).                       |
| `WAIRED_APT_SUITE`        | Override the apt suite (= AR repository id).                            |
| `WAIRED_APT_COMPONENT`    | Override the apt component (default: `main`).                           |
| `WAIRED_APT_KEY_URL`      | Override the signing-key URL (region-scoped Google-managed key).        |

## Release versioning

Each `v*` tag in this repository corresponds to a Waired release of the same version. The `.deb` packages themselves are distributed via Google Artifact Registry; this repository only hosts the installer entrypoint.

After install:

* Configure `/etc/waired/agent.env` (see `/etc/waired/agent.env.example`).
* Enroll the device: `sudo waired init --control https://<your-control-plane>`.
* Start the daemon: `sudo systemctl enable --now waired-agent`.

## Supported targets today

| OS family             | Status                                       |
|-----------------------|----------------------------------------------|
| Debian (trixie+, sid) | supported (apt)                              |
| Ubuntu 24.04 LTS+     | supported (apt)                              |
| Fedora / RHEL         | placeholder — exits with a clear message     |
| Alpine                | placeholder                                  |
| Arch / AUR            | placeholder                                  |
| macOS                 | placeholder (Homebrew tap planned)           |
| Windows               | not handled here — separate `.ps1` planned   |

Architecture matrix: `amd64`, `arm64`. Anything else exits.

## License

Apache-2.0 (see [`LICENSE`](./LICENSE)).
