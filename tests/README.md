# Static validation

Run from the repository root:

```sh
ruby tests/validate-compose.rb
tests/test-firewall.sh
tests/test-jellyfin-deployment.sh
tests/test-qbittorrent-deployment.sh
tests/test-arr-deployment.sh
git diff --check
```

The validators use existing shell tools and Ruby's standard library and install nothing. Static tests enforce the image-lock, exposure, credential, and hardlink-compatible mount contracts. `scripts/verify-image-lock.rb` can query official registries without changing the lock. Runtime health, actual hardlink creation, and application bootstrap still require an authorized deployment operation.

`tests/test-host-preparation.sh` uses mocked host commands and temporary roots to test the Debian preparation script without installing packages or changing the development host.

`tests/test-firewall.sh` sources the firewall implementation in library mode and uses only temporary fixtures and generated rule text. It never invokes the Mac packet filter, changes routes, opens sockets, contacts SSH, or calls systemd. Live target verification is a separate guarded operator procedure documented in `docs/FIREWALL.md`.

`tests/test-arr-deployment.sh` validates the ARR deployment service selection, loopback and mount contracts, API-key handling, Docker-DNS endpoints, exact categories/roots, no-content boundaries, hardlink cleanup, and read-only check mode using temporary local paths.

`tests/test-jellyfin-deployment.sh` uses temporary fixtures and mocked deployment functions. It never calls the local Docker daemon, changes host networking, or touches media storage. Live deployment verification is documented in `docs/JELLYFIN.md`.

`tests/test-qbittorrent-deployment.sh` similarly uses temporary fixtures and mocked deployment functions. It validates loopback, image, mount, credential, path/category, listener, and exact-service contracts without starting qBittorrent or creating a torrent. Live bootstrap verification is documented in `docs/QBITTORRENT.md`.

`tests/test-quality-profiles.sh` and `tests/test_quality_profiles.py` validate the exact quality ladders, HDR/Dolby Vision/AV1/Remux/low-quality rejection policy, protected generation, official-preview drift gate, future Seerr defaults, preservation checks, idempotence, and rollback structure entirely offline. They do not contact an application or run Recyclarr.

`tests/test-download-lifecycle.sh` and `tests/test_download_lifecycle.py` validate exact qBittorrent OR/Stop policy encoding, fail-closed cleanup eligibility, complete hardlink evidence, unimported/partial/active refusal, path traversal and symlink rejection, protected atomic output, configuration-only apply, preview safety, idempotence, and rollback structure entirely offline. The deferred synthetic helper is not called by the deployment or installer; these tests do not create a live torrent or touch media.

`tests/test-control-panel.sh` and `tests/test_control_panel.py` validate the panel/agent socket boundary, exact service/action allowlist, authentication primitives, session expiration, CSRF and Origin checks, rate limiting, credential-free Visit URLs, immutable reproducible-build contract, management-only firewall transition, installer stage order, and idempotent completion behavior without accessing Docker locally.
