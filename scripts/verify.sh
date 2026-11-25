#!/usr/bin/env bash
# Automated security, privacy, confirmation-floor, and cross-tenant isolation
# verification script for arkfile-bitcart. Exits non-zero on any failed check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

CHECK_PROD_INVOICE=false
while [[ $# -gt 0 ]]; do
	case "$1" in
		--check-prod-invoice) CHECK_PROD_INVOICE=true ;;
		-h|--help)
			cat <<'EOF'
Usage: sudo bash scripts/verify.sh [options]
  --check-prod-invoice  Create one live test invoice against prod (omit during routine updates
                        to avoid consuming Bitcoin's 20-address BIP84 gap limit).
                        Fails if the prod tenant is not enabled.
EOF
			exit 0
			;;
		*) die "Unknown argument: $1" ;;
	esac
	shift
done

load_operator_conf
validate_operator_conf

PUBLIC_BASE="https://${PAY_DOMAIN}"
FAILURES=0

pass() {
	log_ok "$*"
}

fail() {
	log_err "$*"
	FAILURES=$((FAILURES + 1))
}

HTTP_STATUS=""
HTTP_BODY=""
HTTP_HEADERS=""
public_request() {
	local method="$1"
	local path="$2"
	local token="${3:-}"
	local body="${4:-}"

	local tmp_body tmp_hdr tmp_cfg
	tmp_body="$(mktemp)"
	tmp_hdr="$(mktemp)"
	tmp_cfg="$(mktemp)"
	chmod 0600 "${tmp_body}" "${tmp_hdr}" "${tmp_cfg}"

	{
		printf 'silent\n'
		printf 'show-error\n'
		printf 'max-time = 25\n'
		printf 'request = "%s"\n' "${method}"
		printf 'url = "%s%s"\n' "${PUBLIC_BASE}" "${path}"
		printf 'dump-header = "%s"\n' "${tmp_hdr}"
		if [[ -n "${token}" ]]; then
			printf 'header = "Authorization: Bearer %s"\n' "${token}"
		fi
		if [[ -n "${body}" ]]; then
			printf 'header = "Content-Type: application/json"\n'
		fi
	} > "${tmp_cfg}"

	if [[ -n "${body}" ]]; then
		HTTP_STATUS="$(printf '%s' "${body}" | curl -K "${tmp_cfg}" --data-binary @- -o "${tmp_body}" -w '%{http_code}' || printf '000')"
	else
		HTTP_STATUS="$(curl -K "${tmp_cfg}" -o "${tmp_body}" -w '%{http_code}' || printf '000')"
	fi
	HTTP_BODY="$(cat "${tmp_body}")"
	HTTP_HEADERS="$(cat "${tmp_hdr}")"
	rm -f "${tmp_body}" "${tmp_hdr}" "${tmp_cfg}"
}

check_host_and_rootless() {
	if [[ "$(getenforce 2>/dev/null || true)" == "Enforcing" ]]; then
		pass "SELinux is Enforcing."
	else
		fail "SELinux is not Enforcing."
	fi

	local info_out
	info_out="$(run_bitcart_podman info --format '{{.Host.Security.Rootless}} {{.Store.GraphDriverName}}' 2>/dev/null || true)"
	if [[ "${info_out}" == "true overlay" ]]; then
		pass "Rootless Podman storage verified for ${BITCART_USER}: true overlay."
	else
		fail "Rootless Podman storage check failed (got '${info_out}', expected 'true overlay')."
	fi

	local units=(bitcart-database bitcart-redis bitcart-bitcoin bitcart-backend bitcart-worker bitcart-checkout bitcart-gateway)
	if has_crypto "xmr"; then
		units+=(bitcart-monero)
	fi

	local unit
	for unit in "${units[@]}"; do
		if run_bitcart_systemctl is-active --quiet "${unit}.service"; then
			pass "Rootless unit active: ${unit}.service"
		else
			fail "Rootless unit NOT active: ${unit}.service"
		fi
	done

	if systemctl is-active --quiet caddy.service; then
		pass "Host caddy.service is active."
	else
		fail "Host caddy.service is NOT active."
	fi

	if firewall-cmd --policy=block-cloud-metadata --list-rich-rules 2>/dev/null | grep -q '169.254.169.254/32.*drop'; then
		pass "firewalld outbound cloud metadata block (169.254.169.254/32) is active."
	else
		fail "firewalld outbound block on 169.254.169.254/32 is missing."
	fi

	if command -v ss >/dev/null 2>&1; then
		local non_loopback
		non_loopback="$(ss -lntH '( sport = :28080 or sport = :29080 )' | awk '$4 !~ /^127\.0\.0\.1:/ { print $4 }')"
		if [[ -z "${non_loopback}" ]]; then
			pass "Gateway ports 28080 and 29080 are bound strictly to 127.0.0.1."
		else
			fail "Gateway port bound outside 127.0.0.1: ${non_loopback}"
		fi
	fi
}

# PublicStore from an invoice_management token. transaction_speed must be at
# least 1. currency_data is fiat divisibility and is not a coin map.
validate_public_store_json() {
	local store_json="$1"

	jq -e '
		((.default_currency | ascii_upcase) == "USD") and
		(.checkout_settings.expiration == 60) and
		(.checkout_settings.transaction_speed >= 1) and
		(.checkout_settings.underpaid_percentage == 0) and
		(.checkout_settings.email_required == false) and
		(.checkout_settings.allow_anonymous_invoice_creation == false)
	' >/dev/null <<< "${store_json}"
}

check_store_config() {
	local env_name="$1"
	local store_id="$2"
	local token="$3"

	public_request "GET" "/api/stores/${store_id}" "${token}"
	if [[ "${HTTP_STATUS}" != "200" ]]; then
		fail "${env_name} GET /api/stores/${store_id} returned HTTP ${HTTP_STATUS} (expected 200)."
		return
	fi

	if validate_public_store_json "${HTTP_BODY}"; then
		pass "${env_name} store settings verified (USD, expiration 60, BTC speed >= 1, underpaid=0, no email, no anonymous invoices)."
	else
		fail "${env_name} store checkout settings check failed."
	fi
}

check_enabled_cryptos() {
	public_request "GET" "/api/cryptos"
	if [[ "${HTTP_STATUS}" != "200" ]]; then
		fail "GET /api/cryptos returned HTTP ${HTTP_STATUS} (expected 200)."
		return
	fi

	if jq -e '[.result[]? | ascii_downcase] | index("btc") != null' >/dev/null <<< "${HTTP_BODY}"; then
		pass "GET /api/cryptos includes btc."
	else
		fail "GET /api/cryptos does not include btc."
	fi

	if has_crypto "xmr"; then
		if jq -e '[.result[]? | ascii_downcase] | index("xmr") != null' >/dev/null <<< "${HTTP_BODY}"; then
			pass "GET /api/cryptos includes xmr."
		else
			fail "GET /api/cryptos does not include xmr."
		fi
	fi
}

check_blocked_route() {
	local method="$1"
	local path="$2"
	local token="${3:-}"
	local body="${4:-}"
	local label="$5"

	public_request "${method}" "${path}" "${token}" "${body}"
	if [[ "${HTTP_STATUS}" == "404" ]]; then
		pass "Blocked public route returns 404: ${label}"
	else
		fail "Blocked public route ${label} returned HTTP ${HTTP_STATUS} (expected 404)."
	fi
}

check_live_invoice() {
	local env_name="$1"
	local store_id="$2"
	local token="$3"

	local rand_suffix payload
	rand_suffix="$(openssl rand -hex 6)"
	payload="$(jq -n --arg sid "${store_id}" --arg oid "verify-${env_name}-${rand_suffix}" \
		'{price: 1, currency: "USD", store_id: $sid, order_id: $oid}')"

	public_request "POST" "/api/invoices" "${token}" "${payload}"
	if [[ "${HTTP_STATUS}" != "200" && "${HTTP_STATUS}" != "201" ]]; then
		fail "${env_name} live invoice creation returned HTTP ${HTTP_STATUS} (expected 200)."
		return
	fi

	local invoice_id
	invoice_id="$(jq -r '.id // empty' <<< "${HTTP_BODY}")"
	if [[ -z "${invoice_id}" ]]; then
		fail "${env_name} live invoice response missing id."
		return
	fi
	pass "${env_name} live invoice created (${invoice_id})."

	if jq -e '
		[.payments[] | select((.currency // "" | ascii_downcase) == "btc") | (.required_confirmations // 0)]
		| length > 0 and all(. >= 1)
	' >/dev/null <<< "${HTTP_BODY}"; then
		pass "${env_name} BTC payment method enforces required_confirmations >= 1."
	else
		fail "${env_name} BTC payment method missing or required_confirmations < 1."
	fi

	if has_crypto "xmr"; then
		if jq -e '
			[.payments[] | select((.currency // "" | ascii_downcase) == "xmr") | (.required_confirmations // 0)]
			| length > 0 and all(. >= 5)
		' >/dev/null <<< "${HTTP_BODY}"; then
			pass "${env_name} XMR payment method enforces required_confirmations >= 5."
		else
			fail "${env_name} XMR payment method missing or required_confirmations < 5."
		fi
	fi

	public_request "GET" "/i/${invoice_id}"
	if [[ "${HTTP_STATUS}" == "200" ]]; then
		pass "${env_name} public checkout GET /i/${invoice_id} returned 200."
	else
		fail "${env_name} public checkout GET /i/${invoice_id} returned HTTP ${HTTP_STATUS} (expected 200)."
	fi

	if grep -iq '^referrer-policy:[[:space:]]*no-referrer' <<< "${HTTP_HEADERS}"; then
		pass "Checkout response includes Referrer-Policy: no-referrer."
	else
		fail "Checkout response missing Referrer-Policy: no-referrer."
	fi

	if grep -iq '^strict-transport-security:' <<< "${HTTP_HEADERS}"; then
		pass "Checkout response includes Strict-Transport-Security."
	else
		fail "Checkout response missing Strict-Transport-Security."
	fi

	if grep -iq '^x-content-type-options:[[:space:]]*nosniff' <<< "${HTTP_HEADERS}"; then
		pass "Checkout response includes X-Content-Type-Options: nosniff."
	else
		fail "Checkout response missing X-Content-Type-Options: nosniff."
	fi

	if grep -iq '^x-frame-options:[[:space:]]*DENY' <<< "${HTTP_HEADERS}"; then
		pass "Checkout response includes X-Frame-Options: DENY."
	else
		fail "Checkout response missing X-Frame-Options: DENY."
	fi
}

check_anonymous_invoice_rejected() {
	local env_name="$1"
	local store_id="$2"
	local payload
	payload="$(jq -n --arg sid "${store_id}" '{price: 1, currency: "USD", store_id: $sid}')"
	public_request "POST" "/api/invoices" "" "${payload}"
	if [[ "${HTTP_STATUS}" == "403" ]]; then
		pass "Unauthenticated POST /api/invoices against ${env_name} store returned 403."
	else
		fail "Unauthenticated POST /api/invoices against ${env_name} store returned HTTP ${HTTP_STATUS} (expected 403)."
	fi
}

main() {
	if [[ "${CHECK_PROD_INVOICE}" == "true" ]] && ! is_prod_tenant_enabled; then
		die "--check-prod-invoice was passed, but the prod tenant is not enabled. Set prod watch-only keys in ${OPERATOR_CONF} before requesting a live prod invoice."
	fi

	check_host_and_rootless

	local prod_store="" prod_tok=""
	local test_store="" test_tok=""

	# Credential files are required only for enabled tenants.
	if is_prod_tenant_enabled; then
		local prod_file="${BITCART_SECRETS_DIR}/prod-arkfile.env"
		[[ -f "${prod_file}" ]] || die "Missing ${prod_file}. Run scripts/provision.sh first."
		prod_store="$(read_existing_key "${prod_file}" "BITCART_STORE_ID")"
		prod_tok="$(read_existing_key "${prod_file}" "BITCART_API_TOKEN")"
	fi
	if is_test_tenant_enabled; then
		local test_file="${BITCART_SECRETS_DIR}/test-arkfile.env"
		[[ -f "${test_file}" ]] || die "Missing ${test_file}. Run scripts/provision.sh first."
		test_store="$(read_existing_key "${test_file}" "BITCART_STORE_ID")"
		test_tok="$(read_existing_key "${test_file}" "BITCART_API_TOKEN")"
	fi

	# Use the prod invoice_management token when prod is enabled, otherwise test.
	local scope_name scope_tok
	if is_prod_tenant_enabled; then
		scope_name="prod"
		scope_tok="${prod_tok}"
	else
		scope_name="test"
		scope_tok="${test_tok}"
	fi

	# 1. Authenticated and unauthenticated /api/invoices/count checks.
	public_request "GET" "/api/invoices/count" "${scope_tok}"
	if [[ "${HTTP_STATUS}" == "200" ]]; then
		pass "GET /api/invoices/count with ${scope_name} token returned 200."
	else
		fail "GET /api/invoices/count with ${scope_name} token returned HTTP ${HTTP_STATUS} (expected 200)."
	fi

	public_request "GET" "/api/invoices/count"
	if [[ "${HTTP_STATUS}" == "401" ]]; then
		pass "GET /api/invoices/count without token returned 401."
	else
		fail "GET /api/invoices/count without token returned HTTP ${HTTP_STATUS} (expected 401)."
	fi

	# 2. Store and checkout settings for every enabled tenant, plus enabled coins.
	if is_prod_tenant_enabled; then
		check_store_config "prod" "${prod_store}" "${prod_tok}"
	fi
	if is_test_tenant_enabled; then
		check_store_config "test" "${test_store}" "${test_tok}"
	fi
	check_enabled_cryptos

	# 3. Unauthenticated invoice creation must be rejected (403) for every enabled tenant.
	if is_prod_tenant_enabled; then
		check_anonymous_invoice_rejected "prod" "${prod_store}"
	fi
	if is_test_tenant_enabled; then
		check_anonymous_invoice_rejected "test" "${test_store}"
	fi

	# 4. Cross-tenant isolation checks only when both tenants are enabled.
	# These probes must return 403 and must not create a real invoice.
	if is_prod_tenant_enabled && is_test_tenant_enabled; then
		local anon_prod_payload anon_test_payload
		anon_prod_payload="$(jq -n --arg sid "${prod_store}" '{price: 1, currency: "USD", store_id: $sid}')"
		anon_test_payload="$(jq -n --arg sid "${test_store}" '{price: 1, currency: "USD", store_id: $sid}')"

		public_request "POST" "/api/invoices" "${test_tok}" "${anon_prod_payload}"
		if [[ "${HTTP_STATUS}" == "403" ]]; then
			pass "Cross-tenant POST /api/invoices (test token -> prod store) returned 403."
		else
			fail "Cross-tenant POST /api/invoices (test token -> prod store) returned HTTP ${HTTP_STATUS} (expected 403)."
		fi

		public_request "POST" "/api/invoices" "${prod_tok}" "${anon_test_payload}"
		if [[ "${HTTP_STATUS}" == "403" ]]; then
			pass "Cross-tenant POST /api/invoices (prod token -> test store) returned 403."
		else
			fail "Cross-tenant POST /api/invoices (prod token -> test store) returned HTTP ${HTTP_STATUS} (expected 403)."
		fi
	fi

	# 5. Blocked public routes must return 404. Authenticated checks use a real
	# invoice_management token (prod when enabled, otherwise test).
	check_blocked_route "GET" "/" "" "" "GET /"
	check_blocked_route "GET" "/admin" "" "" "GET /admin"
	check_blocked_route "POST" "/api/token" "" '{"email":"superadmin@pay.internal","password":"invalid"}' "POST /api/token"
	check_blocked_route "POST" "/api/invoices/batch" "${scope_tok}" '{"ids":["00000000000000000000000000"],"command":"mark_complete"}' "POST /api/invoices/batch (with ${scope_name} invoice_management token)"
	check_blocked_route "GET" "/api/invoices/export" "${scope_tok}" "" "GET /api/invoices/export (with ${scope_name} invoice_management token)"
	check_blocked_route "PATCH" "/api/invoices/00000000000000000000000000/customer" "" '{"buyer_email":"attacker@example.com"}' "PATCH /api/invoices/{id}/customer"
	check_blocked_route "PATCH" "/api/invoices/00000000000000000000000000/details" "" '{"shipping_address":"none"}' "PATCH /api/invoices/{id}/details"
	check_blocked_route "GET" "/api/wallets" "${scope_tok}" "" "GET /api/wallets (with ${scope_name} invoice_management token)"
	check_blocked_route "GET" "/api/users" "${scope_tok}" "" "GET /api/users (with ${scope_name} invoice_management token)"

	# 6. Live invoice check (test store when test is enabled; prod only with --check-prod-invoice).
	if is_test_tenant_enabled; then
		check_live_invoice "test" "${test_store}" "${test_tok}"
	else
		log_info "Test tenant is not enabled; skipping default test-store live invoice check."
	fi

	if [[ "${CHECK_PROD_INVOICE}" == "true" ]]; then
		check_live_invoice "prod" "${prod_store}" "${prod_tok}"
	elif is_prod_tenant_enabled; then
		log_info "Skipping live prod invoice creation to preserve Bitcoin BIP84 gap limit (pass --check-prod-invoice to run)."
	fi

	if (( FAILURES > 0 )); then
		die "Verification failed with ${FAILURES} error(s)."
	fi

	log_ok "SUCCESS! All security, privacy, confirmation, and isolation checks passed."
}

main "$@"
