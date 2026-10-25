# Configuration and generated-data contract

VeinFin implements explicit configuration generation without deployment. Use `install.sh`; do not copy `.env.example` manually.

## Input classes

| Class | Examples | Owner | Storage |
| --- | --- | --- | --- |
| User-provided settings | time zone, UID/GID, media root, hostname, management bind address and source CIDRs | Operator | Generated `.env`, mode `600` |
| Generated credential | shared human-facing management password | Installer | `${RUNTIME_ROOT}/secrets/`, individual file mode `600` |
| Application API keys | Sonarr, Radarr, Prowlarr, Bazarr, Seerr | Verified application bootstrap | Unique protected files below `${RUNTIME_ROOT}/secrets/` after the relevant deployment operation |
| Runtime state | install manifest, migrations, reconciliation state | Installer | `${RUNTIME_ROOT}/state/` |
| Committed templates | Caddy and future application templates | Repository | `templates/`, no secrets |
| Application state | databases, metadata, caches, logs, certificates | Containers | `${CONFIG_ROOT}/<service>/`, outside Git |

The unified management password is applied only to verified private administration interfaces. Media services uses it for the single Jellyfin administrator, Bazarr, and Seerr owner bootstrap as well as the existing private applications. API keys never share that password or each other's keys. Credentials are never embedded in Visit URLs.

## Source and runtime layout

```text
compose.yaml                    tracked primary Compose scaffold
compose/                        tracked optional overrides and service catalog
templates/                      tracked safe source templates
docs/                           tracked architecture and operator contracts
tests/                          tracked static validation
runtime/                        generated and ignored
├── config/                     generated, validated configuration
│   ├── caddy/Caddyfile
│   └── recyclarr/
├── secrets/                    generated secrets, directory 0700/files 0600
│   └── credentials-summary.txt root-readable summary, mode 0600
├── state/
│   └── bootstrap-status.env   non-secret pending application/API state
└── generated/                  endpoint and Compose-file contracts, mode 0600
```

`RUNTIME_ROOT` is derived from the selected `VEINFIN_ROOT`/`--root` output root. `${CONFIG_ROOT}` is the operator-selected root for mutable application data. `${MEDIA_ROOT}` is an existing operator-provided media root. Generation creates only the selected output root and its runtime tree; it never creates the configured application or media roots.

## `.env.example` groups

- Required user settings: `TZ`, `PUID`, `PGID`, `UMASK`, `CONFIG_ROOT`, `MEDIA_ROOT`, `RUNTIME_ROOT`, public hostname/bind settings, and private management settings.
- Image controls: one reviewed release tag plus immutable manifest digest for every container.
- Optional settings: `ENABLE_JELLYFIN_DISCOVERY`, future VPN inputs, and hardware transcoding, which defaults off.
- Empty local-only value: the generated management password.

The example uses a documentation-only hostname and loopback values. Generation rejects the example hostname, empty required values, control characters, environment-file injection, malformed project names, conflicting host ports, unsafe or root paths, invalid UID/GID values, unknown time zones, wildcard management binding, malformed CIDR allowlists, unsafe render-device paths, and any image value that differs from `config/images.lock`.

## Accepted key registry

The parser rejects every key outside this registry. Every registry key is present in `.env.example`; the test suite compares the two sets exactly.

| Purpose | Keys |
| --- | --- |
| Profile | `INSTALLATION_PROFILE`, `ENABLE_MIGRATION_STAGES` |
| Identity | `COMPOSE_PROJECT_NAME`, `TZ`, `PUID`, `PGID`, `UMASK` |
| Paths | `CONFIG_ROOT`, `MEDIA_ROOT`, `RUNTIME_ROOT`, `LEGACY_CANDIDATE_ROOT` |
| Public HTTPS | `PUBLIC_HOSTNAME`, `PUBLIC_BIND_IP`, `HTTPS_PORT` |
| Private access | `MANAGEMENT_BIND_IP`, `MANAGEMENT_URL_SCHEME`, `MANAGEMENT_URL_HOST`, `MANAGEMENT_ALLOWED_CIDRS`, `PROTECTED_LAN_CIDRS`, `SSH_PORT`, `MANAGEMENT_USERNAME`, `MANAGEMENT_PASSWORD` |
| Private ports | `JELLYFIN_MANAGEMENT_PORT`, `QBITTORRENT_MANAGEMENT_PORT`, `SONARR_MANAGEMENT_PORT`, `RADARR_MANAGEMENT_PORT`, `PROWLARR_MANAGEMENT_PORT`, `BAZARR_MANAGEMENT_PORT`, `SEERR_MANAGEMENT_PORT`, `CONTROL_PANEL_MANAGEMENT_PORT`, `LEGACY_CANDIDATE_PORT` |
| Discovery | `ENABLE_JELLYFIN_DISCOVERY`, `JELLYFIN_DISCOVERY_BIND_IP`, `JELLYFIN_DISCOVERY_PORT` |
| Images | `CADDY_IMAGE_TAG`, `JELLYFIN_IMAGE_TAG`, `QBITTORRENT_IMAGE_TAG`, `SONARR_IMAGE_TAG`, `RADARR_IMAGE_TAG`, `PROWLARR_IMAGE_TAG`, `BAZARR_IMAGE_TAG`, `SEERR_IMAGE_TAG`, `RECYCLARR_IMAGE_TAG`, `FLARESOLVERR_IMAGE_TAG` |
| Explicit optional features | `ENABLE_VPN_PROFILE`, `VPN_PROVIDER`, `ENABLE_HARDWARE_TRANSCODING`, `TRANSCODING_DEVICE` |

`LEGACY_CANDIDATE_ROOT` and `LEGACY_CANDIDATE_PORT` are supported inputs for the separately invoked rollback-safe legacy-UI candidate workflow. They are validated and persisted but do not enable that optional workflow in the default installer.

The shared private username defaults to `veinfin`; the password is randomly generated and is applied only by an authorized deployment operation. API keys are captured only from live applications and remain unique. Caddy currently requires no separate basic-auth or internal credential.

## Generation boundaries

- Templates may contain variable names, never real values.
- The installer renders generated files atomically; Compose must not mutate tracked templates.
- The credentials summary helps the owner complete future web/API setup. It is mode `600`, excluded from Git, contains no credential-bearing URL, and must never be served by a web interface.
- Application-generated databases, caches, logs, certificates, and keys stay outside the repository.
- Third-party plugin and subtitle-provider credentials are entered locally and are not exposed to unrelated services.

See [INSTALLER.md](INSTALLER.md) for commands, noninteractive inputs, rotation, preflight, and recovery. See [IMAGE_PINS.md](IMAGE_PINS.md) for the reviewed image lock.
