# Installer and preflight

The installer provides configuration generation, non-mutating preflight, a resumable staged installation, and final verification. It never creates, formats, partitions, repairs, or mounts media storage; an existing writable mount is mandatory.

## Command interface

```sh
./install.sh --help
./install.sh --check [--root /absolute/path]
./install.sh --dry-run --profile public-https|lan-only [configuration options]
./install.sh --generate-config --profile public-https|lan-only [configuration options]
sudo --preserve-env=SSH_CONNECTION ./install.sh --install --profile public-https|lan-only [configuration options]
sudo --preserve-env=SSH_CONNECTION ./install.sh --verify --profile public-https|lan-only [--root /absolute/path]
```

- `--help` prints the interface and changes nothing.
- `--check` reads an existing generated `.env` when available and performs non-mutating host and configuration checks.
- `--dry-run` validates prospective configuration and reports planned writes. It creates no directories, secrets, or files.
- `--generate-config` requires an explicit profile and creates the protected runtime tree, local secrets, `.env`, endpoint metadata, discovery selection, and credential summary. It does not deploy.
- `--install` validates, installs, or resumes the supported stage sequence. Completed unchanged stages are verification-only.
- `--verify` performs final live verification and requires the protected Control panel setup completion state.

Running `sudo ./install.sh` without a mode prints help and exits without changing the host. Deployment always requires the explicit `--install` mode and an active validated SSH context.

## Installation stages and resume

The shared core order is configuration validation, Debian/Docker preparation, storage readiness, firewall, Jellyfin, qBittorrent, Sonarr/Radarr/Prowlarr, Bazarr/Seerr/FlareSolverr/Recyclarr, the selected exposure stage, the control panel/restricted agent, pinned Jellyfin plugins and Jellyfin Enhanced portable defaults, and final verification. `public-https` selects Caddy/ACME; `lan-only` selects a management-address Jellyfin binding. Migration/adoption stages are separate and never prerequisites for an empty clean install.

Each stage completion record is mode `0600` beneath ignored `runtime/state/install/`. Stage fingerprints cover only relevant configuration and implementation inputs. An interrupted run resumes at the first incomplete stage; an unchanged completed installation performs final verification only. A changed validated fingerprint targets that stage without rolling back unrelated healthy stages. Failures identify the exact stage and stop closed.

Optional status is written to `runtime/state/optional-stages.status`. `SKIPPED_NOT_REQUESTED` and `SKIPPED_PROFILE_LAN_ONLY` are explicit skips, never completion markers. Existing-media inventory, Sonarr adoption, legacy Jellyfin migration, and their production manifests remain separately invoked operator stages. A fresh installation creates its own application databases, administrator, credentials, API keys, and service connections; it does not import production state.

The named plugin component uses only `config/plugins.lock`, `config/legacy-ui-assets.lock`, and the classified `config/jellyfin-enhanced-profile.json`; arbitrary plugin repositories are excluded. It installs the reviewed Jellyfin 10.11 cinematic UI profile, then securely injects protected integration credentials and verifies the versioned Jellyfin Enhanced defaults. Unchanged reruns verify only; profile migrations retain a protected API-level rollback payload. No clean-install stage adds a torrent, starts a download, or submits a Seerr request.

## Interactive generation

From a terminal:

```sh
sudo ./install.sh --generate-config --profile public-https
```

The installer prompts for the required public hostname and offers defaults for the management bind address, management URL host, reserved management source CIDRs, time zone, config root, and media root. One management password is generated without prompts or terminal output. No application API key is generated.

## Noninteractive generation

Use a protected input file containing non-secret `KEY=VALUE` records:

```dotenv
PUBLIC_HOSTNAME=media.example.com
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
sudo ./install.sh --generate-config --profile public-https --input /path/to/settings.env
```

Individual non-secret overrides may use `--set KEY=VALUE`. Do not use `--set` for secrets; the installer rejects secret-bearing keys so values are not passed through process arguments.

For tests or alternate output locations, use either:

```sh
VEINFIN_ROOT=/absolute/test/path ./install.sh --generate-config --profile lan-only --input settings.env
./install.sh --generate-config --profile lan-only --root /absolute/test/path --input settings.env
```

`VEINFIN_ROOT` controls only generated VeinFin configuration output. The installer never creates `CONFIG_ROOT` or `MEDIA_ROOT`.

## Existing configuration and rotation

An existing `.env` is preserved by default, making repeated generation safe. Use `--force` to rewrite non-secret configuration while retaining existing generated secrets. Use `--rotate-secrets` for explicit rotation; it implies a forced `.env` rewrite.

Configuration generation creates only the shared human-facing management password. During installation, verified application bootstraps create or capture unique API keys plus separate control-panel channel/session secrets in protected files. qBittorrent and the Jellyfin administrator use the generated management credential; application API keys remain distinct. There is no reverse-proxy credential in the current Caddy contract.

Directories under `runtime/` use mode `0700`. `.env`, secret files, rendered files, and the credential summary use mode `0600`. Writes use same-directory temporary files and atomic replacement. The installer never prints generated values.

If execution is interrupted, rerun the same `--generate-config` command. Completed secret files are preserved, partial final files are prevented by atomic replacement, and stale temporary files contain restrictive permissions. Review before using `--force` or `--rotate-secrets`.

## Rendered contracts

- `runtime/config/caddy/Caddyfile`: validated public hostname and internal `jellyfin:8096` target.
- `runtime/generated/endpoints.env`: public Jellyfin URL, private management URLs, internal service endpoints including `http://flaresolverr:8191`, and media/config roots. It contains no credentials.
- `runtime/generated/compose-files.txt`: the base Compose file and the discovery override only when explicitly enabled.
- `.env`: validated Compose environment including the management password and locked images.
- `runtime/state/bootstrap-status.env`: non-secret pending markers for qBittorrent credential application and application API keys.
- `runtime/secrets/credentials-summary.txt`: root-readable management credential; generation marks it pending and a successful application bootstrap replaces that status with the exact applied-service summary. Visit URLs never embed credentials.

The install operation generates or captures Sonarr, Radarr, Prowlarr, Bazarr, and Seerr API keys only when each verified bootstrap applies its real application configuration. The keys must be unique and remain in root-owned protected files. Configuration generation alone never invents or renders placeholder API values.

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

The installer never initializes storage, manages DNS or router configuration, exposes Docker TCP APIs, enables experimental plugins, or enables hardware transcoding without its separately validated device contract. The named plugin component installs only the immutable reviewed entries described in [PLUGINS.md](PLUGINS.md). Who's Watching remains experimental and unsupported. Guarded firewall and HTTPS transitions retain their rollback and verification gates.

## Profile examples

For `lan-only`, set `PUBLIC_BIND_IP=127.0.0.1`, set `MANAGEMENT_BIND_IP` and `MANAGEMENT_URL_HOST` to the server LAN address, and restrict `MANAGEMENT_ALLOWED_CIDRS` to the approved client CIDR. The installer does not start Caddy or listen on TCP 443.

For `public-https`, set the public hostname and public bind address, ensure DNS and TCP 443 routing are already correct, and use the same private management CIDR controls. VeinFin never changes DNS or the router.
