#!/usr/bin/env bash
# Non-destructive production update script for arkfile-bitcart.
# Pulls updated images from images.env, refreshes Quadlet and Caddy configs while
# preserving PostgreSQL volumes, watch-only wallet state, internal credentials,
# and existing valid Arkfile API tokens, then runs verify.sh without creating
# live prod invoices by default.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

CHECK_PROD_INVOICE=false
ROTATE_TOKENS=false
FORCE_REPROVISION=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--check-prod-invoice) CHECK_PROD_INVOICE=true ;;
		--rotate-tokens) ROTATE_TOKENS=true ;;
		--force-reprovision) FORCE_REPROVISION=true ;;
		-h|--help)
			cat <<'EOF'
Usage: sudo bash scripts/update.sh [options]
  --force-reprovision   Force full reprovisioning (still preserves valid tokens unless --rotate-tokens)
  --rotate-tokens       Explicitly rotate Arkfile invoice_management API tokens
  --check-prod-invoice  Also create one live test invoice against prod during verify.sh
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
	verify_rootless_overlay

	local admin_was_active=false
	if run_bitcart_systemctl is-active --quiet bitcart-admin.service; then
		admin_was_active=true
	fi

	log_info "Refreshing non-secret config, Quadlets, and Caddy configs (preserving existing secrets)..."
	ensure_generated_secrets_and_env
	install_configs_and_quadlets "${REPO_ROOT}"

	log_info "Pulling updated rootless container images as ${BITCART_USER}..."
	pull_stack_images

	log_info "Re-verifying Electrum /data/config auto_connect=false..."
	seed_electrum_config "${REPO_ROOT}"

	log_info "Reloading rootless systemd units and restarting services cleanly..."
	run_bitcart_systemctl daemon-reload

	local restart_units=(bitcart-database bitcart-redis bitcart-bitcoin)
	if has_crypto "xmr"; then
		restart_units+=(bitcart-monero)
	else
		run_bitcart_systemctl stop bitcart-monero.service >/dev/null 2>&1 || true
	fi
	restart_units+=(bitcart-backend bitcart-worker bitcart-checkout bitcart-gateway)

	local unit
	for unit in "${restart_units[@]}"; do
		run_bitcart_systemctl restart "${unit}.service"
	done

	if [[ "${admin_was_active}" == "true" ]]; then
		run_bitcart_systemctl restart bitcart-admin.service
	fi

	systemctl reload caddy.service
	wait_for_local_api 150

	log_info "Re-running idempotent provisioner (existing valid tokens preserved)..."
	local prov_args=()
	[[ "${FORCE_REPROVISION}" == "true" ]] && prov_args+=(--force-reprovision)
	[[ "${ROTATE_TOKENS}" == "true" ]] && prov_args+=(--rotate-tokens)
	bash "${SCRIPT_DIR}/provision.sh" "${prov_args[@]}"

	log_info "Running post-update verification..."
	local verify_args=()
	[[ "${CHECK_PROD_INVOICE}" == "true" ]] && verify_args+=(--check-prod-invoice)
	bash "${SCRIPT_DIR}/verify.sh" "${verify_args[@]}"

	log_ok "SUCCESS! Non-destructive update complete."
}

main "$@"
