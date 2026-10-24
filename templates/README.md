# Safe templates

This directory contains tracked, non-secret source templates. configuration generation will render applicable files into the ignored `${RUNTIME_ROOT}/config/` tree after validating all inputs.

Rules:

- Templates contain placeholders, never installation credentials or machine-specific identifiers.
- Generated files that contain API keys or credentials belong under `${RUNTIME_ROOT}/secrets/` with mode `600`, not here.
- Application databases, caches, logs, certificates, and other mutable state belong under `${CONFIG_ROOT}`, outside Git.
- A future root-readable credentials summary will be generated under `${RUNTIME_ROOT}/secrets/`; it must never be committed or exposed through the control panel.
