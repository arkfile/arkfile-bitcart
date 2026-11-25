#!/usr/bin/env bash
# First-time (and idempotent) deployment orchestrator for arkfile-bitcart.
# Runs host-setup.sh, generates internal secrets, installs Quadlets and Caddy,
# seeds Electrum /data/config, starts rootless services, provisions tenants,
# and runs automated security and privacy verification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

CHECK_PROD_INVOICE=false
PRINT_CREDENTIALS=false
FORCE_REPROVISION=false
ROTATE_TOKENS=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--check-prod-invoice) CHECK_PROD_INVOICE=true ;;
		--print-credentials) PRINT_CREDENTIALS=true ;;
		--force-reprovision) FORCE_REPROVISION=true ;;
		--rotate-tokens) ROTATE_TOKENS=true ;;
		-h|--help)
			cat <<'EOF'
Usage: sudo bash scripts/deploy.sh [options]
  --check-prod-invoice  Also run one live invoice check against prod during verify.sh
  --print-credentials   Print generated Arkfile secrets.env snippets to stdout
  --force-reprovision   Force full reprovisioning in provision.sh
  --rotate-tokens       Rotate Arkfile invoice_management API tokens
EOF
			exit 0
			;;
		*) die "Unknown argument: $1" ;;
	esac
	shift
done

main() {
	load_operator_conf
	validate_operator_conf
	load_images_env "${REPO_ROOT}"

	log_info "Step 1: Running host bootstrap (scripts/host-setup.sh)..."
	bash "${SCRIPT_DIR}/host-setup.sh"

	verify_rootless_overlay

	log_info "Step 2: Ensuring internal secrets, container env files, Quadlets, and Caddy configs..."
	ensure_generated_secrets_and_env
	install_configs_and_quadlets "${REPO_ROOT}"

	log_info "Step 3: Pulling rootless container images..."
	pull_stack_images

	log_info "Step 4: Seeding Electrum /data/config with auto_connect=false..."
	seed_electrum_config "${REPO_ROOT}"

	log_info "Step 5: Reloading rootless systemd user units and starting Bitcart stack..."
	run_bitcart_systemctl daemon-reload

	local core_units=(bitcart-database bitcart-redis bitcart-bitcoin)
	if has_crypto "xmr"; then
		core_units+=(bitcart-monero)
	fi

	local unit
	for unit in "${core_units[@]}"; do
		run_bitcart_systemctl start "${unit}.service"
	done

	run_bitcart_systemctl start bitcart-backend.service
	run_bitcart_systemctl start bitcart-worker.service
	run_bitcart_systemctl start bitcart-checkout.service
	run_bitcart_systemctl start bitcart-gateway.service

	log_info "Step 6: Enabling and restarting host caddy.service..."
	systemctl enable --now caddy.service
	# admin off in the host Caddyfile, so reload cannot reach the admin endpoint.
	systemctl restart caddy.service

	wait_for_local_api 150

	log_info "Step 7: Provisioning Bitcart tenants (scripts/provision.sh)..."
	local prov_args=()
	[[ "${FORCE_REPROVISION}" == "true" ]] && prov_args+=(--force-reprovision)
	[[ "${ROTATE_TOKENS}" == "true" ]] && prov_args+=(--rotate-tokens)
	[[ "${PRINT_CREDENTIALS}" == "true" ]] && prov_args+=(--print-credentials)
	bash "${SCRIPT_DIR}/provision.sh" "${prov_args[@]}"

	log_info "Step 8: Running post-deploy security and privacy verification (scripts/verify.sh)..."
	local verify_args=()
	[[ "${CHECK_PROD_INVOICE}" == "true" ]] && verify_args+=(--check-prod-invoice)
	bash "${SCRIPT_DIR}/verify.sh" "${verify_args[@]}"

	log_ok "SUCCESS! Deployment complete. Mode-0600 credentials are stored under ${CREDS_OUT_DIR}/."
}

main "$@"
