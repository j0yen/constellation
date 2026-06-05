#!/usr/bin/env bash
# lint-schema-crossref.sh — assert chezmoi per-host data keys agree with
# ansible host_vars keys. AC7 gate for constellation-appearance.
#
# Required keys that must appear in BOTH:
#   chezmoi: .chezmoidata/hosts/<hostname>.toml
#   ansible: ansible/host_vars/<hostname>.yml
#
# Exit 0 = all good. Exit 1 = mismatch (printed to stderr).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHEZMOI_DATA="${REPO_ROOT}/chezmoi/.chezmoidata/hosts"
ANSIBLE_HVARS="${REPO_ROOT}/ansible/host_vars"

REQUIRED_KEYS=(gpu voice_node)   # role and monitors use different formats; spot-check gpu+voice_node

fail=0

for chezmoi_file in "${CHEZMOI_DATA}"/*.toml; do
    hostname="$(basename "${chezmoi_file}" .toml)"
    ansible_file="${ANSIBLE_HVARS}/${hostname}.yml"

    if [[ ! -f "${ansible_file}" ]]; then
        echo "WARN: no ansible host_vars for ${hostname} (${ansible_file} missing)" >&2
        continue
    fi

    for key in "${REQUIRED_KEYS[@]}"; do
        # chezmoi side: key = "value" or key = true/false
        chezmoi_val=$(grep -E "^${key}\s*=" "${chezmoi_file}" | head -1 | sed 's/.*= *//' | tr -d '"' | tr -d "'" | xargs)
        # ansible side: key: value
        ansible_val=$(grep -E "^${key}:" "${ansible_file}" | head -1 | awk '{print $2}' | xargs)

        if [[ -z "${chezmoi_val}" ]]; then
            echo "FAIL: ${hostname}: key '${key}' missing from chezmoi data (${chezmoi_file})" >&2
            fail=1
            continue
        fi
        if [[ -z "${ansible_val}" ]]; then
            echo "FAIL: ${hostname}: key '${key}' missing from ansible host_vars (${ansible_file})" >&2
            fail=1
            continue
        fi

        # Normalise booleans (true/True/false/False)
        chezmoi_norm=$(echo "${chezmoi_val}" | tr '[:upper:]' '[:lower:]')
        ansible_norm=$(echo "${ansible_val}"  | tr '[:upper:]' '[:lower:]')

        if [[ "${chezmoi_norm}" != "${ansible_norm}" ]]; then
            echo "FAIL: ${hostname}: key '${key}' mismatch: chezmoi=${chezmoi_val} ansible=${ansible_val}" >&2
            fail=1
        else
            echo "OK:   ${hostname}: ${key} = ${chezmoi_val}"
        fi
    done
done

if [[ "${fail}" -eq 0 ]]; then
    echo "lint-schema-crossref: all checks passed"
    exit 0
else
    echo "lint-schema-crossref: FAILED — see errors above" >&2
    exit 1
fi
