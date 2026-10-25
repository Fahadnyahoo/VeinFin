# Supported Jellyfin legacy UI

VeinFin intentionally pins Jellyfin `10.11.11` for its supported cinematic UI profile. Jellyfin's official migration warning means a 12.x database must never be opened by this image. Existing 12.x installations use the isolated blue/green workflow in `scripts/deploy/legacy-ui.sh`; fresh installations use the named `plugins` installer component after Jellyfin and its libraries are ready.

## Immutable allowlists

`config/plugins.lock` is the only server-plugin allowlist. Each record contains the exact plugin GUID, version, target ABI, license, official project, immutable release URL, archive SHA-256, restart behavior, and every permitted archive member hash. `config/legacy-ui-assets.lock` pins KefinTweaks `0.5.3` to tag commit `7ff0812d88fb923e5dc7fdb3262a84b283fd627a` and archive SHA-256 `4ffe74b4b8589ba7e64adc28f6c9542e07979dd6dbc525945b2c347888a5d099`. Both locks were reviewed on 2026-10-24; updates are manual and never automatic.

| Plugin | Version | Jellyfin ABI | License |
| --- | --- | --- | --- |
| Jellyfin Enhanced | 12.13.0.0 | 10.11 series | GPL-3.0 |
| Media Bar Enhanced | 3.10.0.0 | 10.11 series | GPL-3.0 |
| Home Screen Sections | 3.0.3.0 | 10.11 series | GPL-3.0 |
| Custom Tabs | 0.3.2.0 | 10.11 series | GPL-3.0 |
| JavaScript Injector | 4.1.0.0 | 10.11 series | GPL-3.0 |
| File Transformation | 3.0.2.0 | 10.11 series | GPL-3.0 |
| HoverTrailer | 0.3.1.0 | 10.11 series | MIT |
| InPlayerEpisodePreview | 2.5.0.2 | 10.11 series | MIT |
| Intro Skipper | 1.10.11.24 | 10.11 series | GPL-3.0 |
| Local Posters | 0.2.0.2 | 10.11 series | GPL-3.0 |
| AniList | 13.0.0.0 | 10.11 series | GPL-2.0 |
| AniSearch | 6.0.0.0 | 10.11 series | GPL-2.0 |

AudioDB, MusicBrainz, OMDb, Studio Images, and TMDb are bundled in the immutable Jellyfin image and are verified rather than installed twice. Who's Watching is excluded and unsupported.

KefinTweaks is self-hosted from the verified tag archive. JavaScript Injector rejects external script URLs, so clients never load `latest`, a floating branch, or a third-party CDN at runtime. The reviewed configuration enables the local cinematic skin, video hero, home sections, hover trailers, in-player episode preview, native media-segment skip controls, and presentation features. It does not invent Custom Tabs, external analytics, or Jellyseerr settings.

## Installation and rollback

Fresh installations run the named component through `sudo --preserve-env=SSH_CONNECTION ./install.sh --install`. Direct component operations are:

```sh
sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --check
sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --apply
sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --verify
sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --rollback
sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --configure-integrations
sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --verify-integrations
sudo --preserve-env=SSH_CONNECTION scripts/deploy/plugins.sh --rollback-integrations
```

### Jellyfin Enhanced installation profile

`config/jellyfin-enhanced-profile.json` is the versioned Jellyfin Enhanced
`12.13.0.0` installation profile. It classifies all 357 fields in the reviewed
live schema: 304 safe portable defaults, 24 installation-specific fields, eight
secrets, and 21 user/runtime-state fields. The 304 exact adopted values are the
`safe_portable_defaults` object; keeping them machine-readable avoids a second,
drifting copy in documentation. The profile loader rejects overlaps, missing
classifications, secret-shaped portable keys, endpoints in portable values, and
any live schema addition that has not been classified first.

Portable defaults include the live feature, appearance, tag, playback, request,
discovery, maintenance-policy, keyboard-shortcut, and UI behavior. Analytics is
disabled; Arr links and Seerr search are enabled. Installation endpoints,
instance records, custom roots/profile IDs, branding URLs, operator messages,
and Shoko settings are not copied. API keys and the analytics installation
secret are classified as secrets. Analytics delivery state, custom-tab ownership
state, blocked/affected user lists, library-ID lists, and cache-clear timestamps
are classified as user/runtime state. Excluded fields remain untouched except
for the explicitly generated VeinFin integration fields below.

The Jellyfin Enhanced integration command reads Sonarr, Radarr, Bazarr, and Seerr
keys only from root-readable runtime secret files. It stores Sonarr, Radarr, and
Seerr credentials through Jellyfin's supported plugin configuration API. The supported
Jellyfin Enhanced version does not accept a Bazarr API key; Bazarr uses a URL and
its protected key is used solely for verification. Sonarr, Radarr, Bazarr, and
Seerr use their Docker service URLs. All Advanced URL Mappings are empty by
default, so the profile contains no browser management address.

An optional operator-supplied TMDB key may be placed in the root-owned mode-0600
`runtime/secrets/tmdb-api-key` file. When the file is absent, the installer writes
an empty `TMDB_API_KEY`, leaving TMDB-dependent enhancements disabled. The key is
never part of the versioned profile.

The first configuration and each reviewed profile migration create a mode-0600
full configuration backup plus a protected backup pointer before using the
supported plugin API. The completion marker is a fingerprint of the profile and
configuration code. An unchanged repeated installation verifies only; a changed
fingerprint performs one guarded migration and restores the pre-change payload
automatically if persistence or integration validation fails. The dedicated
integration rollback command restores the latest protected payload through the
same supported API. None of these operations restarts Jellyfin.

Seerr uses its Docker service URL, leaves advanced URL mappings empty, enables
ordinary unavailable-title search and request controls, and does not require a
TMDB key for that search path. Verification never submits a request.
`tests/browser-seerr-request-smoke.py` exercises the authenticated browser client,
renders unavailable movie and show cards, opens their controls by keyboard, and
asserts that enabled Request buttons are present without invoking a request API.

An existing Jellyfin 12.x deployment must use:

```sh
sudo --preserve-env=SSH_CONNECTION scripts/deploy/legacy-ui.sh --apply
sudo --preserve-env=SSH_CONNECTION scripts/deploy/legacy-ui.sh --verify
sudo --preserve-env=SSH_CONNECTION scripts/deploy/legacy-ui.sh --promote
sudo --preserve-env=SSH_CONNECTION scripts/deploy/legacy-ui.sh --rollback
```

The candidate has separate config/cache, a loopback-only port, read-only media, and no torrent or Docker-socket mount. Promotion preserves the full original Jellyfin directory and environment beneath root-only ignored runtime backups. `--rollback` restores that directory and the previous image pin. Repeated apply or promotion is verification-only.

## Security and upgrades

This profile deliberately accepts the increased risk of an older Jellyfin release and reviewed plugins that transform Jellyfin Web. It must remain behind Caddy, with TCP 443 as the only public port and management access loopback-only. Plugin artifacts are not fetched by Compose, arbitrary repository URLs are rejected, and upgrades require a new image/plugin compatibility review, hashes, isolated browser tests, and protected rollback. Never point Jellyfin 10.11 at a 12.x database.
