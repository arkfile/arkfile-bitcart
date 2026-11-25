#!/usr/bin/env bash
# Shared helper library for arkfile-bitcart host lifecycle scripts.

set -euo pipefail

BITCART_USER="bitcart"
BITCART_HOME="/home/bitcart"
BITCART_SECRETS_DIR="${BITCART_HOME}/secrets"
BITCART_CONFIG_DIR="${BITCART_HOME}/config"
BITCART_QUADLET_DIR="${BITCART_HOME}/.config/containers/systemd"
OPERATOR_CONF="/etc/arkfile-bitcart/bitcart.conf"
CREDS_OUT_DIR="/root/arkfile-bitcart-credentials"

log_info() {
	printf '[i] %s\n' "$*"
}

log_ok() {
	printf '[OK] %s\n' "$*"
}

log_warn() {
	printf '[!] %s\n' "$*" >&2
}

log_err() {
	printf '[X] %s\n' "$*" >&2
}

die() {
	log_err "$*"
	exit 1
}

require_root() {
	if [[ "${EUID}" -ne 0 ]]; then
		die "This script must be run as root (for example: sudo bash $0)."
	fi
}

# Safely parse simple KEY=VALUE files without executing arbitrary shell code.
load_env_file() {
	local file_path="$1"
	[[ -f "${file_path}" ]] || die "Required file not found: ${file_path}"

	local line key val
	while IFS= read -r line || [[ -n "${line}" ]]; do
		# Strip trailing CR if present.
		line="${line%$'\r'}"
		# Skip blank lines and comments.
		[[ -z "${line//[[:space:]]/}" ]] && continue
		[[ "${line}" =~ ^[[:space:]]*# ]] && continue

		if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
			key="${BASH_REMATCH[1]}"
			val="${BASH_REMATCH[2]}"
			# Trim surrounding matching single or double quotes.
			if [[ "${val}" =~ ^\"(.*)\"$ ]]; then
				val="${BASH_REMATCH[1]}"
			elif [[ "${val}" =~ ^\'(.*)\'$ ]]; then
				val="${BASH_REMATCH[1]}"
			fi
			printf -v "${key}" '%s' "${val}"
		else
			die "Malformed line in ${file_path}: ${line}"
		fi
	done < "${file_path}"
}

load_operator_conf() {
	[[ -f "${OPERATOR_CONF}" ]] || die "Missing ${OPERATOR_CONF}. Copy bitcart.conf.example to ${OPERATOR_CONF} (chmod 0600) and fill in your values."
	local perms
	perms="$(stat -c '%a' "${OPERATOR_CONF}")"
	if [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
		log_warn "${OPERATOR_CONF} has mode ${perms}; restricting to 0600."
		chmod 0600 "${OPERATOR_CONF}"
	fi
	load_env_file "${OPERATOR_CONF}"
}

load_images_env() {
	local repo_root="$1"
	local images_file="${repo_root}/images.env"
	load_env_file "${images_file}"
	local var
	for var in IMAGE_DATABASE IMAGE_REDIS IMAGE_BITCOIN IMAGE_MONERO IMAGE_BACKEND IMAGE_CHECKOUT IMAGE_ADMIN IMAGE_GATEWAY; do
		[[ -n "${!var:-}" ]] || die "Missing ${var} in ${images_file}"
	done
}

has_crypto() {
	local target="$1"
	local list=",${BITCART_CRYPTOS:-btc,xmr},"
	list="${list// /}"
	[[ "${list}" == *",${target},"* ]]
}

reject_private_btc_key() {
	local label="$1"
	local key_val="$2"
	local lower_prefix
	lower_prefix="$(printf '%s' "${key_val:0:4}" | tr '[:upper:]' '[:lower:]')"
	case "${lower_prefix}" in
		xprv|yprv|zprv|tprv|uprv|vprv)
			die "${label} appears to be a private spending key (${lower_prefix}...). Watch-only public keys only."
			;;
	esac
}

validate_btc_xpub() {
	local label="$1"
	local key_val="$2"
	[[ -n "${key_val}" ]] || die "${label} must be set in ${OPERATOR_CONF}."
	reject_private_btc_key "${label}" "${key_val}"
	if [[ ! "${key_val}" =~ ^(xpub|ypub|zpub|Xpub|Ypub|Zpub)[1-9A-HJ-NP-Za-km-z]{60,}$ ]]; then
		die "${label} must be a valid mainnet watch-only extended public key (zpub, ypub, or xpub)."
	fi
}

validate_xmr_watch_only() {
	local prefix="$1"
	local addr_var="${prefix}_XMR_ADDRESS"
	local view_var="${prefix}_XMR_PRIVATE_VIEW_KEY"
	local height_var="${prefix}_XMR_RESTORE_HEIGHT"
	local addr="${!addr_var:-}"
	local view_key="${!view_var:-}"
	local restore_height="${!height_var:-}"

	[[ -n "${addr}" ]] || die "${addr_var} must be set when xmr is enabled."
	if [[ ! "${addr}" =~ ^4[1-9A-HJ-NP-Za-km-z]{94}$ ]]; then
		die "${addr_var} must be a mainnet Monero primary address starting with 4 (95 base58 characters)."
	fi
	[[ -n "${view_key}" ]] || die "${view_var} must be set when xmr is enabled."
	if [[ ! "${view_key}" =~ ^[0-9a-fA-F]{64}$ ]]; then
		die "${view_var} must be a 64-character hexadecimal private view key."
	fi
	if [[ -n "${restore_height}" && ! "${restore_height}" =~ ^[0-9]+$ ]]; then
		die "${height_var} must be a non-negative integer block height."
	fi
}

# True when this tenant prefix has any watch-only field set. Empty fields do
# not request the tenant. A partial set still requests it so validation can
# fail closed instead of provisioning from an incomplete config.
tenant_has_watch_only_keys() {
	local prefix="$1"
	local btc_var="${prefix}_BTC_XPUB"
	local addr_var="${prefix}_XMR_ADDRESS"
	local view_var="${prefix}_XMR_PRIVATE_VIEW_KEY"
	local height_var="${prefix}_XMR_RESTORE_HEIGHT"
	[[ -n "${!btc_var:-}" || -n "${!addr_var:-}" || -n "${!view_var:-}" || -n "${!height_var:-}" ]]
}

is_prod_tenant_enabled() {
	tenant_has_watch_only_keys "PROD"
}

is_test_tenant_enabled() {
	local flag="${ENABLE_TEST_TENANT:-false}"
	flag="$(printf '%s' "${flag}" | tr '[:upper:]' '[:lower:]')"
	if [[ "${flag}" == "true" ]]; then
		return 0
	fi
	# TEST_BTC_XPUB set implies test, as do any TEST_XMR_* watch-only fields.
	tenant_has_watch_only_keys "TEST"
}

validate_enabled_tenant() {
	local prefix="$1"
	local btc_var="${prefix}_BTC_XPUB"
	validate_btc_xpub "${btc_var}" "${!btc_var:-}"
	if has_crypto "xmr"; then
		validate_xmr_watch_only "${prefix}"
	fi
}

validate_operator_conf() {
	PAY_DOMAIN="${PAY_DOMAIN:-}"
	BITCART_CRYPTOS="${BITCART_CRYPTOS:-btc,xmr}"
	BTC_SERVER="${BTC_SERVER:-}"
	BTC_ONESERVER="${BTC_ONESERVER:-false}"
	XMR_SERVER="${XMR_SERVER:-}"
	BTC_TX_SPEED="${BTC_TX_SPEED:-1}"
	XMR_TX_SPEED="${XMR_TX_SPEED:-5}"
	BITCART_LOG_RETENTION_DAYS="${BITCART_LOG_RETENTION_DAYS:-21}"

	# Enforce mainnet-only configuration.
	if [[ -n "${BTC_NETWORK:-}" && "${BTC_NETWORK}" != "mainnet" ]]; then
		die "Only BTC_NETWORK=mainnet is supported."
	fi
	if [[ -n "${XMR_NETWORK:-}" && "${XMR_NETWORK}" != "mainnet" ]]; then
		die "Only XMR_NETWORK=mainnet is supported."
	fi

	[[ -n "${PAY_DOMAIN}" ]] || die "PAY_DOMAIN must be set in ${OPERATOR_CONF}."
	if [[ ! "${PAY_DOMAIN}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
		die "PAY_DOMAIN (${PAY_DOMAIN}) must be a valid public domain name."
	fi

	local cryptos_clean="${BITCART_CRYPTOS// /}"
	BITCART_CRYPTOS="${cryptos_clean}"
	case "${BITCART_CRYPTOS}" in
		btc|btc,xmr|xmr,btc) ;;
		*) die "BITCART_CRYPTOS (${BITCART_CRYPTOS}) must be btc or btc,xmr." ;;
	esac

	[[ -n "${BTC_SERVER}" ]] || die "BTC_SERVER must be set in ${OPERATOR_CONF}."
	case "${BTC_ONESERVER}" in
		true|false) ;;
		*) die "BTC_ONESERVER must be true or false." ;;
	esac

	if [[ ! "${BTC_TX_SPEED}" =~ ^[0-9]+$ ]] || (( BTC_TX_SPEED < 1 )); then
		die "BTC_TX_SPEED must be an integer >= 1 (Arkfile enforces >= 1 confirmation for BTC)."
	fi

	if [[ ! "${XMR_TX_SPEED}" =~ ^[0-9]+$ ]] || (( XMR_TX_SPEED < 5 )); then
		die "XMR_TX_SPEED must be an integer >= 5 (Arkfile enforces >= 5 confirmations for XMR)."
	fi

	if [[ ! "${BITCART_LOG_RETENTION_DAYS}" =~ ^[0-9]+$ ]] || (( BITCART_LOG_RETENTION_DAYS < 1 )); then
		die "BITCART_LOG_RETENTION_DAYS must be a positive integer."
	fi

	if has_crypto "xmr"; then
		[[ -n "${XMR_SERVER}" ]] || die "XMR_SERVER must be set when xmr is enabled."
	fi

	if ! is_prod_tenant_enabled && ! is_test_tenant_enabled; then
		die "At least one of prod or test watch-only keys is required in ${OPERATOR_CONF}."
	fi

	# Requested tenants must pass watch-only checks. Empty fields on a tenant
	# that was not requested are skipped. A partial requested tenant fails closed.
	if is_prod_tenant_enabled; then
		validate_enabled_tenant "PROD"
	fi
	if is_test_tenant_enabled; then
		validate_enabled_tenant "TEST"
	fi
}

get_bitcart_uid() {
	id -u "${BITCART_USER}"
}

ensure_bitcart_user_ready() {
	id -u "${BITCART_USER}" >/dev/null 2>&1 || die "Linux user ${BITCART_USER} does not exist. Run scripts/host-setup.sh first."
	local uid
	uid="$(get_bitcart_uid)"
	(( uid > 0 )) || die "User ${BITCART_USER} must be an unprivileged non-root account."

	if [[ ! -d "/run/user/${uid}" ]]; then
		systemctl start "user@${uid}.service"
	fi
	[[ -S "/run/user/${uid}/bus" ]] || die "systemd user bus missing at /run/user/${uid}/bus. Ensure loginctl enable-linger ${BITCART_USER} succeeded."
}

run_bitcart_podman() {
	ensure_bitcart_user_ready
	local uid
	uid="$(get_bitcart_uid)"
	# runuser keeps the caller's working directory. The bitcart user cannot enter /root.
	(
		cd /tmp || exit 1
		runuser -u "${BITCART_USER}" -- env \
			HOME="${BITCART_HOME}" \
			XDG_RUNTIME_DIR="/run/user/${uid}" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
			podman "$@"
	)
}

run_bitcart_systemctl() {
	ensure_bitcart_user_ready
	systemctl --user -M "${BITCART_USER}@" "$@"
}

verify_rootless_overlay() {
	local info_out
	info_out="$(run_bitcart_podman info --format '{{.Host.Security.Rootless}} {{.Store.GraphDriverName}}')"
	if [[ "${info_out}" != "true overlay" ]]; then
		die "Rootless Podman storage check failed: got '${info_out}', expected 'true overlay'. Refusing to proceed with vfs or rootful storage."
	fi
	log_ok "Rootless Podman verified as ${BITCART_USER}: ${info_out}"
}

generate_hex_secret() {
	openssl rand -hex 32
}

read_existing_key() {
	local file_path="$1"
	local target_key="$2"
	[[ -f "${file_path}" ]] || return 0
	local line
	while IFS= read -r line || [[ -n "${line}" ]]; do
		line="${line%$'\r'}"
		if [[ "${line}" == "${target_key}="* ]]; then
			printf '%s' "${line#*=}"
			return 0
		fi
	done < "${file_path}"
}

render_template() {
	local src="$1"
	local dst="$2"
	shift 2
	python3 - "${src}" "${dst}" "$@" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
with open(src, "r", encoding="utf-8") as fh:
    content = fh.read()
for pair in pairs:
    key, val = pair.split("=", 1)
    content = content.replace(key, val)
with open(dst, "w", encoding="utf-8") as fh:
    fh.write(content)
PY
}

write_bitcart_secret_file() {
	local target="$1"
	local tmp="${target}.tmp.$$"
	cat > "${tmp}"
	chown "${BITCART_USER}:${BITCART_USER}" "${tmp}"
	chmod 0600 "${tmp}"
	mv -f "${tmp}" "${target}"
}

ensure_generated_secrets_and_env() {
	install -d -m 0700 -o "${BITCART_USER}" -g "${BITCART_USER}" "${BITCART_SECRETS_DIR}"

	local pg_pass btc_pass xmr_pass super_pass prod_pass test_pass
	pg_pass="$(read_existing_key "${BITCART_SECRETS_DIR}/postgres.env" "POSTGRES_PASSWORD")"
	[[ -n "${pg_pass}" ]] || pg_pass="$(generate_hex_secret)"

	btc_pass="$(read_existing_key "${BITCART_SECRETS_DIR}/bitcoin.env" "BTC_PASSWORD")"
	[[ -n "${btc_pass}" ]] || btc_pass="$(read_existing_key "${BITCART_SECRETS_DIR}/bitcoin.env" "BTC_PASS")"
	[[ -n "${btc_pass}" ]] || btc_pass="$(generate_hex_secret)"

	xmr_pass="$(read_existing_key "${BITCART_SECRETS_DIR}/monero.env" "XMR_PASSWORD")"
	[[ -n "${xmr_pass}" ]] || xmr_pass="$(read_existing_key "${BITCART_SECRETS_DIR}/monero.env" "XMR_PASS")"
	[[ -n "${xmr_pass}" ]] || xmr_pass="$(generate_hex_secret)"

	super_pass="$(read_existing_key "${BITCART_SECRETS_DIR}/accounts.env" "SUPERADMIN_PASSWORD")"
	[[ -n "${super_pass}" ]] || super_pass="$(generate_hex_secret)"

	prod_pass="$(read_existing_key "${BITCART_SECRETS_DIR}/accounts.env" "PROD_ADMIN_PASSWORD")"
	[[ -n "${prod_pass}" ]] || prod_pass="$(generate_hex_secret)"

	test_pass="$(read_existing_key "${BITCART_SECRETS_DIR}/accounts.env" "TEST_ADMIN_PASSWORD")"
	[[ -n "${test_pass}" ]] || test_pass="$(generate_hex_secret)"

	write_bitcart_secret_file "${BITCART_SECRETS_DIR}/postgres.env" <<EOF
POSTGRES_USER=postgres
POSTGRES_DB=bitcart
POSTGRES_PASSWORD=${pg_pass}
EOF

	write_bitcart_secret_file "${BITCART_SECRETS_DIR}/bitcoin.env" <<EOF
IN_DOCKER=true
BTC_NETWORK=mainnet
BTC_LIGHTNING=false
BTC_SERVER=${BTC_SERVER}
BTC_ONESERVER=${BTC_ONESERVER}
BTC_LOGIN=btc_rpc
BTC_PASSWORD=${btc_pass}
BTC_USER=btc_rpc
BTC_PASS=${btc_pass}
EOF

	write_bitcart_secret_file "${BITCART_SECRETS_DIR}/monero.env" <<EOF
IN_DOCKER=true
XMR_NETWORK=mainnet
XMR_SERVER=${XMR_SERVER}
XMR_SEED_SERVER=
XMR_LOGIN=xmr_rpc
XMR_PASSWORD=${xmr_pass}
XMR_USER=xmr_rpc
XMR_PASS=${xmr_pass}
EOF

	write_bitcart_secret_file "${BITCART_SECRETS_DIR}/backend.env" <<EOF
BITCART_ENV=production
IN_DOCKER=true
LOG_LEVEL=INFO
BITCART_API_WORKERS=2
BITCART_CRYPTOS=${BITCART_CRYPTOS}
BTC_NETWORK=mainnet
BTC_LIGHTNING=false
XMR_NETWORK=mainnet
BITCART_HOST=${PAY_DOMAIN}
BITCART_HTTPS_ENABLED=true
BITCART_REVERSEPROXY=none
BITCART_BACKEND_ROOTPATH=/api
BITCART_AGENT_TRANSPORT=none
BITCART_ENABLE_SSH=false
DB_HOST=database
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=${pg_pass}
DB_DATABASE=bitcart
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_DB=0
BTC_HOST=bitcoin
BTC_LOGIN=btc_rpc
BTC_PASSWORD=${btc_pass}
BTC_USER=btc_rpc
BTC_PASS=${btc_pass}
XMR_HOST=monero
XMR_LOGIN=xmr_rpc
XMR_PASSWORD=${xmr_pass}
XMR_USER=xmr_rpc
XMR_PASS=${xmr_pass}
BITCART_DATADIR=/datadir
BITCART_BACKUPS_DIR=/backups
BITCART_BACKEND_PLUGINS_DIR=/plugins/backend
BITCART_ADMIN_PLUGINS_DIR=/plugins/admin
BITCART_STORE_PLUGINS_DIR=/plugins/store
BITCART_DOCKER_PLUGINS_DIR=/plugins/docker
EOF

	write_bitcart_secret_file "${BITCART_SECRETS_DIR}/checkout.env" <<EOF
ONE_DOMAIN_MODE=true
BITCART_API_URL=https://${PAY_DOMAIN}/api
BITCART_CHECKOUT_URL=https://${PAY_DOMAIN}
EOF

	write_bitcart_secret_file "${BITCART_SECRETS_DIR}/admin.env" <<EOF
ONE_DOMAIN_MODE=true
BITCART_ADMIN_ROOTPATH=/
BITCART_ADMIN_API_URL=http://127.0.0.1:29080/api
BITCART_ADMIN_SERVER_API_URL=http://backend:8000
EOF

	write_bitcart_secret_file "${BITCART_SECRETS_DIR}/accounts.env" <<EOF
SUPERADMIN_PASSWORD=${super_pass}
PROD_ADMIN_PASSWORD=${prod_pass}
TEST_ADMIN_PASSWORD=${test_pass}
EOF

	log_ok "Internal container secrets and environment files ensured under ${BITCART_SECRETS_DIR}"
}

install_configs_and_quadlets() {
	local repo_root="$1"

	install -d -m 0755 -o "${BITCART_USER}" -g "${BITCART_USER}" "${BITCART_CONFIG_DIR}"
	install -d -m 0755 -o "${BITCART_USER}" -g "${BITCART_USER}" "${BITCART_QUADLET_DIR}"

	install -m 0644 -o "${BITCART_USER}" -g "${BITCART_USER}" \
		"${repo_root}/caddy/Caddyfile.gateway" \
		"${BITCART_CONFIG_DIR}/Caddyfile.gateway"
	install -m 0644 -o "${BITCART_USER}" -g "${BITCART_USER}" \
		"${repo_root}/nginx/checkout-privacy.conf" \
		"${BITCART_CONFIG_DIR}/checkout-privacy.conf"

	local f base
	for f in "${repo_root}"/quadlets/*.network "${repo_root}"/quadlets/*.volume; do
		base="$(basename "${f}")"
		install -m 0644 -o "${BITCART_USER}" -g "${BITCART_USER}" "${f}" "${BITCART_QUADLET_DIR}/${base}"
	done

	local unit_templates=(
		bitcart-database
		bitcart-redis
		bitcart-bitcoin
		bitcart-backend
		bitcart-worker
		bitcart-checkout
		bitcart-gateway
		bitcart-admin
	)
	if has_crypto "xmr"; then
		unit_templates+=(bitcart-monero)
	else
		rm -f "${BITCART_QUADLET_DIR}/bitcart-monero.container"
	fi

	local unit dst
	for unit in "${unit_templates[@]}"; do
		dst="${BITCART_QUADLET_DIR}/${unit}.container"
		render_template "${repo_root}/quadlets/${unit}.container.template" "${dst}" \
			"__IMAGE_DATABASE__=${IMAGE_DATABASE}" \
			"__IMAGE_REDIS__=${IMAGE_REDIS}" \
			"__IMAGE_BITCOIN__=${IMAGE_BITCOIN}" \
			"__IMAGE_MONERO__=${IMAGE_MONERO}" \
			"__IMAGE_BACKEND__=${IMAGE_BACKEND}" \
			"__IMAGE_CHECKOUT__=${IMAGE_CHECKOUT}" \
			"__IMAGE_ADMIN__=${IMAGE_ADMIN}" \
			"__IMAGE_GATEWAY__=${IMAGE_GATEWAY}"
		chown "${BITCART_USER}:${BITCART_USER}" "${dst}"
		chmod 0644 "${dst}"
	done

	# Render and validate host Caddyfile.
	install -d -m 0755 /etc/caddy
	local tmp_caddy="/etc/caddy/Caddyfile.tmp.$$"
	render_template "${repo_root}/caddy/Caddyfile.host.template" "${tmp_caddy}" \
		"__PAY_DOMAIN__=${PAY_DOMAIN}"
	chmod 0644 "${tmp_caddy}"
	if ! caddy validate --config "${tmp_caddy}" --adapter caddyfile >/dev/null 2>&1; then
		caddy validate --config "${tmp_caddy}" --adapter caddyfile || true
		rm -f "${tmp_caddy}"
		die "Host Caddyfile validation failed."
	fi
	mv -f "${tmp_caddy}" /etc/caddy/Caddyfile
	if command -v restorecon >/dev/null 2>&1; then
		restorecon -F /etc/caddy/Caddyfile >/dev/null 2>&1 || true
	fi

	log_ok "Quadlet units, gateway Caddyfile, checkout privacy override, and host Caddyfile installed."
}

pull_stack_images() {
	local images=(
		"${IMAGE_DATABASE}"
		"${IMAGE_REDIS}"
		"${IMAGE_BITCOIN}"
		"${IMAGE_BACKEND}"
		"${IMAGE_CHECKOUT}"
		"${IMAGE_GATEWAY}"
		"${IMAGE_ADMIN}"
	)
	if has_crypto "xmr"; then
		images+=("${IMAGE_MONERO}")
	fi

	local img
	for img in "${images[@]}"; do
		log_info "Pulling rootless image as ${BITCART_USER}: ${img}"
		run_bitcart_podman pull "${img}"
	done
	log_ok "All required container images pulled."
}

seed_electrum_config() {
	local repo_root="$1"
	local helper_dst="${BITCART_CONFIG_DIR}/seed-btc-config.sh"
	install -m 0755 -o "${BITCART_USER}" -g "${BITCART_USER}" \
		"${repo_root}/scripts/seed-btc-config.sh" "${helper_dst}"

	if ! run_bitcart_podman volume exists bitcart-btc-data >/dev/null 2>&1; then
		run_bitcart_podman volume create bitcart-btc-data >/dev/null
	fi

	log_info "Seeding Electrum /data/config with auto_connect=false inside rootless user namespace..."
	run_bitcart_podman run --rm \
		--network none \
		--entrypoint /bin/sh \
		-v bitcart-btc-data:/data \
		-v "${helper_dst}:/usr/local/bin/seed-btc-config.sh:ro,Z" \
		"${IMAGE_BITCOIN}" \
		/usr/local/bin/seed-btc-config.sh
	log_ok "Electrum /data/config seeded with auto_connect=false."
}

wait_for_local_api() {
	local max_wait="${1:-120}"
	local elapsed=0
	log_info "Waiting for internal Bitcart API on http://127.0.0.1:29080/api/cryptos (timeout ${max_wait}s)..."
	while (( elapsed < max_wait )); do
		if curl -fsS --max-time 3 "http://127.0.0.1:29080/api/cryptos" >/dev/null 2>&1; then
			log_ok "Internal Bitcart API is ready."
			return 0
		fi
		sleep 2
		elapsed=$((elapsed + 2))
	done
	die "Timed out waiting for http://127.0.0.1:29080/api/cryptos after ${max_wait}s."
}
