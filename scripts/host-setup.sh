#!/usr/bin/env bash
# Idempotent AlmaLinux 10 host bootstrap for arkfile-bitcart.
# Preserves SELinux=enforcing, configures 2 GiB swap, installs rootless Podman
# and stock Caddy, creates the dedicated bitcart user, verifies overlay storage,
# and locks down firewalld including outbound cloud metadata egress blocking.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

verify_os_and_selinux() {
	[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
	# shellcheck disable=SC1091
	source /etc/os-release

	local major="${VERSION_ID%%.*}"
	if [[ "${major}" != "10" ]]; then
		die "Unsupported OS version (${PRETTY_NAME:-unknown}). Expected AlmaLinux or RHEL-family 10."
	fi
	log_ok "Verified OS: ${PRETTY_NAME:-AlmaLinux 10}"

	if ! command -v getenforce >/dev/null 2>&1; then
		die "SELinux tooling (getenforce) not found; expected SELinux=enforcing."
	fi
	local se_mode
	se_mode="$(getenforce)"
	if [[ "${se_mode}" != "Enforcing" ]]; then
		die "SELinux mode is '${se_mode}', expected 'Enforcing'. Enable SELinux enforcing mode before deploying."
	fi
	log_ok "SELinux mode verified: Enforcing"
}

ensure_swapfile() {
	local swap_total
	swap_total="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)"
	if (( swap_total > 0 )); then
		log_ok "Swap is already active (${swap_total} KiB)."
	else
		log_info "Creating 2 GiB /swapfile for 2 GB RAM VPS headroom..."
		if [[ ! -f /swapfile ]]; then
			if ! fallocate -l 2G /swapfile 2>/dev/null; then
				dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
			fi
		fi
		chmod 0600 /swapfile
		if ! file /swapfile 2>/dev/null | grep -qi "swap file"; then
			mkswap /swapfile >/dev/null
		fi
		swapon /swapfile
		log_ok "Enabled 2 GiB /swapfile."
	fi

	if [[ -f /swapfile ]] && ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
		printf '/swapfile none swap defaults 0 0\n' >> /etc/fstab
		log_ok "Persisted /swapfile in /etc/fstab."
	fi

	cat > /etc/sysctl.d/99-arkfile-bitcart-swap.conf <<'EOF'
vm.swappiness=20
EOF
	sysctl -q -p /etc/sysctl.d/99-arkfile-bitcart-swap.conf
	log_ok "Applied vm.swappiness=20."
}

install_packages() {
	log_info "Installing required AlmaLinux 10 packages..."
	dnf install -y \
		podman \
		slirp4netns \
		passt \
		fuse-overlayfs \
		jq \
		curl \
		firewalld \
		openssl \
		python3 \
		policycoreutils-python-utils \
		dnf-plugins-core

	if ! command -v caddy >/dev/null 2>&1; then
		log_info "Installing official stock Caddy from @caddy/caddy COPR..."
		dnf copr enable -y @caddy/caddy
		dnf install -y caddy
	fi

	log_ok "Required packages installed (podman, passt/slirp4netns, fuse-overlayfs, firewalld, jq, curl, caddy)."
}

ensure_subid_range() {
	local subfile="$1"
	local user="$2"
	touch "${subfile}"

	if grep -q "^${user}:" "${subfile}"; then
		log_ok "${subfile} already has an entry for ${user}."
		return 0
	fi

	local next_start
	next_start="$(awk -F: '
		BEGIN { max_end = 100000 }
		NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {
			end = $2 + $3
			if (end > max_end) max_end = end
		}
		END { print max_end }
	' "${subfile}")"

	printf '%s:%s:65536\n' "${user}" "${next_start}" >> "${subfile}"
	SUBID_CHANGED=true
	log_ok "Allocated ${user}:${next_start}:65536 in ${subfile}."
}

# podman system migrate stops all containers and races systemd Restart=on-failure
# if run while units are active or auto-restarting.
migrate_rootless_podman() {
	local list unit
	local -a managed_units=()
	list="$(run_bitcart_systemctl list-units --type=service --state=active,activating --no-legend --no-pager 'bitcart-*.service' | awk '{print $1}')"
	while IFS= read -r unit; do
		[[ -n "${unit}" ]] || continue
		managed_units+=("${unit}")
	done <<< "${list}"

	if ((${#managed_units[@]} > 0)); then
		log_info "Stopping bitcart units before podman system migrate: ${managed_units[*]}"
		run_bitcart_systemctl stop "${managed_units[@]}"
	fi

	run_bitcart_podman system migrate

	if ((${#managed_units[@]} > 0)); then
		log_info "Starting bitcart units stopped for podman system migrate."
		run_bitcart_systemctl start "${managed_units[@]}"
	fi
}

ensure_bitcart_account() {
	local user_created=false
	if ! id -u "${BITCART_USER}" >/dev/null 2>&1; then
		useradd --create-home --home-dir "${BITCART_HOME}" --shell /sbin/nologin "${BITCART_USER}"
		passwd -l "${BITCART_USER}" >/dev/null 2>&1 || true
		user_created=true
		log_ok "Created dedicated unprivileged user ${BITCART_USER}."
	else
		log_ok "User ${BITCART_USER} already exists."
	fi

	chmod 0700 "${BITCART_HOME}"
	if [[ -f "${BITCART_HOME}/.ssh/authorized_keys" ]]; then
		log_warn "Removing unexpected ${BITCART_HOME}/.ssh/authorized_keys."
		rm -f "${BITCART_HOME}/.ssh/authorized_keys"
	fi

	SUBID_CHANGED=false
	ensure_subid_range /etc/subuid "${BITCART_USER}"
	ensure_subid_range /etc/subgid "${BITCART_USER}"

	loginctl enable-linger "${BITCART_USER}"
	local uid
	uid="$(get_bitcart_uid)"
	systemctl start "user@${uid}.service"

	ensure_bitcart_user_ready
	local active_units running_containers
	active_units="$(run_bitcart_systemctl list-units --type=service --state=active,activating --no-legend --no-pager 'bitcart-*.service' | awk '{print $1}')"
	running_containers="$(run_bitcart_podman ps -q)"

	if [[ "${user_created}" == "true" || "${SUBID_CHANGED}" == "true" ]]; then
		migrate_rootless_podman
	elif [[ -z "${active_units}" && -z "${running_containers}" ]]; then
		run_bitcart_podman system migrate
	else
		log_ok "Rootless containers are running and subuid/subgid are unchanged; skipping podman system migrate."
	fi
	verify_rootless_overlay
}

configure_firewalld() {
	systemctl enable --now firewalld

	local default_zone
	default_zone="$(firewall-cmd --get-default-zone)"
	log_info "Configuring firewalld default zone (${default_zone}) to permit only ssh, http, https..."

	local svc
	for svc in $(firewall-cmd --permanent --zone="${default_zone}" --list-services); do
		case "${svc}" in
			ssh|http|https) ;;
			*)
				firewall-cmd --permanent --zone="${default_zone}" --remove-service="${svc}" >/dev/null
				;;
		esac
	done

	for svc in ssh http https; do
		firewall-cmd --permanent --zone="${default_zone}" --add-service="${svc}" >/dev/null
	done

	# Block host and rootless container egress to cloud link-local metadata (169.254.169.254/32).
	local policy_name="block-cloud-metadata"
	if ! firewall-cmd --permanent --get-policies | tr ' ' '\n' | grep -qx "${policy_name}"; then
		firewall-cmd --permanent --new-policy="${policy_name}" >/dev/null
	fi
	firewall-cmd --permanent --policy="${policy_name}" --add-ingress-zone=HOST >/dev/null
	firewall-cmd --permanent --policy="${policy_name}" --add-egress-zone=ANY >/dev/null
	firewall-cmd --permanent --policy="${policy_name}" --set-target=CONTINUE >/dev/null
	firewall-cmd --permanent --policy="${policy_name}" \
		--add-rich-rule='rule family="ipv4" destination address="169.254.169.254/32" drop' >/dev/null

	firewall-cmd --reload >/dev/null
	log_ok "firewalld configured (public: ssh/http/https only; outbound 169.254.169.254/32 blocked)."
}

configure_selinux_and_dirs() {
	if command -v getsebool >/dev/null 2>&1 && getsebool httpd_can_network_connect >/dev/null 2>&1; then
		setsebool -P httpd_can_network_connect 1
		log_ok "Enabled SELinux boolean httpd_can_network_connect for host Caddy loopback proxy."
	fi

	install -d -m 0700 /etc/arkfile-bitcart
	install -d -m 0700 "${CREDS_OUT_DIR}"
	install -d -m 0700 -o "${BITCART_USER}" -g "${BITCART_USER}" "${BITCART_SECRETS_DIR}"
	install -d -m 0755 -o "${BITCART_USER}" -g "${BITCART_USER}" "${BITCART_CONFIG_DIR}"
	install -d -m 0755 -o "${BITCART_USER}" -g "${BITCART_USER}" "${BITCART_QUADLET_DIR}"
	log_ok "Host and ${BITCART_USER} directories prepared."
}

main() {
	verify_os_and_selinux
	ensure_swapfile
	install_packages
	ensure_bitcart_account
	configure_firewalld
	configure_selinux_and_dirs
	log_ok "Host bootstrap complete."
}

main "$@"
