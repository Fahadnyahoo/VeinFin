# Jellyfin libraries and controlled scan

Library setup creates exactly three Jellyfin libraries through the authenticated local API:

| Name | Jellyfin type | Container path |
| --- | --- | --- |
| Movies | Movies | `/data/library/movies` |
| TV Shows | Shows | `/data/library/tv` |
| Anime | Shows | `/data/library/anime` |

The paths are the existing read-only Jellyfin view of `/srv/media/library`. This workflow neither changes the media tree nor configures Sonarr, Radarr, metadata providers, plugins, credentials, users, locale, networking, discovery, or hardware transcoding.

## Interface

On the Debian target:

```sh
sudo --preserve-env=SSH_CONNECTION scripts/deploy/libraries.sh --check
sudo --preserve-env=SSH_CONNECTION scripts/deploy/libraries.sh --apply
sudo --preserve-env=SSH_CONNECTION scripts/deploy/libraries.sh --verify
```

`--check` is read-only and validates the protected runtime manifest, storage mount, expected non-empty MKV count, nine healthy containers, inactive rsync state, read-only legacy-disk contract, HTTPS, listeners, and firewall.

`--apply` inventories every expected MKV, uses Jellyfin's bundled `ffprobe` for stream validation, performs three short decode checks with bundled `ffmpeg`, creates only the three libraries with implicit refresh disabled, and initiates one explicit full-library refresh. The mode-`0600` completion marker prevents repeated apply from initiating another scan.

`--verify` repeats the non-mutating media probes, checks the exact library set, compares Jellyfin episode paths with the inventory, verifies one recognized series and a contiguous unique episode set, queries playback information for first/middle/final samples, and rechecks preservation and exposure controls.

## Deployment-local manifest and evidence

The operator creates ignored `runtime/state/libraries-media.conf` as a root-owned mode-`0600` file. It supplies the host and container path for the existing series, its expected Jellyfin title, a filename episode-number regular expression, expected count, and the already-configured metadata language/country. This keeps personal media names out of the public repository.

The report is written atomically to ignored `runtime/state/libraries-media-report.json`, mode `0600`. It records counts and container paths needed to compare disk inventory with Jellyfin, but no application password or API token. The container fingerprint baseline and one-scan marker are also ignored, root-readable runtime state.

If probing, naming, numbering, library emptiness, playback information, or preservation differs from the declared contract, the tool fails. Media remains untouched. Any rename proposal must be generated from runtime-only evidence, reviewed separately, collision checked, and include an exact reverse mapping before a later explicitly authorized operation may execute it.

## Scan and playback boundaries

Movies and TV Shows are expected to remain empty. Anime may contain only the declared existing copy. The scan does not trigger a media copy, rename, ownership change, checksum pass, full transcode, or watched-state update. The decode checks discard output and do not involve Jellyfin playback sessions. Playback-info results describe the server's expected Direct Play, remux, or transcode options; they are not proof of behavior for every client.

Hardware transcoding remains disabled. Verification does not enable a render device. The library mount remains read-only, direct Jellyfin and management ports remain non-public, and Caddy continues to be the sole public TCP 443 entry point.

## Recovery and limits

The tool writes a protected scan-start marker before the refresh request. An interruption before the completion marker blocks another apply and requires reviewing the protected report and Jellyfin scheduled-task state; it never assumes whether the interrupted scan completed. Library reconciliation is idempotent. After a confirmed successful scan, the completion marker makes apply verification-only.

Library setup does not rename media, configure metadata or subtitle providers, install plugins, change library options beyond name/type/path, manage DNS or certificates, alter firewall policy, touch the protected legacy disk, or start Sonarr adoption work.
