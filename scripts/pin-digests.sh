#!/usr/bin/env bash
# Resolve container image tags in images.env to immutable @sha256 digests.
# Uses skopeo if available or rootless Podman as bitcart (never rootful Podman).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_root

IMAGES_FILE="${REPO_ROOT}/images.env"
load_images_env "${REPO_ROOT}"

resolve_digest() {
	local ref="$1"
	local repo="${ref%@*}"
	# Remove tag suffix while preserving registry port colons.
	local last_part="${repo##*/}"
	if [[ "${last_part}" == *:* ]]; then
		repo="${repo%:*}"
	fi

	local digest=""
	if command -v skopeo >/dev/null 2>&1; then
		digest="$(skopeo inspect --format '{{.Digest}}' "docker://${ref}")"
	else
		run_bitcart_podman pull -q "${ref}" >/dev/null
		digest="$(run_bitcart_podman inspect --format '{{.Digest}}' "${ref}")"
		if [[ -z "${digest}" || "${digest}" == "<no value>" ]]; then
			digest="$(run_bitcart_podman inspect --format '{{index .RepoDigests 0}}' "${ref}" | awk -F'@' '{print $2}')"
		fi
	fi

	[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "Could not resolve sha256 digest for ${ref} (got: ${digest})."
	printf '%s@%s' "${repo}" "${digest}"
}

main() {
	if ! command -v skopeo >/dev/null 2>&1; then
		verify_rootless_overlay
	fi

	local tmp_file="${IMAGES_FILE}.tmp.$$"
	: > "${tmp_file}"

	local line key val pinned
	while IFS= read -r line || [[ -n "${line}" ]]; do
		line="${line%$'\r'}"
		if [[ "${line}" =~ ^(IMAGE_[A-Z0-9_]+)=(.+)$ ]]; then
			key="${BASH_REMATCH[1]}"
			val="${BASH_REMATCH[2]}"
			log_info "Resolving ${key} (${val})..."
			pinned="$(resolve_digest "${val}")"
			printf '%s=%s\n' "${key}" "${pinned}" >> "${tmp_file}"
			log_ok "${key}=${pinned}"
		else
			printf '%s\n' "${line}" >> "${tmp_file}"
		fi
	done < "${IMAGES_FILE}"

	mv -f "${tmp_file}" "${IMAGES_FILE}"
	chmod 0644 "${IMAGES_FILE}"
	log_ok "Updated ${IMAGES_FILE} with immutable @sha256 digests."
}

main "$@"
