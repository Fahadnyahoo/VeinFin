# VeinFin contributor instructions

These rules apply throughout the repository.

## Scope

- Preserve user files and unrelated changes.
- Do not push to a remote unless the owner explicitly requests it.
- Keep changes focused, reversible, and documented.
- Treat remote audits as read-only unless a request explicitly authorizes changes.

## Safety

- Never print, expose, or commit passwords, tokens, API keys, private keys, or generated credentials.
- Never format, partition, erase, initialize, repair, or automatically mount storage.
- Do not modify DNS providers, router configuration, or unrelated infrastructure.
- Keep public exposure limited to the documented endpoints.

## Repository boundaries

- Commit reusable code, templates, tests, and documentation only.
- Keep `.env`, secrets, state, backups, generated configuration, databases, logs, and private keys out of Git.
- Keep addresses, hostnames, IDs, time zones, paths, and credentials configurable.
- Do not add operator infrastructure, media names, machine audits, personal endpoints, or workstation-specific instructions.
- Prefer pinned versions, idempotent operations, least privilege, and verified rollback.
- Never mount the unrestricted Docker socket into the control panel.
- Experimental integrations must remain disabled and excluded from the default installer.

## Validation

- Run the relevant focused tests and static validators.
- Run `git diff --check` when Git metadata is available.
- Review changes for secrets, machine-specific values, stale names, security contradictions, and unsupported claims.
