#!/bin/bash

echo "Starting script at $(date)" >&2

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
        echo "Adding metric: $metric" >&2
        echo "$metric" >> "$METRICS_FILE"
    else
        echo "Duplicate metric found, not adding: $metric" >&2
    fi
}

# Function to handle API requests with detailed error logging
safe_curl() {
    local url="$1"
    local method="${2:-GET}"
    local data="${3:-}"
    shift 3
    local headers=("$@")

    local max_retries=3
    local attempt=1
    local delay=5

    while [[ $attempt -le $max_retries ]]; do
        echo "Attempt $attempt: Making API request to URL: $url with method: $method" >&2

        # Prefix each header with -H
        local curl_headers=()
        for header in "${headers[@]}"; do
            curl_headers+=("-H" "$header")
        done

        local response
        local http_code
        response=$(curl -k -s -w "%{http_code}" -X "$method" "${curl_headers[@]}" "$url" -d "$data")
        http_code="${response: -3}"
        response="${response:0:${#response}-3}"

        if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
            echo "API request to $url succeeded on attempt $attempt" >&2
            echo "$response"
            return 0
        else
            echo "API request to $url failed with HTTP status $http_code on attempt $attempt" >&2
            echo "Response body: $response" >&2
            if [[ $attempt -lt $max_retries ]]; then
                echo "Retrying in $delay seconds..." >&2
                sleep $delay
            fi
        fi

        ((attempt++))
    done

    echo "API request to $url failed after $max_retries attempts" >&2
    return 1
}


# Function to request a token using the TokenRequest API
request_token() {
    local namespace="$1"
    local service_account="$2"

    echo "Requesting token for service account $service_account in namespace $namespace" >&2

    # Create the JSON payload for the TokenRequest
    local payload
    payload=$(cat <<EOF
{
    "apiVersion": "authentication.k8s.io/v1",
    "kind": "TokenRequest",
    "spec": {
        "audiences": ["kubernetes.default.svc"],
        "expirationSeconds": 600
    }
}
EOF
)

    # Use the existing safe_curl function to make the API request
    token_response=$(safe_curl "$KUBE_API/apis/authentication.k8s.io/v1/namespaces/$namespace/serviceaccounts/$service_account/token" "POST" "$payload" \
        "-H" "Authorization: Bearer $SA_TOKEN" "-H" "Content-Type: application/json")

    if [[ $? -eq 0 ]]; then
        echo "$token_response" | jq -r '.status.token'
    else
        echo "Failed to obtain token for service account $service_account in namespace $namespace" >&2
        echo "" >&2
    fi
}


# Function to check if a pod's service account has access to the Kubernetes API
check_pod_api_access() {
    local pod_name="$1"
    local namespace="$2"

    echo "Checking API access for pod: $pod_name in namespace: $namespace" >&2

    # Get the service account name for the pod
    echo "Retrieving service account name for pod $pod_name" >&2
    service_account_name=$(safe_curl "$KUBE_API/api/v1/namespaces/$namespace/pods/$pod_name" "GET" "" \
        "-H" "Authorization: Bearer $SA_TOKEN" "-H" "Content-Type: application/json" | jq -r '.spec.serviceAccountName')

    if [[ -z "$service_account_name" || "$service_account_name" == "null" ]]; then
        echo "Service account name not found for pod $pod_name" >&2
        metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} 0"
        return
    fi
    echo "Service account name: $service_account_name" >&2

    # Request a token using TokenRequest API
    pod_sa_token=$(request_token "$namespace" "$service_account_name")

    if [[ -z "$pod_sa_token" ]]; then
        echo "Token not found for service account $service_account_name" >&2
        metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} 0"
        return
    fi

    # Use the token to attempt an API access check (e.g., list namespaces)
    echo "Attempting to access Kubernetes API with pod's service account token" >&2
    response=$(safe_curl "$KUBE_API/api/v1/namespaces" "GET" "" \
        "-H" "Authorization: Bearer $pod_sa_token" "-H" "Content-Type: application/json")

    if [[ $? -eq 0 && $response == *"NamespaceList"* ]]; then
        echo "Pod $pod_name has API access" >&2
        metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} 1"
    else
        echo "Pod $pod_name does NOT have API access" >&2
        metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} 0"
    fi
}

# Function to collect metrics once
collect_metrics() {
    echo "Starting metric collection" >&2

    # Loop over all namespaces and pods
    echo "Fetching list of namespaces" >&2
    namespaces=$(safe_curl "$KUBE_API/api/v1/namespaces" "GET" "" \
        "-H" "Authorization: Bearer $SA_TOKEN" "-H" "Content-Type: application/json" | jq -r '.items[].metadata.name')

    echo "Namespaces found: $namespaces" >&2
    for ns in $namespaces; do
        echo "Processing namespace: $ns" >&2

        echo "Fetching pods in namespace $ns" >&2
        pods=$(safe_curl "$KUBE_API/api/v1/namespaces/$ns/pods" "GET" "" \
            "-H" "Authorization: Bearer $SA_TOKEN" "-H" "Content-Type: application/json" | jq -r '.items[].metadata.name')

        echo "Pods found in namespace $ns: $pods" >&2
        for pod in $pods; do
            check_pod_api_access "$pod" "$ns"
        done
    done

    # Add a heartbeat metric
    echo "Adding heartbeat metric" >&2
    metric_add "k8s_api_access_heartbeat $(date +%s)"
}

# Configuration
KUBE_API="https://kubernetes.default.svc"
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CA_CERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
METRICS_FILE="/tmp/metrics.log"
CURRENT_MIN=$((10#$(date +%M)))
RUN_BEFORE_MINUTE=${RUN_BEFORE_MINUTE:-"59"}  # Adjust as needed
EPOCH=$(date +%s)

if [[ $CURRENT_MIN -lt ${RUN_BEFORE_MINUTE} ]]; then
    echo "Current minute ($CURRENT_MIN) is less than RUN_BEFORE_MINUTE ($RUN_BEFORE_MINUTE), starting metric collection" >&2

    echo "Clearing metrics file $METRICS_FILE" >&2
    echo "" > "$METRICS_FILE"

    echo "Adding initial metrics" >&2
    metric_add "# scraping start $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    metric_add "kubernetes_heart_beat ${EPOCH}"
    metric_add "# HELP k8s_pod_api_access Whether a pod has access to the Kubernetes API."
    metric_add "# TYPE k8s_pod_api_access gauge"

    # Collect metrics once
    collect_metrics
else
    echo "Current minute ($CURRENT_MIN) is not less than RUN_BEFORE_MINUTE ($RUN_BEFORE_MINUTE), skipping metric collection" >&2
fi

echo "Script completed at $(date)" >&2
