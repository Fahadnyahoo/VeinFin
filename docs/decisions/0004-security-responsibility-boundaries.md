# ADR 0004: Security and responsibility boundaries

- Status: accepted
- Date: 2026-10-23

## Decision

VeinFin does not manage DNS or router configuration. It may use one configurable management username/password where applications support it. Application API keys remain absent until a verified bootstrap creates or captures them, and real API keys must remain unique. Secrets are generated locally and never embedded in Visit URLs.

## Rationale

Separating infrastructure ownership reduces privileges and prevents a reusable media installer from becoming a network-control plane. Unique API keys constrain credential reuse and support independent rotation even when human-facing credentials are intentionally simple.

## Consequences

Operators configure DNS and perimeter networking separately. The future control panel uses a restricted Docker socket proxy and receives no unrelated secrets. A root-readable credential summary remains outside Git and the web interface.
