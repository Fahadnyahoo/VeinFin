# Installer and preflight

The installer provides configuration generation, non-mutating preflight, a resumable staged installation, and final verification. It never creates, formats, partitions, repairs, or mounts media storage; an existing writable mount is mandatory.

## Command interface

```sh
./install.sh --help
./install.sh --check [--root /absolute/path]
./install.sh --dry-run [configuration options]
./install.sh --generate-config [configuration options]
sudo --preserve-env=SSH_CONNECTION ./install.sh --install [configuration options]
sudo --preserve-env=SSH_CONNECTION ./install.sh --verify [--root /absolute/path]
```

- `--help` prints the interface and changes nothing.
- `--check` reads an existing generated `.env` when available and performs non-mutating host and configuration checks.
- `--dry-run` validates prospective configuration and reports planned writes. It creates no directories, secrets, or files.
- `--generate-config` explicitly creates the protected runtime tree, local secrets, `.env`, the Caddy configuration, endpoint metadata, discovery selection, and credential summary. It does not deploy.
- `--install` validates, installs, or resumes the supported stage sequence. Completed unchanged stages are verification-only.
- `--verify` performs final live verification and requires the protected Control panel setup completion state.

Running `sudo ./install.sh` without a mode prints help and exits without changing the host. Deployment always requires the explicit `--install` mode and an active validated SSH context.

## Installation stages and resume

The supported order is configuration validation, Debian/Docker preparation, storage readiness, firewall, core/Jellyfin, qBittorrent, Sonarr/Radarr/Prowlarr, Bazarr/Seerr/FlareSolverr/Recyclarr, public HTTPS when configured, libraries, indexer/subtitle foundation, quality profiles, download lifecycle policy, control panel/restricted agent, and final verification.

Each stage completion record is mode `0600` beneath ignored `runtime/state/install/`. Stage fingerprints cover only relevant configuration and implementation inputs. An interrupted run resumes at the first incomplete stage; an unchanged completed installation performs final verification only. A changed validated fingerprint targets that stage without rolling back unrelated healthy stages. Failures identify the exact stage and stop closed.

Experimental plugins and the deferred Download lifecycle setup synthetic torrent helper are excluded from the stage graph. The final summary contains endpoints and enabled/deferred state but never credentials.

## Interactive generation

From a terminal:

```sh
sudo ./install.sh --generate-config
```

The installer prompts for the required public hostname and offers defaults for the management bind address, management URL host, reserved management source CIDRs, time zone, config root, and media root. One management password is generated without prompts or terminal output. No application API key is generated.

## Noninteractive generation

Use a protected input file containing non-secret `KEY=VALUE` records:

```dotenv
PUBLIC_HOSTNAME=media.example.invalid
MANAGEMENT_BIND_IP=127.0.0.1
MANAGEMENT_URL_HOST=localhost
MANAGEMENT_ALLOWED_CIDRS=127.0.0.1/32
PUID=1000
PGID=1000
TZ=Etc/UTC
CONFIG_ROOT=/opt/veinfin
MEDIA_ROOT=/srv/media
```

Then run:

```sh
sudo ./install.sh --generate-config --input /path/to/settings.env
```

Individual non-secret overrides may use `--set KEY=VALUE`. Do not use `--set` for secrets; the installer rejects secret-bearing keys so values are not passed through process arguments.

For tests or alternate output locations, use either:

```sh
VEINFIN_ROOT=/absolute/test/path ./install.sh --generate-config --input settings.env
./install.sh --generate-config --root /absolute/test/path --input settings.env
```

`VEINFIN_ROOT` controls only generated VeinFin configuration output. The installer never creates `CONFIG_ROOT` or `MEDIA_ROOT`.

## Existing configuration and rotation

An existing `.env` is preserved by default, making repeated generation safe. Use `--force` to rewrite non-secret configuration while retaining existing generated secrets. Use `--rotate-secrets` for explicit rotation; it implies a forced `.env` rewrite.

The only generated credential is the shared human-facing management password. qBittorrent is intended to use that same password where its verified bootstrap supports it; a later service-specific hash must be derived rather than creating another human password. Jellyfin viewer accounts remain separate. No control-panel secret or placeholder application API key is created. There is no reverse-proxy credential in the current Caddy contract.

Directories under `runtime/` use mode `0700`. `.env`, secret files, rendered files, and the credential summary use mode `0600`. Writes use same-directory temporary files and atomic replacement. The installer never prints generated values.

If execution is interrupted, rerun the same `--generate-config` command. Completed secret files are preserved, partial final files are prevented by atomic replacement, and stale temporary files contain restrictive permissions. Review before using `--force` or `--rotate-secrets`.

## Rendered contracts

- `runtime/config/caddy/Caddyfile`: validated public hostname and internal `jellyfin:8096` target.
- `runtime/generated/endpoints.env`: public Jellyfin URL, private management URLs, internal service endpoints including `http://flaresolverr:8191`, and media/config roots. It contains no credentials.
- `runtime/generated/compose-files.txt`: the base Compose file and the discovery override only when explicitly enabled.
- `.env`: validated Compose environment including the management password and locked images.
- `runtime/state/bootstrap-status.env`: non-secret pending markers for qBittorrent credential application and application API keys.
- `runtime/secrets/credentials-summary.txt`: root-readable management credential, explicitly marked not yet applied, without embedded Visit credentials.

Application-specific API configuration is deferred to an authorized deployment operation. Sonarr, Radarr, Prowlarr, Bazarr, and Seerr API keys will be generated or captured only when a verified bootstrap actually applies them. Real API keys must be unique. The foundation does not invent or render unverified application configuration formats.

## Preflight behavior

`--check` reports:

- OS and architecture;
- CPU cores, RAM, and swap;
- required host commands and secure random source;
- Docker and Compose availability;
- media-root existence, mount status, and expected directory layout;
- render-device availability and hardware-transcoding consistency;
- configured TCP/optional UDP port occupancy;
- image-pin and configuration validity;
- `.env` and secret permissions.

Less than 8 GiB RAM produces a prominent warning; at least 12 GiB is recommended. The checker never changes host memory. Missing or unmounted media storage fails the storage preflight without repair.

Compose binds private interfaces to one specific configured server address, but it cannot enforce source-client CIDRs. The separate host-firewall procedure in [FIREWALL.md](FIREWALL.md) enforces target-local management sources; installer preflight warns that Compose alone is insufficient and never claims deployment readiness.

## Deliberately excluded

The installer never initializes storage, manages DNS or router configuration, exposes Docker TCP APIs, enables experimental plugins, or enables hardware transcoding without its separately validated device contract. Who's Watching remains experimental and unsupported. Guarded firewall and HTTPS transitions retain their rollback and verification gates.
