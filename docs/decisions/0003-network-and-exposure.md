# ADR 0003: Docker network and exposure boundaries

- Status: accepted
- Date: 2026-10-23

## Decision

Use a proxy-facing network for Caddy and Jellyfin and a separate application network for required service communication. Publish public TCP 443 only from Caddy. Bind private management interfaces to a configurable host address. Do not publish Jellyfin 8096, FlareSolverr 8191, or TCP 80. LAN discovery is an explicit optional override.

## Rationale

This keeps public ingress narrow, prevents accidental host exposure of internal services, and still permits name-based application communication and required internet egress.

## Consequences

Jellyfin bridges the two networks. Prowlarr addresses FlareSolverr as `http://flaresolverr:8191`. The host firewall must restrict management sources; Compose bindings alone are not the complete access-control policy.
