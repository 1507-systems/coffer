#!/usr/bin/env bash
# import.sh -- Import secrets from a keychain CSV dump
# CSV format: service,account,password
# Uses config/keychain-mapping.yaml to map service names to lockbox paths.
# Usage: lockbox import <csv-file>
set -euo pipefail

cmd_import() {
    local csv_file="${1:-}"
    [[ -n "$csv_file" ]] || die "Usage: lockbox import <csv-file>"
    [[ -f "$csv_file" ]] || die "CSV file not found: ${csv_file}"

    require_cmd sops
    require_cmd yq
    require_identity
    ensure_unlocked

    local mapping_file="${LOCKBOX_ROOT}/config/keychain-mapping.yaml"
    [[ -f "$mapping_file" ]] || die "Mapping file not found: ${mapping_file}"

    local imported=0
    local skipped=0
    local errors=0
    local skipped_services=()

    # Read CSV line by line, skipping the header
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))

        # Skip header row
        if [[ $line_num -eq 1 ]]; then
            # Verify it looks like a header
            if [[ "$line" == *"service"* ]] && [[ "$line" == *"password"* ]]; then
                continue
            fi
            # If it doesn't look like a header, process it as data
        fi

        # Skip empty lines
        [[ -n "$line" ]] || continue

        # Parse CSV fields (handle quoted fields with commas)
        # shellcheck disable=SC2034
        local service="" account="" password=""
        if ! parse_csv_line "$line" service account password; then
            warn "Failed to parse line ${line_num}: ${line}"
            errors=$((errors + 1))
            continue
        fi

        # Look up the service name in the mapping file
        local lockbox_path
        lockbox_path=$(yq ".mappings[\"${service}\"] // \"\"" "$mapping_file")

        if [[ -z "$lockbox_path" ]] || [[ "$lockbox_path" == "null" ]]; then
            warn "No mapping for service: ${service}"
            skipped_services+=("$service")
            skipped=$((skipped + 1))
            continue
        fi

        # Use the set command to store the secret
        # Source set.sh if not already loaded
        if ! type cmd_set &>/dev/null; then
            # shellcheck source=set.sh
            source "${LOCKBOX_ROOT}/lib/set.sh"
        fi

        if cmd_set "${lockbox_path}" "${password}"; then
            imported=$((imported + 1))
        else
            warn "Failed to import: ${service} -> ${lockbox_path}"
            errors=$((errors + 1))
        fi
    done < "$csv_file"

    # Print summary
    echo ""
    echo "Import complete:"
    echo "  Imported: ${imported}"
    echo "  Skipped (no mapping): ${skipped}"
    if [[ ${#skipped_services[@]} -gt 0 ]]; then
        for svc in "${skipped_services[@]}"; do
            echo "    - \"${svc}\""
        done
    fi
    echo "  Errors: ${errors}"
}

# Parse a single CSV line, handling quoted fields.
# Sets the three named variables (passed by name) to the parsed values.
parse_csv_line() {
    local line="$1"
    local -n _service="$2"
    local -n _account="$3"
    local -n _password="$4"

    # Simple CSV parser: handle quoted fields with possible commas inside
    local fields=()
    local current=""
    local in_quotes=false
    local i

    for ((i = 0; i < ${#line}; i++)); do
        local char="${line:i:1}"

        if [[ "$in_quotes" == true ]]; then
            if [[ "$char" == '"' ]]; then
                # Check for escaped quote (doubled)
                if [[ "${line:i+1:1}" == '"' ]]; then
                    current+="$char"
                    i=$((i + 1))
                else
                    in_quotes=false
                fi
            else
                current+="$char"
            fi
        else
            if [[ "$char" == '"' ]]; then
                in_quotes=true
            elif [[ "$char" == ',' ]]; then
                fields+=("$current")
                current=""
            else
                current+="$char"
            fi
        fi
    done
    fields+=("$current")

    # We need at least 3 fields
    if [[ ${#fields[@]} -lt 3 ]]; then
        return 1
    fi

    _service="${fields[0]}"
    _account="${fields[1]}"
    _password="${fields[2]}"
    return 0
}
