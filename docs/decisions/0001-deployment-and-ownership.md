# ADR 0001: Linux host and operator ownership boundaries

- Status: accepted
- Date: 2026-10-23

## Decision

VeinFin targets a supported Linux Docker host. The repository contains reusable source; deployment-specific values stay in ignored local configuration. The operator supplies an existing media root and a hostname that already resolves correctly.

## Rationale

A conventional Linux and Docker contract keeps the installer portable and prevents it from taking ownership of unrelated infrastructure.

## Consequences

VeinFin validates storage availability but never formats, partitions, repairs, or automatically mounts it. VeinFin does not manage DNS or router configuration.
