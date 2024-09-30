#!/bin/bash

echo "Starting script at $(date)" >&2

# Function to escape label values for Prometheus
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
    METRICS+="\n$metric"
}

# Function to handle kubectl exec commands with detailed error logging
safe_exec() {
    local pod="$1"
    local namespace="$2"
    local command="$3"

    echo "Executing command in pod $pod (namespace: $namespace): $command" >&2

    # Execute the command inside the pod
    response=$(kubectl exec "$pod" -n "$namespace" -- /bin/sh -c "$command" 2>&1)
    exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "Command succeeded in pod $pod" >&2
        echo "$response"
        return 0
    else
        echo "Command failed in pod $pod with exit code $exit_code" >&2
        echo "Response: $response" >&2
        return 1
    fi
}

# Function to check if a pod can access the Kubernetes API
check_pod_api_access() {
    local pod_name="$1"
    local namespace="$2"

    echo "Checking API access for pod: $pod_name in namespace: $namespace" >&2

    # Define the API request command with conditional use of curl or wget
    api_command='if command -v curl >/dev/null 2>&1; then
                    curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
                         -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
                         https://kubernetes.default.svc/api/v1/namespaces
                elif command -v wget >/dev/null 2>&1; then
                    wget -qO- --ca-certificate=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
                         --header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
                         https://kubernetes.default.svc/api/v1/namespaces
                else
                    echo "no_curl_or_wget"
                fi'

    # Execute the API command inside the pod
    response=$(safe_exec "$pod_name" "$namespace" "$api_command")

    # Determine the metric based on the response
    if [[ $? -eq 0 ]]; then
        if [[ "$response" == "no_curl_or_wget" ]]; then
            echo "Neither curl nor wget is available in pod $pod_name" >&2
            metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} -1"
        elif echo "$response" | grep -q '"default"'; then
            echo "Pod $pod_name has API access" >&2
            metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} 1"
        else
            echo "Pod $pod_name does NOT have API access" >&2
            metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} 0"
        fi
    else
        echo "Failed to execute API command in pod $pod_name" >&2
        metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} 0"
    fi
}

# Function to collect metrics once
collect_metrics() {
    echo "Starting metric collection" >&2

    # Loop over all namespaces and pods
    echo "Fetching list of namespaces" >&2
    namespaces=$(kubectl get namespaces --no-headers -o custom-columns=":metadata.name")

    echo "Namespaces found: $namespaces" >&2
    for ns in $namespaces; do
        echo "Processing namespace: $ns" >&2

        echo "Fetching pods in namespace $ns" >&2
        pods=$(kubectl get pods -n "$ns" --no-headers -o custom-columns=":metadata.name")

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
METRICS_FILE="/tmp/metrics.log"
CURRENT_MIN=$((10#$(date +%M)))
RUN_BEFORE_MINUTE=${RUN_BEFORE_MINUTE:-"59"}  # Adjust as needed
EPOCH=$(date +%s)
METRICS=""

if [[ $CURRENT_MIN -lt ${RUN_BEFORE_MINUTE} ]]; then
    echo "Current minute ($CURRENT_MIN) is less than RUN_BEFORE_MINUTE ($RUN_BEFORE_MINUTE), starting metric collection" >&2

    echo "Clearing metrics file $METRICS_FILE" >&2
    METRICS=""

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

# Write metrics to file (to be scraped by Prometheus)
echo -e "$METRICS" > "$METRICS_FILE"

echo "Script completed at $(date)" >&2

# Optional: Serve metrics via HTTP (uncomment if needed)
# Function to serve metrics via HTTP
# serve_metrics() {
#     while true; do
#         echo -e "$METRICS" | nc -l -p 9100 -q 1
#     done
# }
#
# echo "Starting HTTP server to serve metrics on port 9100" >&2
# serve_metrics
