#!/bin/bash

# Function to escape label values
escape_label_value() {
    local val="$1"
    val="${val//\\/\\\\}"  # Escape backslash
    val="${val//\"/\\\"}"  # Escape double quote
    val="${val//$'\n'/}"   # Remove newlines
    val="${val//$'\r'/}"   # Remove carriage returns
    echo -n "$val"
}

# Function to add metrics without duplication
metric_add() {
    local metric="$1"
    if ! grep -Fxq "$metric" "$METRICS_FILE"; then
        echo "$metric" >> "$METRICS_FILE"
    else
        echo "Duplicate metric found, not adding: $metric" >&2
    fi
}

# Function to handle retries for API requests and log requests and failures
safe_curl() {
    local url="$1"
    local method="${2:-GET}"
    local data="${3:-}"
    shift 3
    local headers=("$@")
    local retries=1
    local wait_time=1

    # Prefix each header with -H
    local curl_headers=()
    for header in "${headers[@]}"; do
        curl_headers+=("-H" "$header")
    done

    for i in $(seq 1 "$retries"); do
        # Log the request
        echo "$method $url" >> /tmp/curl_requests.log
        # Perform the request
        response=$(curl -k -s -f -X "$method" "${curl_headers[@]}" "$url" -d "$data")
        local exit_status=$?
        if [[ $exit_status -eq 0 ]]; then
            echo "$response"
            return 0
        fi
        echo "Attempt $i failed for URL: $url" >&2
        sleep "$wait_time"
    done
    echo "All $retries attempts failed for URL: $url" >&2
    echo "$url" >> /tmp/curl_failures.log
    return 1
}

# Function to authenticate with Vault using Kubernetes service account token
authenticate_vault() {
    local jwt=$(cat "/var/run/secrets/kubernetes.io/serviceaccount/token")
    local payload=$(jq -n --arg jwt "$jwt" --arg role "$ROLE_NAME" '{"jwt": $jwt, "role": $role}')
    local response=$(safe_curl "$VAULT_ADDR/v1/auth/kubernetes/login" "POST" "$payload" "-H" "Content-Type: application/json")
    local vault_token=$(echo "$response" | jq -r '.auth.client_token')
    if [[ -z "$vault_token" || "$vault_token" == "null" ]]; then
        echo "Failed to authenticate with Vault." >&2
        exit 1
    fi
    echo "$vault_token"
}

# Function to query Vault for a token's expiration using its accessor and write to the metrics file
query_token_expiration() {
    local description="$1"
    local accessor="$2"
    local vault_token="$3"

    local payload=$(jq -n --arg accessor "$accessor" '{"accessor": $accessor}')
    local response=$(safe_curl "$VAULT_ADDR/v1/auth/token/lookup-accessor" "POST" "$payload" "-H" "Content-Type: application/json" "-H" "X-Vault-Token: $vault_token") || {
        metric_add "vault_token_expiration_time_seconds{description=\"$(escape_label_value "$description")\", error=\"lookup_failed\"} -1"
        return
    }

    local expire_time
    expire_time=$(echo "$response" | jq -r '.data.expire_time')

    if [[ "$expire_time" != "null" && -n "$expire_time" ]]; then
        # Convert ISO 8601 date to epoch seconds
        local expiration_epoch=$(date -u -d "$expire_time" +"%s")
        local current_epoch=$(date -u +%s)
        local remaining_seconds=$((expiration_epoch - current_epoch))

        # Prevent negative remaining time
        if [[ "$remaining_seconds" -lt 0 ]]; then
            remaining_seconds=0
        fi

        # Write the metric
        metric_add "vault_token_expiration_time_seconds{description=\"$(escape_label_value "$description")\"} $remaining_seconds"
    else
        metric_add "vault_token_expiration_time_seconds{description=\"$(escape_label_value "$description")\", error=\"lookup_failed\"} -1"
    fi
}

# Function to initialize the metrics file with headers
initialize_metrics() {
    echo "# HELP vault_token_expiration_time_seconds The expiration time of Vault tokens in seconds from now." > "$METRICS_FILE"
    echo "# TYPE vault_token_expiration_time_seconds gauge" >> "$METRICS_FILE"
}

# Function to collect metrics once
collect_metrics() {
    # Clear and initialize the metrics file
    initialize_metrics

    # Authenticate with Vault
    local vault_token=$(authenticate_vault)

    # Read accessors and query their expiration
    while IFS=: read -r description accessor || [[ -n "$description" ]]; do
        query_token_expiration "$description" "$accessor" "$vault_token"
    done < "$ACCESSORS_FILE"

    # Add a heartbeat metric
    metric_add "vault_heart_beat $(date +%s)"
}

# set -euo pipefail
# Configuration
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
ACCESSORS_FILE="/vault/secrets/vault-accessors"
METRICS_FILE="/tmp/metrics.log"
ROLE_NAME="${ROLE_NAME:-your_role_name}"
CURRENT_MIN=$((10#$(date +%M)))
RUN_BEFORE_MINUTE=${RUN_BEFORE_MINUTE:-"5"}

if [[ $CURRENT_MIN -lt ${RUN_BEFORE_MINUTE} ]]; then
    # Initialize logs
    : > /tmp/metrics.log
    : > /tmp/curl_requests.log
    : > /tmp/curl_failures.log

    # Collect metrics once
    collect_metrics
fi
