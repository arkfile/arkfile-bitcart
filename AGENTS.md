# AGENTS.md

`NOTE: Agents, Agentic Coding Tools & LLMs must read this document to understand how to interact with and assist with this arkfile-bitcart project.`

# arkfile-bitcart: Overview for Agents

`arkfile-bitcart` is a standalone, security- and privacy-hardened deployment repository for hosting a mainnet-only Bitcart payment server on a small AlmaLinux 10 VPS (targeting 1 vCPU / 2 GB RAM) to process Bitcoin (BTC) and Monero (XMR) invoice top-ups for Arkfile deployments. Prod-only, test-only, and both are valid on the same Bitcart stack via separate non-superuser Bitcart merchant accounts. A tenant is provisioned only when that tenant's watch-only keys are set, and at least one tenant's watch-only keys are required. A test-only first deploy is how an operator validates the stack against a test Arkfile host before filling `PROD_*` keys. Filling the other tenant's keys later and running `scripts/update.sh` creates only the missing tenant and preserves the existing tenant's PostgreSQL data, wallets, store, and `invoice_management` token.

Maintaining strict privacy, zero visitor IP logging, and two-host separation from Arkfile is central to everything in this repository. The Bitcart host must never hold Arkfile application code, Arkfile user accounts, or username-to-invoice mappings. Arkfile sends Bitcart only a random invoice ID (as `order_id`), the USD amount, the store ID, and its webhook callback URL.

## Core Security and Privacy Invariants

**Rootless Podman only.** Never use Docker, never invoke `docker` commands, and never mount `/var/run/docker.sock` or any Podman socket into any container. All containers run rootless under the dedicated unprivileged `bitcart` Linux account via native systemd user Quadlets with `SELinux=enforcing` preserved (`:Z` labels on bind mounts) and `overlay` storage verified (never `vfs`). Any container-side helper script must check `/proc/self/uid_map` and abort if running in the host root user namespace.

**Mainnet only, external nodes only.** Never assume, configure, or document testnet, regtest, or stagenet anywhere in code, examples, or documentation (`BTC_NETWORK=mainnet`, `XMR_NETWORK=mainnet`). Never deploy blockchain full nodes (`bitcoind`, `electrs`, `fulcrum`, or `monerod`) on the VPS. Point Bitcart's lightweight watch-only RPC daemons strictly at operator-configured `BTC_SERVER` and `XMR_SERVER` URLs. Keep Electrum's `/data/config` seeded with `{"auto_connect": false}` so Bitcoin wallet subscriptions never silently fail over to random public peers and so `BTC_ONESERVER=true` does not trigger Electrum's `auto_connect` conflict.

**Watch-only keys only.** This host must never accept, generate, or store private spending keys or seed phrases. Always reject any `BTC_XPUB` starting with `xprv`, `yprv`, `zprv`, `tprv`, `uprv`, or `vprv` before making API calls. Monero wallets use only a mainnet primary address, private view key, and restore height.

**Zero visitor IP logging and minimal metadata.** Both Caddy hops (host Caddy and internal gateway Caddy) must discard access logs and strip `X-Forwarded-For`, `X-Real-IP`, and `Forwarded` headers before proxying. Host Caddy enforces TLS 1.3 via stock automatic Let's Encrypt (no custom `xcaddy` or DNS API tokens) and sets `Strict-Transport-Security`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, and `X-Frame-Options: DENY`. `bitcart-checkout` mounts a read-only Nginx override with `access_log off;` so checkout URLs and browser `User-Agent` strings are never written to journald. Bitcart's `log_retention_days` policy stays capped (default `21`).

**Strict public API surface and SSH-only admin UI.** Public `https://<PAY_DOMAIN>` serves only checkout static paths and the exact HTTP methods and API routes required by Arkfile and Bitcart Checkout. Everything else must return `404` publicly, including `/`, `/admin*`, `POST /api/invoices/batch` (so a leaked `invoice_management` token cannot invoke `mark_complete`), `GET /api/invoices/export`, unauthenticated `PATCH /api/invoices/{id}/customer` and `/details`, `/api/token*`, `/api/users*`, `/api/wallets*`, `/api/backups*`, `/api/plugins*`, `/api/configurator*`, and mutating `/api/manage*` endpoints. Full admin and management access lives exclusively on `127.0.0.1:29080` over SSH port-forwarding, with `bitcart-admin` kept as an optional on-demand systemd unit.

**Network segmentation and daemon isolation.** Keep the three rootless Podman networks intact: `bitcart-edge` (`gateway`, `checkout`, `admin`, `backend`), `bitcart-data` with `Internal=true` (`database`, `redis`, `backend`, `worker`), and `bitcart-coins` (`bitcoin`, `monero`, `backend`, `worker`). Enforce password authentication on PostgreSQL, replace Bitcart's default `electrumz` RPC credentials with generated 32-byte secrets (`BTC_PASS`, `XMR_PASS`), disable Bitcart's host agent and SSH hooks (`BITCART_AGENT_TRANSPORT=none`, `BITCART_ENABLE_SSH=false`), and preserve the outbound `firewalld` block on cloud metadata (`169.254.169.254/32`).

**Multi-tenant isolation and confirmation floors.** Prod-only, test-only, and both are valid. A tenant is provisioned only when its watch-only keys are present, at least one tenant is required, and a partial tenant config fails closed. `prod` and `test` must always be non-superuser Bitcart accounts (`is_superuser: false`); `superadmin` is never used to issue Arkfile API tokens. Do not create a tenant that was not requested, and do not delete an existing tenant, store, wallet, token, or credential file when that tenant is skipped. Preserve Bitcart's required confirmation settings (`BTC_TX_SPEED >= 1` on stores, `XMR_TX_SPEED >= 5` on Monero wallets, `underpaid_percentage: 0`, `email_required: false`, `allow_anonymous_invoice_creation: false`, `expiration: 60`) because Arkfile enforces `>= 1` confirmation for BTC and `>= 5` confirmations for XMR at invoice creation time.

**Domain-neutral repository.** Keep all tracked config templates, scripts, and documentation domain-neutral using generic example domains (`pay.example.com`, `files.example.com`, `test.example.com`). Real deployment domains, wallet keys, passwords, and tokens live exclusively on the VPS under `/etc/arkfile-bitcart/`, `/home/bitcart/secrets/`, and `/root/arkfile-bitcart-credentials/` with `0600` permissions.

## Existing Data and Non-Destructive Operations

A deployed VPS holds live PostgreSQL invoice history, watch-only wallet state, generated internal credentials, and active Arkfile API tokens. Changes to deployment, update, or provisioning scripts must be non-destructive to existing deployments:

- `scripts/update.sh` and `scripts/provision.sh` must preserve PostgreSQL volumes, watch-only wallet state, existing store IDs (resolving stores by saved `BITCART_STORE_ID` before falling back to store name so `PROD_STORE_NAME` / `TEST_STORE_NAME` updates rename stores in place), and existing valid `invoice_management` tokens unless `--rotate-tokens` is explicitly passed.
- A test-only first deploy is valid and is how an operator validates the stack against a test Arkfile host before filling `PROD_*` keys. On a later `scripts/update.sh`, filling the other tenant's watch-only keys creates only the missing tenant and must preserve the existing tenant's PostgreSQL data, wallets, store, and `invoice_management` token. Prod-only (`PROD_*` set, `ENABLE_TEST_TENANT=false`, `TEST_*` empty) must keep working, and routine verification must still refuse a default live prod invoice.
- Routine `scripts/verify.sh` checks must not create live invoices against the `prod` store by default, so repeated updates never burn through Bitcoin's 20-address BIP84 gap limit. When test is enabled, one live test-store invoice is created. `--check-prod-invoice` creates a live prod invoice only when prod is enabled, and must fail if prod is not enabled.
- Keep `BITCART_*_PLUGINS_DIR` variables pointed inside `/plugins/...` so `bitcart/bitcart` under `gosu electrum` never crashes during Alembic migrations with `PermissionError`.
- Note that `worker` logging a caught `RendererUnavailableError` after `Sending IPN ... success` is expected because the optional chat/email template renderer sidecar is intentionally omitted.

## Implementation and Review Preferences

Prefer the simplest correct configuration or shell script that meets current operational needs. Avoid premature abstraction, unnecessary wrapper tools, or extra sidecar containers that bloat RAM on a 2 GB VPS.

Before finalizing edits to scripts or unit files, check:
- Does this change preserve rootless isolation, SELinux enforcing mode, zero IP logging, and the strict `:28080` route boundary?
- Is it idempotent when re-run against an already provisioned VPS?
- Does it keep RAM usage within the 2 GB VPS budget and per-unit `MemoryMax=` limits?
- Did you validate shell scripts with `bash -n` (and `shellcheck` if available) and inspect Quadlet and Caddyfile syntax?

## Operational Boundaries for Agents

**Do not invoke lifecycle deployment commands yourself.** Ask the operator to run `scripts/host-setup.sh`, `scripts/deploy.sh`, `scripts/update.sh`, `scripts/provision.sh`, `scripts/verify.sh`, or `scripts/backup.sh` on the target host as appropriate.

**Using Podman.** Never invoke `podman` commands without the explicit consent of the developer for each invocation, and never run rootful `podman`.

**Using Git.** Do not add files to git, create commits, or push branches yourself at any time. That is strictly up to the developer.

## Formatting and Communication Rules

- **No emojis** in any code, scripts, comments, logs, documentation, or responses. Use `[OK]`, `[X]`, `[!]`, or `SUCCESS!` instead.
- **No em-dashes.** Use double-dashes (`--`) only.
- **Document formatting.** Do not add hard line breaks within markdown paragraphs; keep each paragraph on a single continuous line so editors wrap text naturally.
- **Comment and log formatting.** Do not use `===` or `---` banners inside log statements or short comments. Keep comments concise and focused on established behavior, with no references to ephemeral planning IDs, phases, or tiers.
- **Language.** Avoid terms like `allowlist` or `denylist`; use plain descriptive terms such as `permitted_routes`, `blocked_paths`, or `public_api_paths`.
- **Responses in chat.** Prefer paragraph format over heavy jargon, and be direct and transparent about any security, privacy, or reliability trade-offs discovered during work.
```