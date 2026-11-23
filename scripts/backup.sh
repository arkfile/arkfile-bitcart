#!/usr/bin/env bash
# Non-disruptive backup helper for arkfile-bitcart.
# Creates a mode-0600 archive containing a live pg_dump of the Bitcart
# PostgreSQL database, /home/bitcart/secrets, and /etc/arkfile-bitcart/bitcart.conf.
# Optionally encrypts the archive using age (BACKUP_AGE_RECIPIENT) or gpg
# (BACKUP_GPG_RECIPIENT) for off-VPS rsync/scp archival.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_root
load_operator_conf
verify_rootless_overlay

BACKUP_DIR="${BACKUP_DIR:-/var/backups/arkfile-bitcart}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"
BACKUP_GPG_RECIPIENT="${BACKUP_GPG_RECIPIENT:-}"

if [[ ! "${BACKUP_RETENTION_DAYS}" =~ ^[0-9]+$ ]] || (( BACKUP_RETENTION_DAYS < 1 )); then
	die "BACKUP_RETENTION_DAYS must be a positive integer."
fi

if [[ -n "${BACKUP_AGE_RECIPIENT}" && -n "${BACKUP_GPG_RECIPIENT}" ]]; then
	die "Set at most one of BACKUP_AGE_RECIPIENT or BACKUP_GPG_RECIPIENT."
fi

main() {
	umask 077
	install -d -m 0700 "${BACKUP_DIR}"

	local timestamp work_dir dump_file raw_archive final_archive
	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	work_dir="$(mktemp -d "${BACKUP_DIR}/.work-${timestamp}-XXXXXX")"
	trap 'rm -rf "${work_dir}"' EXIT

	dump_file="${work_dir}/bitcart-postgres.sql"
	log_info "Running non-disruptive pg_dump via rootless database container..."
	run_bitcart_podman exec database pg_dump -U postgres -d bitcart --clean --if-exists --no-owner > "${dump_file}"
	chmod 0600 "${dump_file}"
	[[ -s "${dump_file}" ]] || die "pg_dump produced an empty file."

	mkdir -p "${work_dir}/secrets" "${work_dir}/etc"
	cp -a "${BITCART_SECRETS_DIR}/." "${work_dir}/secrets/"
	cp -a "${OPERATOR_CONF}" "${work_dir}/etc/bitcart.conf"

	raw_archive="${work_dir}/arkfile-bitcart-${timestamp}.tar.gz"
	tar -C "${work_dir}" -czf "${raw_archive}" bitcart-postgres.sql secrets etc
	chmod 0600 "${raw_archive}"

	if [[ -n "${BACKUP_AGE_RECIPIENT}" ]]; then
		command -v age >/dev/null 2>&1 || die "BACKUP_AGE_RECIPIENT is set, but 'age' is not installed."
		final_archive="${BACKUP_DIR}/arkfile-bitcart-${timestamp}.tar.gz.age"
		age -r "${BACKUP_AGE_RECIPIENT}" -o "${final_archive}" "${raw_archive}"
		chmod 0600 "${final_archive}"
	elif [[ -n "${BACKUP_GPG_RECIPIENT}" ]]; then
		command -v gpg >/dev/null 2>&1 || die "BACKUP_GPG_RECIPIENT is set, but 'gpg' is not installed."
		final_archive="${BACKUP_DIR}/arkfile-bitcart-${timestamp}.tar.gz.gpg"
		gpg --batch --yes --trust-model always --encrypt -r "${BACKUP_GPG_RECIPIENT}" -o "${final_archive}" "${raw_archive}"
		chmod 0600 "${final_archive}"
	else
		final_archive="${BACKUP_DIR}/arkfile-bitcart-${timestamp}.tar.gz"
		mv -f "${raw_archive}" "${final_archive}"
		chmod 0600 "${final_archive}"
	fi

	find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'arkfile-bitcart-*.tar.gz*' -mtime "+${BACKUP_RETENTION_DAYS}" -delete

	log_ok "Backup written (mode 0600): ${final_archive}"
}

main "$@"
