# Security Policy

## Supported Versions

Security fixes apply to the latest release on the `main` branch (`assemblrr upgrade`).

## Reporting a Vulnerability

Please do **not** open a public GitHub issue with exploit details for an unpatched vulnerability.

Report security issues privately via GitHub Security Advisories or private contact with the repository maintainer (`soulis-1256`). Include:

- Affected script, service overlay, or API endpoint
- Reproduction steps or minimal proof of concept
- Potential impact (e.g., credential exposure, privilege boundary bypass, command injection)

## Security Architecture Highlights

- **Secret isolation**: Service credentials and API tokens live under `secrets/` (`0700` directory, `0600` files), never embedded in `.env` or container compose YAML.
- **No `eval`/`source` on untrusted config**: Config files are loaded via `safe_source` (`lib/paths.sh`), which parses literal `KEY=VALUE` assignments line-by-line and rejects command substitution or code execution.
- **Authenticated request-delete gateway**: `scripts/seerr-gateway.py` resolves caller identity and permissions against `GET /api/v1/auth/me` before invoking privileged Sonarr/Radarr APIs and fails closed (`502`/`403`) on missing or unauthorized sessions.
- **Safe curl usage**: Secrets are passed via headers or `--form-string` rather than raw `-F` file/stdin triggers.
