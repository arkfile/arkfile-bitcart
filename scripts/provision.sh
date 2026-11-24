#!/usr/bin/env bash
# Idempotent multi-tenant Bitcart API provisioner for arkfile-bitcart.
# Talks exclusively to http://127.0.0.1:29080/api and configures:
#   - superadmin@pay.internal (superuser, global policy lockdown only)
#   - prod@pay.internal (non-superuser, store "arkfile-prod", invoice_management token)
#   - test@pay.internal (optional non-superuser, store "arkfile-test", invoice_management token)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

API_BASE="http://127.0.0.1:29080/api"
FORCE_REPROVISION=false
ROTATE_TOKENS=false
PRINT_CREDENTIALS=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--force-reprovision) FORCE_REPROVISION=true ;;
		--rotate-tokens) ROTATE_TOKENS=true ;;
		--print-credentials) PRINT_CREDENTIALS=true ;;
		-h|--help)
			cat <<'EOF'
Usage: sudo bash scripts/provision.sh [options]
  --force-reprovision  Bypass fast-path check and re-run superadmin and tenant provisioning
  --rotate-tokens      Mint new invoice_management tokens (invalidates old Arkfile tokens)
  --print-credentials  Print generated Arkfile secrets.env snippets to stdout
EOF
			exit 0
			;;
		*) die "Unknown argument: $1" ;;
	esac
	shift
done

load_operator_conf
validate_operator_conf
ensure_bitcart_user_ready

# Ensure accounts.env exists with generated high-entropy passwords.
ensure_account_passwords() {
	install -d -m 0700 -o "${BITCART_USER}" -g "${BITCART_USER}" "${BITCART_SECRETS_DIR}"
	local acct_file="${BITCART_SECRETS_DIR}/accounts.env"
	local super_pass prod_pass test_pass
	super_pass="$(read_existing_key "${acct_file}" "SUPERADMIN_PASSWORD")"
	prod_pass="$(read_existing_key "${acct_file}" "PROD_ADMIN_PASSWORD")"
	test_pass="$(read_existing_key "${acct_file}" "TEST_ADMIN_PASSWORD")"

	local changed=false
	if [[ -z "${super_pass}" ]]; then
		super_pass="$(generate_hex_secret)"
		changed=true
	fi
	if [[ -z "${prod_pass}" ]]; then
		prod_pass="$(generate_hex_secret)"
		changed=true
	fi
	if [[ -z "${test_pass}" ]]; then
		test_pass="$(generate_hex_secret)"
		changed=true
	fi

	if [[ "${changed}" == "true" || ! -f "${acct_file}" ]]; then
		write_bitcart_secret_file "${acct_file}" <<EOF
SUPERADMIN_PASSWORD=${super_pass}
PROD_ADMIN_PASSWORD=${prod_pass}
TEST_ADMIN_PASSWORD=${test_pass}
EOF
	fi

	SUPERADMIN_PASSWORD="${super_pass}"
	PROD_ADMIN_PASSWORD="${prod_pass}"
	TEST_ADMIN_PASSWORD="${test_pass}"
}

# Execute an HTTP request against API_BASE without exposing bearer tokens in argv.
# Sets global HTTP_STATUS and HTTP_BODY.
HTTP_STATUS=""
HTTP_BODY=""
api_request() {
	local method="$1"
	local path="$2"
	local token="${3:-}"
	local body="${4:-}"

	local tmp_body tmp_cfg
	tmp_body="$(mktemp)"
	tmp_cfg="$(mktemp)"
	chmod 0600 "${tmp_body}" "${tmp_cfg}"

	{
		printf 'silent\n'
		printf 'show-error\n'
		printf 'max-time = 25\n'
		printf 'request = "%s"\n' "${method}"
		printf 'url = "%s%s"\n' "${API_BASE}" "${path}"
		printf 'header = "Accept: application/json"\n'
		if [[ -n "${token}" ]]; then
			printf 'header = "Authorization: Bearer %s"\n' "${token}"
		fi
		if [[ -n "${body}" ]]; then
			printf 'header = "Content-Type: application/json"\n'
		fi
	} > "${tmp_cfg}"

	if [[ -n "${body}" ]]; then
		HTTP_STATUS="$(printf '%s' "${body}" | curl -K "${tmp_cfg}" --data-binary @- -o "${tmp_body}" -w '%{http_code}')"
	else
		HTTP_STATUS="$(curl -K "${tmp_cfg}" -o "${tmp_body}" -w '%{http_code}')"
	fi
	HTTP_BODY="$(cat "${tmp_body}")"
	rm -f "${tmp_body}" "${tmp_cfg}"
}

# PublicStore, returned for an invoice_management token. currency_data is fiat
# divisibility metadata, and wallets are omitted.
validate_public_store_json() {
	local store_json="$1"
	local expected_btc_speed="$2"

	jq -e --argjson btc_speed "${expected_btc_speed}" '
		((.default_currency | ascii_upcase) == "USD") and
		(.checkout_settings.expiration == 60) and
		(.checkout_settings.transaction_speed == $btc_speed) and
		(.checkout_settings.underpaid_percentage == 0) and
		(.checkout_settings.email_required == false) and
		(.checkout_settings.allow_anonymous_invoice_creation == false)
	' >/dev/null <<< "${store_json}"
}

# DisplayStore, returned for the tenant full_control token. wallets is a list
# of wallet IDs.
validate_tenant_store_json() {
	local store_json="$1"
	local expected_btc_speed="$2"
	local btc_wallet_id="$3"
	local xmr_wallet_id="${4:-}"

	validate_public_store_json "${store_json}" "${expected_btc_speed}" || return 1
	if has_crypto "xmr" && [[ -z "${xmr_wallet_id}" ]]; then
		return 1
	fi

	jq -e --arg btc "${btc_wallet_id}" --arg xmr "${xmr_wallet_id}" '
		(.wallets | type == "array") and
		([.wallets[] | if type == "object" then .id else . end] | index($btc) != null) and
		($xmr == "" or ([.wallets[] | if type == "object" then .id else . end] | index($xmr) != null))
	' >/dev/null <<< "${store_json}"
}

write_tenant_credentials() {
	local env_name="$1"
	local store_id="$2"
	local token="$3"

	write_bitcart_secret_file "${BITCART_SECRETS_DIR}/${env_name}-arkfile.env" <<EOF
BITCART_API_URL=https://${PAY_DOMAIN}/api
BITCART_CHECKOUT_URL=https://${PAY_DOMAIN}
BITCART_STORE_ID=${store_id}
BITCART_API_TOKEN=${token}
EOF

	install -d -m 0700 "${CREDS_OUT_DIR}"
	local out_file="${CREDS_OUT_DIR}/${env_name}-secrets.env"
	local tmp_out="${out_file}.tmp.$$"
	cat > "${tmp_out}" <<EOF
# Ready-to-copy Arkfile secrets.env snippet for ${env_name} (${PAY_DOMAIN}).
# Copy these lines as-is into the existing /opt/arkfile/etc/secrets.env.
# Edit the top-up limits below before applying this file if needed.
ARKFILE_PAYMENTS_ENABLED=true
ARKFILE_MIN_TOP_UP_USD=0.50
ARKFILE_MAX_TOP_UP_USD=1000.00
ARKFILE_BITCART_API_URL=https://${PAY_DOMAIN}/api
ARKFILE_BITCART_CHECKOUT_URL=https://${PAY_DOMAIN}
ARKFILE_BITCART_STORE_ID=${store_id}
ARKFILE_BITCART_API_TOKEN=${token}
EOF
	chmod 0600 "${tmp_out}"
	mv -f "${tmp_out}" "${out_file}"
	log_ok "Saved mode 0600 credentials snippet to ${out_file}"

	if [[ "${PRINT_CREDENTIALS}" == "true" ]]; then
		printf '\n# %s credentials snippet (%s)\n' "${env_name}" "${out_file}"
		cat "${out_file}"
	fi
}

check_existing_token_valid() {
	local env_name="$1"
	local store_id="$2"
	local token="$3"

	[[ -n "${token}" && -n "${store_id}" ]] || return 1

	api_request "GET" "/invoices/count" "${token}"
	[[ "${HTTP_STATUS}" == "200" ]] || return 1

	api_request "GET" "/stores/${store_id}" "${token}"
	[[ "${HTTP_STATUS}" == "200" ]] || return 1
	validate_public_store_json "${HTTP_BODY}" "${BTC_TX_SPEED}" || return 1
	return 0
}

try_fast_path() {
	if [[ "${FORCE_REPROVISION}" == "true" || "${ROTATE_TOKENS}" == "true" ]]; then
		return 1
	fi

	local prod_file="${BITCART_SECRETS_DIR}/prod-arkfile.env"
	[[ -f "${prod_file}" ]] || return 1

	local prod_store prod_tok
	prod_store="$(read_existing_key "${prod_file}" "BITCART_STORE_ID")"
	prod_tok="$(read_existing_key "${prod_file}" "BITCART_API_TOKEN")"
	check_existing_token_valid "prod" "${prod_store}" "${prod_tok}" || return 1

	if is_test_tenant_enabled; then
		local test_file="${BITCART_SECRETS_DIR}/test-arkfile.env"
		[[ -f "${test_file}" ]] || return 1

		local test_store test_tok
		test_store="$(read_existing_key "${test_file}" "BITCART_STORE_ID")"
		test_tok="$(read_existing_key "${test_file}" "BITCART_API_TOKEN")"
		check_existing_token_valid "test" "${test_store}" "${test_tok}" || return 1

		# Confirm cross-tenant isolation in fast-path as well (POST /invoices returns 403).
		local probe_prod probe_test
		probe_prod="$(jq -n --arg sid "${prod_store}" '{price: 1, currency: "USD", store_id: $sid}')"
		probe_test="$(jq -n --arg sid "${test_store}" '{price: 1, currency: "USD", store_id: $sid}')"
		api_request "POST" "/invoices" "${test_tok}" "${probe_prod}"
		[[ "${HTTP_STATUS}" == "403" ]] || return 1
		api_request "POST" "/invoices" "${prod_tok}" "${probe_test}"
		[[ "${HTTP_STATUS}" == "403" ]] || return 1

		write_tenant_credentials "test" "${test_store}" "${test_tok}"
	fi

	write_tenant_credentials "prod" "${prod_store}" "${prod_tok}"
	log_ok "Fast-path passed: existing tenant stores, checkout settings, and API tokens are already valid."
	return 0
}

mint_token() {
	local email="$1"
	local password="$2"
	local permission="$3"
	local app_id="${4:-}"

	local payload
	if [[ -n "${app_id}" ]]; then
		payload="$(jq -n --arg e "${email}" --arg p "${password}" --arg perm "${permission}" --arg app "${app_id}" \
			'{email: $e, password: $p, permissions: [$perm], app_id: $app}')"
	else
		payload="$(jq -n --arg e "${email}" --arg p "${password}" --arg perm "${permission}" \
			'{email: $e, password: $p, permissions: [$perm]}')"
	fi

	api_request "POST" "/token" "" "${payload}"
	if [[ "${HTTP_STATUS}" != "200" ]]; then
		return 1
	fi
	jq -er '.access_token' <<< "${HTTP_BODY}"
}

bootstrap_superadmin() {
	local super_email="superadmin@pay.internal"
	local super_token=""

	if super_token="$(mint_token "${super_email}" "${SUPERADMIN_PASSWORD}" "full_control" 2>/dev/null)"; then
		log_ok "Authenticated as existing ${super_email}."
	else
		log_info "Registering initial superuser ${super_email}..."
		local reg_payload
		reg_payload="$(jq -n --arg e "${super_email}" --arg p "${SUPERADMIN_PASSWORD}" \
			'{email: $e, password: $p, captcha_code: ""}')"
		api_request "POST" "/users" "" "${reg_payload}"
		if [[ "${HTTP_STATUS}" != "200" && "${HTTP_STATUS}" != "201" ]]; then
			die "Failed to register ${super_email} (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"
		fi
		super_token="$(mint_token "${super_email}" "${SUPERADMIN_PASSWORD}" "full_control")" \
			|| die "Registered ${super_email} but failed to obtain full_control token."
		log_ok "Created and authenticated ${super_email}."
	fi

	# Lock down global Bitcart instance policies.
	local policy_payload
	policy_payload="$(jq -n --argjson days "${BITCART_LOG_RETENTION_DAYS}" '{
		disable_registration: true,
		discourage_index: true,
		check_updates: false,
		allow_anonymous_configurator: false,
		allow_file_uploads: false,
		log_retention_days: $days
	}')"
	api_request "POST" "/manage/policies" "${super_token}" "${policy_payload}"
	if [[ "${HTTP_STATUS}" != "200" ]]; then
		die "Failed to apply global Bitcart policies (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"
	fi
	log_ok "Applied hardened global Bitcart policies (log_retention_days=${BITCART_LOG_RETENTION_DAYS})."

	SUPERADMIN_TOKEN="${super_token}"
}

ensure_tenant_user() {
	local email="$1"
	local password="$2"

	api_request "GET" "/users?limit=-1" "${SUPERADMIN_TOKEN}"
	[[ "${HTTP_STATUS}" == "200" ]] || die "Failed to list users (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"

	local existing
	existing="$(jq -c --arg e "${email}" '.result[] | select(.email == $e)' <<< "${HTTP_BODY}" | head -n 1 || true)"
	if [[ -n "${existing}" ]]; then
		local is_su
		is_su="$(jq -r '.is_superuser' <<< "${existing}")"
		if [[ "${is_su}" != "false" ]]; then
			die "Tenant account ${email} has is_superuser=${is_su}. Tenant accounts must never be superusers."
		fi
		log_ok "Verified existing non-superuser tenant account ${email}."
		return 0
	fi

	local create_payload
	create_payload="$(jq -n --arg e "${email}" --arg p "${password}" \
		'{email: $e, password: $p, is_superuser: false}')"
	api_request "POST" "/users" "${SUPERADMIN_TOKEN}" "${create_payload}"
	if [[ "${HTTP_STATUS}" != "200" && "${HTTP_STATUS}" != "201" ]]; then
		die "Failed to create non-superuser account ${email} (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"
	fi
	local created_su
	created_su="$(jq -r '.is_superuser' <<< "${HTTP_BODY}")"
	[[ "${created_su}" == "false" ]] || die "Created user ${email} unexpectedly has is_superuser=${created_su}."
	log_ok "Created isolated non-superuser tenant account ${email}."
}

provision_tenant() {
	local env_name="$1"
	local env_upper="$2"
	local email="${env_name}@pay.internal"
	local password="$3"

	local btc_xpub_var="${env_upper}_BTC_XPUB"
	local btc_xpub="${!btc_xpub_var:-}"
	validate_btc_xpub "${btc_xpub_var}" "${btc_xpub}"

	local tenant_token
	tenant_token="$(mint_token "${email}" "${password}" "full_control")" \
		|| die "Failed to authenticate tenant ${email} for provisioning."

	# List tenant wallets.
	api_request "GET" "/wallets?limit=-1" "${tenant_token}"
	[[ "${HTTP_STATUS}" == "200" ]] || die "Failed to list wallets for ${env_name} (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"
	local wallets_json="${HTTP_BODY}"

	# Create or update BTC watch-only wallet.
	local btc_wallet_name="${env_name}-btc"
	local btc_wallet_id
	btc_wallet_id="$(jq -r --arg n "${btc_wallet_name}" \
		'(.result[] | select(.name == $n and .currency == "btc") | .id) // (.result[] | select(.currency == "btc") | .id)' \
		<<< "${wallets_json}" | head -n 1 || true)"

	if [[ -z "${btc_wallet_id}" ]]; then
		local btc_payload
		btc_payload="$(jq -n --arg n "${btc_wallet_name}" --arg x "${btc_xpub}" \
			'{name: $n, xpub: $x, currency: "btc", lightning_enabled: false}')"
		api_request "POST" "/wallets" "${tenant_token}" "${btc_payload}"
		[[ "${HTTP_STATUS}" == "200" || "${HTTP_STATUS}" == "201" ]] \
			|| die "Failed to create BTC wallet for ${env_name} (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"
		btc_wallet_id="$(jq -er '.id' <<< "${HTTP_BODY}")"
		log_ok "Created watch-only BTC wallet ${btc_wallet_name} (${btc_wallet_id})."
	else
		local patch_btc
		patch_btc="$(jq -n --arg n "${btc_wallet_name}" --arg x "${btc_xpub}" \
			'{name: $n, xpub: $x, lightning_enabled: false}')"
		api_request "PATCH" "/wallets/${btc_wallet_id}" "${tenant_token}" "${patch_btc}"
		[[ "${HTTP_STATUS}" == "200" ]] \
			|| die "Failed to update BTC wallet ${btc_wallet_id} (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"
		log_ok "Verified watch-only BTC wallet ${btc_wallet_name} (${btc_wallet_id})."
	fi

	local wallet_ids_json
	wallet_ids_json="$(jq -n --arg id "${btc_wallet_id}" '[$id]')"

	# Create or update XMR watch-only wallet when enabled.
	if has_crypto "xmr"; then
		validate_xmr_watch_only "${env_upper}"
		local xmr_addr_var="${env_upper}_XMR_ADDRESS"
		local xmr_view_var="${env_upper}_XMR_PRIVATE_VIEW_KEY"
		local xmr_height_var="${env_upper}_XMR_RESTORE_HEIGHT"
		local xmr_addr="${!xmr_addr_var}"
		local xmr_view="${!xmr_view_var}"
		local xmr_height="${!xmr_height_var:-}"

		local xmr_wallet_name="${env_name}-xmr"
		local xmr_wallet_id
		xmr_wallet_id="$(jq -r --arg n "${xmr_wallet_name}" \
			'(.result[] | select(.name == $n and .currency == "xmr") | .id) // (.result[] | select(.currency == "xmr") | .id)' \
			<<< "${wallets_json}" | head -n 1 || true)"

		local addl_with_height addl_no_height
		addl_no_height="$(jq -n --arg a "${xmr_addr}" '{address: $a}')"
		if [[ -n "${xmr_height}" ]]; then
			addl_with_height="$(jq -n --arg a "${xmr_addr}" --argjson h "${xmr_height}" '{address: $a, restore_height: $h}')"
		else
			addl_with_height="${addl_no_height}"
		fi

		if [[ -z "${xmr_wallet_id}" ]]; then
			local xmr_payload
			xmr_payload="$(jq -n \
				--arg n "${xmr_wallet_name}" \
				--arg v "${xmr_view}" \
				--argjson speed "${XMR_TX_SPEED}" \
				--argjson addl "${addl_with_height}" \
				'{name: $n, xpub: $v, currency: "xmr", transaction_speed: $speed, additional_xpub_data: $addl}')"
			api_request "POST" "/wallets" "${tenant_token}" "${xmr_payload}"
			if [[ "${HTTP_STATUS}" != "200" && "${HTTP_STATUS}" != "201" && -n "${xmr_height}" ]]; then
				log_warn "XMR wallet creation with restore_height rejected (HTTP ${HTTP_STATUS}); retrying without restore_height."
				xmr_payload="$(jq -n \
					--arg n "${xmr_wallet_name}" \
					--arg v "${xmr_view}" \
					--argjson speed "${XMR_TX_SPEED}" \
					--argjson addl "${addl_no_height}" \
					'{name: $n, xpub: $v, currency: "xmr", transaction_speed: $speed, additional_xpub_data: $addl}')"
				api_request "POST" "/wallets" "${tenant_token}" "${xmr_payload}"
			fi
			[[ "${HTTP_STATUS}" == "200" || "${HTTP_STATUS}" == "201" ]] \
				|| die "Failed to create XMR wallet for ${env_name} (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"
			xmr_wallet_id="$(jq -er '.id' <<< "${HTTP_BODY}")"
			log_ok "Created watch-only XMR wallet ${xmr_wallet_name} (${xmr_wallet_id}, transaction_speed=${XMR_TX_SPEED})."
		fi

		# Always PATCH transaction_speed on existing XMR wallets so confirmation floors stay enforced.
		local patch_xmr
		patch_xmr="$(jq -n --argjson speed "${XMR_TX_SPEED}" '{transaction_speed: $speed}')"
		api_request "PATCH" "/wallets/${xmr_wallet_id}" "${tenant_token}" "${patch_xmr}"
		[[ "${HTTP_STATUS}" == "200" ]] \
			|| die "Failed to enforce transaction_speed=${XMR_TX_SPEED} on XMR wallet ${xmr_wallet_id} (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"
		log_ok "Verified watch-only XMR wallet ${xmr_wallet_name} (${xmr_wallet_id}, transaction_speed=${XMR_TX_SPEED})."

		wallet_ids_json="$(jq -n --arg b "${btc_wallet_id}" --arg x "${xmr_wallet_id}" '[$b, $x]')"
	fi

	# Create or update tenant USD store and checkout settings.
	local store_name="arkfile-${env_name}"
	api_request "GET" "/stores?limit=-1" "${tenant_token}"
	[[ "${HTTP_STATUS}" == "200" ]] || die "Failed to list stores for ${env_name} (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"

	local store_id
	store_id="$(jq -r --arg n "${store_name}" '.result[] | select(.name == $n) | .id' <<< "${HTTP_BODY}" | head -n 1 || true)"

	local store_payload
	store_payload="$(jq -n \
		--arg n "${store_name}" \
		--argjson wallets "${wallet_ids_json}" \
		--argjson btc_speed "${BTC_TX_SPEED}" \
		'{
			name: $n,
			default_currency: "USD",
			wallets: $wallets,
			checkout_settings: {
				expiration: 60,
				transaction_speed: $btc_speed,
				underpaid_percentage: 0,
				email_required: false,
				allow_anonymous_invoice_creation: false
			}
		}')"

	if [[ -z "${store_id}" ]]; then
		api_request "POST" "/stores" "${tenant_token}" "${store_payload}"
		[[ "${HTTP_STATUS}" == "200" || "${HTTP_STATUS}" == "201" ]] \
			|| die "Failed to create store ${store_name} (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"
		store_id="$(jq -er '.id' <<< "${HTTP_BODY}")"
		log_ok "Created store ${store_name} (${store_id})."
	else
		api_request "PATCH" "/stores/${store_id}" "${tenant_token}" "${store_payload}"
		[[ "${HTTP_STATUS}" == "200" ]] \
			|| die "Failed to update store ${store_name} (${store_id}) (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"
		log_ok "Updated store ${store_name} (${store_id})."
	fi

	# Verify checkout settings and attached wallet IDs on the DisplayStore response.
	api_request "GET" "/stores/${store_id}" "${tenant_token}"
	[[ "${HTTP_STATUS}" == "200" ]] || die "Failed to read store ${store_id} (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"
	validate_tenant_store_json "${HTTP_BODY}" "${BTC_TX_SPEED}" "${btc_wallet_id}" "${xmr_wallet_id:-}" \
		|| die "Store ${store_name} (${store_id}) failed checkout_settings or wallet verification: ${HTTP_BODY}"
	log_ok "Verified store ${store_name} checkout_settings and attached wallets."

	# Preserve existing valid invoice_management token unless --rotate-tokens was passed.
	local saved_file="${BITCART_SECRETS_DIR}/${env_name}-arkfile.env"
	local existing_tok=""
	existing_tok="$(read_existing_key "${saved_file}" "BITCART_API_TOKEN")"

	local scoped_token=""
	if [[ "${ROTATE_TOKENS}" != "true" ]] && check_existing_token_valid "${env_name}" "${store_id}" "${existing_tok}"; then
		scoped_token="${existing_tok}"
		log_ok "Preserved existing valid invoice_management token for ${env_name}."
	else
		scoped_token="$(mint_token "${email}" "${password}" "invoice_management" "arkfile-${env_name}")" \
			|| die "Failed to mint invoice_management token for ${env_name}."
		log_ok "Minted scoped invoice_management token for ${env_name}."
	fi

	write_tenant_credentials "${env_name}" "${store_id}" "${scoped_token}"
	printf -v "PROVISIONED_${env_upper}_STORE_ID" '%s' "${store_id}"
	printf -v "PROVISIONED_${env_upper}_TOKEN" '%s' "${scoped_token}"
}

main() {
	wait_for_local_api 90
	ensure_account_passwords

	if try_fast_path; then
		exit 0
	fi

	bootstrap_superadmin

	ensure_tenant_user "prod@pay.internal" "${PROD_ADMIN_PASSWORD}"
	if is_test_tenant_enabled; then
		ensure_tenant_user "test@pay.internal" "${TEST_ADMIN_PASSWORD}"
	fi

	provision_tenant "prod" "PROD" "${PROD_ADMIN_PASSWORD}"
	if is_test_tenant_enabled; then
		provision_tenant "test" "TEST" "${TEST_ADMIN_PASSWORD}"

		# Confirm cross-tenant store isolation immediately after provisioning.
		local probe_prod probe_test
		probe_prod="$(jq -n --arg sid "${PROVISIONED_PROD_STORE_ID}" '{price: 1, currency: "USD", store_id: $sid}')"
		probe_test="$(jq -n --arg sid "${PROVISIONED_TEST_STORE_ID}" '{price: 1, currency: "USD", store_id: $sid}')"
		api_request "POST" "/invoices" "${PROVISIONED_TEST_TOKEN}" "${probe_prod}"
		if [[ "${HTTP_STATUS}" != "403" ]]; then
			die "Cross-tenant isolation check failed: test token attempted invoice on prod store (HTTP ${HTTP_STATUS}, expected 403)."
		fi
		api_request "POST" "/invoices" "${PROVISIONED_PROD_TOKEN}" "${probe_test}"
		if [[ "${HTTP_STATUS}" != "403" ]]; then
			die "Cross-tenant isolation check failed: prod token attempted invoice on test store (HTTP ${HTTP_STATUS}, expected 403)."
		fi
		log_ok "Verified cross-tenant store isolation between prod and test."
	fi

	log_ok "Bitcart multi-tenant provisioning complete."
}

main "$@"
