# arkfile-bitcart

`arkfile-bitcart` is a standalone, security- and privacy-hardened deployment repository for hosting a mainnet-only Bitcart payment server (`pay.example.com` or any operator-supplied domain) on a small AlmaLinux 10 VPS (targeting 1 vCPU / 2 GB RAM) to process Bitcoin (BTC) and Monero (XMR) invoice top-ups for Arkfile deployments. It supports a primary `prod` tenant (`files.example.com`) and an optional isolated `test` tenant (`test.example.com`) on the same Bitcart stack using separate non-superuser Bitcart merchant accounts.

## Architecture and Security Model

This repository enforces strict two-host separation between Arkfile and Bitcart. The Bitcart VPS never holds Arkfile application code, Arkfile user accounts, or username-to-invoice mappings. Arkfile sends Bitcart only a random invoice ID (as `order_id`), the USD amount, the store ID, and its webhook callback URL.

All application containers run strictly in rootless Podman under a dedicated unprivileged `bitcart` Linux account managed by native systemd user Quadlets under `/home/bitcart/.config/containers/systemd/`. Docker is never used, no container socket is ever mounted, `SELinux=enforcing` is preserved across all bind mounts (`:Z`), and `overlay` storage is verified before startup (`vfs` is rejected).

Container traffic is segmented across three rootless Podman networks so edge proxies have zero reachability to databases or coin RPC daemons and internal data services have zero outbound internet egress:

- `bitcart-edge`: `gateway`, `checkout`, `admin` (on-demand), `backend`.
- `bitcart-data` (`Internal=true`): `database`, `redis`, `backend`, `worker`.
- `bitcart-coins`: `bitcoin`, `monero` (when `xmr` is enabled), `backend`, `worker`.

PostgreSQL enforces password authentication with a generated 32-byte secret, and both watch-only coin RPC daemons replace Bitcart's default `electrum` / `electrumz` credentials with generated 32-byte secrets (`BTC_LOGIN`/`BTC_PASSWORD` and `XMR_LOGIN`/`XMR_PASSWORD`). Upstream Bitcart (`api/settings.py`) reads `REDIS_HOST`, `REDIS_PORT`, and `REDIS_DB` without a separate `REDIS_PASSWORD` setting, so `redis` is kept strictly isolated on the `Internal=true` `bitcart-data` network with `--protected-mode yes`, no persistence, and no published host ports. Bitcart's host agent and SSH hooks are disabled (`BITCART_AGENT_TRANSPORT=none`, `BITCART_ENABLE_SSH=false`), and `firewalld` blocks outbound host and container egress to cloud metadata (`169.254.169.254/32`).

### Zero Visitor IP Logging and Strict Public API Surface

Both Caddy hops -- host `caddy.service` on ports `80`/`443` and the internal rootless `gateway` container on `127.0.0.1:28080` -- discard access logs (`log { output discard }`) and strip `X-Forwarded-For`, `X-Real-IP`, and `Forwarded` before proxying. Host Caddy uses stock automatic Let's Encrypt (HTTP-01 / TLS-ALPN-01, TLS 1.3 enforced, no custom `xcaddy` build or DNS API tokens) and sets `Strict-Transport-Security`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, and `X-Frame-Options: DENY`. `bitcart-checkout` mounts `nginx/checkout-privacy.conf` (`access_log off;`) read-only so checkout URLs and browser `User-Agent` strings are never written to journald, and Bitcart's `log_retention_days` policy is capped (default `21`).

Public `https://pay.example.com` proxies exclusively to `127.0.0.1:28080`, which enforces strict positive method-and-path matching for checkout static assets (`/i/*`, `/checkout/*`, `/embed/*`, `/modal/*`, `/refunds/*`) and the exact `public_api_paths` required by Arkfile and Bitcart Checkout (`POST /api/invoices`, `GET /api/invoices/count`, `GET /api/invoices/{id}`, `GET /api/stores/{id}`, `GET /api/stores/{id}/rates`, `GET /api/ws/invoices/{id}`, `GET /api/manage/policies`, `GET /api/cryptos*`, and `GET /api/tor/services`). Every other path and method returns `404` publicly, including `/`, `/admin*`, `POST /api/invoices/batch` (preventing a leaked `invoice_management` token from calling `mark_complete`), `GET /api/invoices/export`, unauthenticated `PATCH /api/invoices/{id}/customer` and `/details`, `/api/token*`, `/api/users*`, `/api/wallets*`, `/api/backups*`, `/api/plugins*`, and mutating `/api/manage*` routes. Full API and optional admin UI access lives strictly on `127.0.0.1:29080` over SSH port forwarding.

### External Node Privacy and Integrity Trade-Offs

This VPS never runs local blockchain full nodes (`bitcoind`, `electrs`, `fulcrum`, or `monerod`). Bitcart's lightweight watch-only daemons connect strictly to operator-configured external servers (`BTC_SERVER` and `XMR_SERVER`, mainnet only). Operators should understand two honest trade-offs when using third-party public nodes instead of self-hosted nodes:

- **Bitcoin (`BTC_SERVER`):** A third-party Electrum server observes the set of derived Bitcoin addresses (scripthashes) queried by your watch-only wallet and can link those addresses together as belonging to the same server. Before starting `bitcoin`, `scripts/deploy.sh` and `scripts/update.sh` always seed `{"auto_connect": false}` into Electrum's `/data/config` so wallet subscriptions never silently fail over to random public peers. Leaving `BTC_ONESERVER=false` (the default for public Electrum servers) lets Electrum cross-check SPV block headers across peers without leaking wallet scripthashes to other servers. If you run your own private Electrum server (such as Fulcrum or electrs), point `BTC_SERVER` at it and set `BTC_ONESERVER=true` so both privacy and header trust stay entirely under your control.
- **Monero (`XMR_SERVER`):** Because `bitcart-xmr` scans blocks locally with your private view key inside the container, a remote Monero daemon cannot see your private view key, your wallet addresses, or which outputs belong to you. However, because the VPS does not perform local RandomX proof-of-work verification, you trust the remote daemon(s) listed in `XMR_SERVER` (comma-separated list supported) to report honest block heights and transaction inclusion. Running your own remote `monerod` and setting `XMR_SERVER` to it removes that trust assumption.

## Prerequisites

1. **VPS:** Provision a fresh AlmaLinux 10 x86_64 VPS with at least 1 vCPU, 2 GB RAM, and 20 GB disk on any standard VPS provider, with `SELinux=enforcing` active. `scripts/host-setup.sh` creates a 2 GiB `/swapfile` (`vm.swappiness=20`) automatically if swap is not already configured.
2. **DNS:** Create a public `A` record (and optional `AAAA` record) pointing `pay.example.com` to your VPS IP address and wait for propagation before running `scripts/deploy.sh` so host Caddy can obtain a Let's Encrypt TLS 1.3 certificate.
3. **Watch-Only Mainnet Wallet Keys:** Prepare watch-only keys offline on your own hardware or software wallet. Never put private spending keys (`xprv`, `yprv`, `zprv`, `tprv`, `uprv`, `vprv`) or seed phrases on this VPS.
   - **Bitcoin:** Export a mainnet BIP84 watch-only account extended public key (`zpub...`). If you enable the optional `test` tenant, use a separate BIP84 account `zpub` (for example `m/84'/0'/1'`) so `prod` and `test` invoice addresses and BIP84 gap limits remain completely independent.
   - **Monero:** Export the mainnet primary address (starts with `4`, 95 characters), private view key (64 hexadecimal characters), and a recent integer block restore height. If you enable the optional `test` tenant, use a separate Monero wallet/account from `prod`.

## Initial Deployment

Clone this repository onto the AlmaLinux 10 VPS, copy `bitcart.conf.example` to `/etc/arkfile-bitcart/bitcart.conf` with mode `0600`, and populate your domain and watch-only wallet keys:

```bash
sudo install -d -m 0700 /etc/arkfile-bitcart
sudo install -m 0600 bitcart.conf.example /etc/arkfile-bitcart/bitcart.conf
sudoedit /etc/arkfile-bitcart/bitcart.conf
```

Keep `BTC_TX_SPEED >= 1` and `XMR_TX_SPEED >= 5` in `/etc/arkfile-bitcart/bitcart.conf` because Arkfile enforces at least 1 confirmation for BTC and at least 5 confirmations for XMR at invoice creation time. To enable an isolated `test` tenant alongside `prod`, set `ENABLE_TEST_TENANT=true` and populate `TEST_BTC_XPUB` (and `TEST_XMR_*` when `xmr` is enabled).

Run the deployment orchestrator (add `--check-prod-invoice` on initial setup if you want `scripts/verify.sh` to create one live test invoice against `prod` to confirm end-to-end checkout rendering and confirmation floors):

```bash
sudo bash scripts/deploy.sh --check-prod-invoice
```

`scripts/deploy.sh` performs host setup, verifies rootless `overlay` storage, generates internal secrets under `/home/bitcart/secrets/` (`0600`), installs Quadlet units and Caddy configs, seeds Electrum's `/data/config`, starts the stack, provisions the isolated Bitcart accounts (`superadmin@pay.internal`, `prod@pay.internal`, and optionally `test@pay.internal`), writes ready-to-copy Arkfile snippets under `/root/arkfile-bitcart-credentials/` (`0600`), and runs `scripts/verify.sh`.

## Connecting Arkfile Deployments

Read the generated mode-`0600` credential snippets on the Bitcart VPS:

```bash
sudo cat /root/arkfile-bitcart-credentials/prod-secrets.env
# If the optional test tenant is enabled:
sudo cat /root/arkfile-bitcart-credentials/test-secrets.env
```

Copy the `BITCART_API_URL`, `BITCART_CHECKOUT_URL`, `BITCART_STORE_ID`, and `BITCART_API_TOKEN` lines into `/opt/arkfile/etc/secrets.env` on your production Arkfile host (`files.example.com`) and, if enabled, the `test` snippet onto your test Arkfile host (`test.example.com`). Apply the configuration on each Arkfile host using your standard deployment script (`prod-update.sh`, `test-update.sh`, or `local-deploy.sh`), then run `arkfile-admin payments check` on each Arkfile host to confirm end-to-end API connectivity and store configuration.

Note that `bitcart-worker` logging a caught `RendererUnavailableError` immediately after `Sending IPN ... success` is expected because the optional chat/email template renderer sidecar is intentionally omitted to save RAM on a 2 GB VPS.

## Accessing the Admin UI Over SSH

`bitcart-admin` is installed as an optional on-demand unit and stays stopped by default to save RAM and eliminate idle Node/Nuxt attack surface. When you need the Bitcart Admin UI (for example to inspect an invoice or enable TOTP 2FA on `superadmin@pay.internal`), start the unit on the VPS, forward port `29080` over SSH, and stop the unit again when finished:

```bash
# On the Bitcart VPS:
sudo systemctl --user -M bitcart@ start bitcart-admin
sudo cat /home/bitcart/secrets/accounts.env

# On your local workstation:
ssh -L 29080:127.0.0.1:29080 root@<vps-ip>
```

Open `http://127.0.0.1:29080` in your local browser while the SSH tunnel is active. When done, stop `bitcart-admin` on the VPS:

```bash
sudo systemctl --user -M bitcart@ stop bitcart-admin
```

If you enable TOTP 2FA on `superadmin@pay.internal`, routine `scripts/update.sh` runs continue to work cleanly because `scripts/provision.sh` uses a fast-path check with existing tenant tokens and skips `superadmin` login whenever stores, settings, and tokens are already valid.

## Pinning Image Digests and Updating

To pin all image references in `images.env` to immutable `@sha256` digests on the host:

```bash
sudo bash scripts/pin-digests.sh
```

To apply updated images or configuration changes non-destructively while preserving PostgreSQL volumes, watch-only wallet state, internal credentials, and existing valid Arkfile API tokens:

```bash
sudo bash scripts/update.sh
```

By default, `scripts/update.sh` runs `scripts/verify.sh` without creating live invoices against the `prod` store so repeated updates never burn through Bitcoin's 20-address BIP84 gap limit. Existing valid Arkfile API tokens are preserved unless `--rotate-tokens` is explicitly passed.

## Backups and Restore

`scripts/backup.sh` performs a live, non-disruptive `pg_dump` through the rootless `database` container and bundles the SQL dump together with `/home/bitcart/secrets/` and `/etc/arkfile-bitcart/bitcart.conf` into a mode-`0600` timestamped archive under `BACKUP_DIR` (default `/var/backups/arkfile-bitcart`), pruning archives older than `BACKUP_RETENTION_DAYS` (default `14`):

```bash
sudo bash scripts/backup.sh
```

If you set `BACKUP_AGE_RECIPIENT` (requiring `age`) or `BACKUP_GPG_RECIPIENT` (requiring `gpg`) in `/etc/arkfile-bitcart/bitcart.conf`, `scripts/backup.sh` encrypts the archive automatically before saving it. Schedule `scripts/backup.sh` via root cron or a systemd timer and pull the resulting files off-VPS over SSH using `rsync` or `scp` (for example `rsync -av root@<vps-ip>:/var/backups/arkfile-bitcart/ ./backups/`).

To restore on a fresh AlmaLinux 10 VPS:

1. Decrypt (if encrypted) and unpack the backup archive into a mode-`0700` temporary directory.
2. Restore `/etc/arkfile-bitcart/bitcart.conf` (`chmod 0600`) and run `sudo bash scripts/host-setup.sh`.
3. Copy the backed-up `secrets/*` files into `/home/bitcart/secrets/` (`chown -R bitcart:bitcart /home/bitcart/secrets && chmod 0600 /home/bitcart/secrets/*`).
4. Run `sudo bash scripts/deploy.sh` to install Quadlets, start `bitcart-database.service`, and verify storage.
5. Stop `bitcart-backend.service` and `bitcart-worker.service` (`sudo systemctl --user -M bitcart@ stop bitcart-backend bitcart-worker`), load the SQL dump into the rootless database container (`sudo runuser -u bitcart -- env XDG_RUNTIME_DIR=/run/user/$(id -u bitcart) podman exec -i database psql -U postgres -d bitcart < bitcart-postgres.sql`), restart the stack (`sudo bash scripts/update.sh`), and confirm all checks in `scripts/verify.sh` pass.
