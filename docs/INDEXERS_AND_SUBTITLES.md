# Public indexers and subtitle-provider foundation

Indexer and subtitle setup adds an API-only, reversible foundation for public indexers and subtitle languages. It does not search, grab, download, scan, import, rename, move, or delete media.

## Operator interface

```bash
sudo --preserve-env=SSH_CONNECTION scripts/deploy/indexers-subtitles.sh --check
sudo --preserve-env=SSH_CONNECTION scripts/deploy/indexers-subtitles.sh --apply
sudo --preserve-env=SSH_CONNECTION scripts/deploy/indexers-subtitles.sh --verify
sudo --preserve-env=SSH_CONNECTION scripts/deploy/indexers-subtitles.sh --rollback
```

`--check` is read-only. It validates nine healthy zero-restart containers, API authentication, the existing Sonarr/Radarr/Bazarr content state, zero torrents, zero Bazarr wanted/history activity, application synchronization, listeners, firewall policy, HTTPS, and Docker API protection.

The first `--apply` creates protected online SQLite backups and configuration copies for Prowlarr and Bazarr. It resolves candidates from the live Prowlarr schema bundled with the pinned image, rejects credential-bearing definitions, runs Prowlarr's official connection test, and enables only candidates that pass. It then requests Prowlarr's application-indexer synchronization and tests the existing Sonarr and Radarr connections. A repeated apply is verification-only.

`--verify` checks the exact indexers recorded in ignored protected state, each connection, category-dependent Arr synchronization, scoped FlareSolverr tagging, exact Bazarr profiles/providers, and all preservation guards. `--rollback` restores the captured API-visible state without deleting the protected backup. Database/configuration copies are last-resort recovery material and are not written back automatically because that would require a separately reviewed container stop.

## Indexer policy

The workflow considers at most Nyaa.si, 1337x, and TorrentGalaxy. A definition must be public, bundled with the locked Prowlarr release, credential-free, and pass the official connection test at deployment time. Unavailable or failed candidates remain absent. It never substitutes mirrors, disables TLS checks, adds custom definitions, or enables YTS, Jackett, private trackers, or account-backed sources.

FlareSolverr is never applied globally. A candidate receives the existing dedicated proxy tag only when its live bundled schema explicitly advertises FlareSolverr handling. FlareSolverr remains private to the application network with no host port or media mount.

Only declared categories determine synchronization. Anime sources with declared movie categories may synchronize to Radarr; otherwise anime-only sources are limited to Sonarr. Synchronization does not run a release search.

## Bazarr policy

Three unassigned language profiles are created: Movies, TV, and Anime. Each requests normal Arabic and English subtitles, with no forced-only, hearing-impaired-only, machine-translated, cutoff-upgrade, or automatic synchronization behavior.

The pinned Bazarr provider implementation is inspected before deployment. Indexer and subtitle setup permits at most two credential-free capabilities: local Embedded Subtitles and the bundled public SubtitleCat provider. Account/API-key providers remain disabled. SubtitleCat machine-translated results remain disabled. If the pinned schemas change, apply stops.

Profiles deliberately remain unassigned during indexer and subtitle setup. Bazarr's profile-assignment endpoint immediately recalculates missing subtitles, while recognizing existing embedded tracks would require a media scan. Both operations are outside this workflow. Enabling Embedded Subtitles only preserves that future capability; it does not inspect or extract a media stream.

## Protected state and recovery

Ignored root-owned mode-`0700` state is placed below `runtime/backups/indexers_subtitles-apps-before/` and `runtime/state/`. Backup files, API snapshots, reports, baselines, and markers are mode `0600`. SQLite's online backup API produces consistent database copies and verifies them with `PRAGMA integrity_check`. Temporary output is atomically replaced.

An interrupted apply leaves a protected start marker and blocks further mutation. Review the preserved backup and use `--rollback`. A failed first apply automatically attempts API rollback and verifies the empty baseline. Secrets remain in existing protected files and are never logged or included in URLs.

Indexer and subtitle setup changes no Compose service, image, listener, firewall rule, certificate, DNS setting, router setting, plugin, media file, quality profile, download client, or container lifecycle. Who's Watching remains deferred, unsupported, and absent. Quality profile setup is not included.
