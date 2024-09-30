#!/bin/bash

echo "Starting script at $(date)" >&2

# Define system namespaces to exclude
EXCLUDED_NAMESPACES=("kube-system" "kube-public" "kube-node-lease" "istio-system" "cilium")

# Function to check if a namespace is excluded
is_excluded_namespace() {
    local ns="$1"
    for excluded in "${EXCLUDED_NAMESPACES[@]}"; do
        if [[ "$ns" == "$excluded" ]]; then
            return 0  # True: Excluded
        fi
    done
    return 1  # False: Not excluded
}

# Function to escape label values for Prometheus
escape_label_value() {
    local val="$1"
    val="${val//\\/\\\\}"  # Escape backslash
    val="${val//\"/\\\"}"  # Escape double quote
    val="${val//$'\n'/}"   # Remove newlines
    val="${val//$'\r'/}"   # Remove carriage returns
    echo -n "$val"
}

# Function to add metrics directly to the file without duplication
metric_add() {
    local metric="$1"
    if ! grep -Fxq "$metric" "$METRICS_FILE"; then
        echo "Adding metric: $metric" >&2
        echo "$metric" >> "$METRICS_FILE"
    else
        echo "Duplicate metric found, not adding: $metric" >&2
    fi
}

# Function to handle kubectl exec commands without echoing responses on failure
safe_exec() {
    local pod="$1"
    local namespace="$2"
    local container="$3"
    local command="$4"

    if [[ -n "$container" ]]; then
        response=$(kubectl exec "$pod" -n "$namespace" --container "$container" -- /bin/sh -c "$command" 2>/dev/null)
        exit_code=$?
    else
        response=$(kubectl exec "$pod" -n "$namespace" -- /bin/sh -c "$command" 2>/dev/null)
        exit_code=$?
    fi

    return $exit_code
}

# Function to check if a pod can access the Kubernetes API
check_pod_api_access() {
    local pod_name="$1"
    local namespace="$2"
    local container_name="$3"  # Optional: Specify container name if needed

    # Define the API request command with conditional use of curl or wget
    api_command='
    if command -v curl >/dev/null 2>&1; then
        curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
             -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
             https://kubernetes.default.svc/api/v1/namespaces
    elif command -v wget >/dev/null 2>&1; then
        if wget --help 2>&1 | grep -q "\-\-ca-certificate"; then
            wget -qO- --ca-certificate /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
                 --header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
                 https://kubernetes.default.svc/api/v1/namespaces
        else
            echo "wget_no_ca_cert"
        fi
    else
        echo "no_curl_or_wget"
    fi'

    safe_exec "$pod_name" "$namespace" "$container_name" "$api_command"
    exec_status=$?

    # Initialize metric value
    metric_value=0

    if [[ $exec_status -eq 0 ]]; then
        if [[ -n "$container_name" ]]; then
            response=$(kubectl exec "$pod_name" -n "$namespace" --container "$container_name" -- /bin/sh -c "$api_command" 2>/dev/null)
        else
            response=$(kubectl exec "$pod_name" -n "$namespace" -- /bin/sh -c "$api_command" 2>/dev/null)
        fi

        if [[ "$response" == "no_curl_or_wget" || "$response" == "wget_no_ca_cert" ]]; then
            metric_value=-1
        elif echo "$response" | grep -q '"default"'; then
            metric_value=1
        else
            metric_value=0
        fi
    else
        metric_value=-1
    fi

    metric_add "k8s_pod_api_access{namespace=\"$(escape_label_value "$namespace")\", pod=\"$(escape_label_value "$pod_name")\"} $metric_value"
}

# Function to collect metrics once
collect_metrics() {
    echo "Starting metric collection" >&2

    # Fetch all namespaces
    echo "Fetching list of namespaces" >&2
    namespaces=$(kubectl get namespaces --no-headers -o custom-columns=":metadata.name")

    echo "Namespaces found: $namespaces" >&2
    for ns in $namespaces; do
        if is_excluded_namespace "$ns"; then
            echo "Skipping excluded namespace: $ns" >&2
            continue
        fi

        echo "Processing namespace: $ns" >&2
        echo "Fetching pods in namespace $ns" >&2
        pods=$(kubectl get pods -n "$ns" --no-headers -o custom-columns=":metadata.name")

        echo "Pods found in namespace $ns: $pods" >&2
        for pod in $pods; do
            container_name=""
            check_pod_api_access "$pod" "$ns" "$container_name" &
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
