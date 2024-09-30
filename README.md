About Exporter Kubernetes
==================

Exporter Kubernetes is a Prometheus exporter

TLDR: Have the Kubernetes incorrect settings in Your Grafana! This exporter will perform such process for You.

Usage
==================

- Run it as Your k8s with approriate rights.
- Feel free to use below helm-charts and settings

### Helm-chartie values
```yaml
deployments:

  exporter-kubernetes:
    image: lukaspastva/exporter-kubernetes:1.0
    resources:
      limits:
        memory: 50Mi
      requests:
        cpu: 30m
        memory: 30Mi
    # TODO podSecurityContextRestricted: true
    ports:
      - name: http
        port: 9199
    serviceMonitor:
      enabled: true
      interval: 3600s

extraObjects:

- apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: exporter-kubernetes
  rules:
    - apiGroups: [""]
      resources:
        - pods
        - namespaces
        - serviceaccounts
        - secrets
      verbs:
        - get
        - list

- apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: exporter-kubernetes
  subjects:
    - kind: ServiceAccount
      name: exporter-kubernetes
      namespace: exporter
  roleRef:
    kind: ClusterRole
    name: exporter-kubernetes
    apiGroup: rbac.authorization.k8s.io

- apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata:
    name: exporter-kubernetes
    namespace: exporter
  rules:
    - apiGroups: ["authentication.k8s.io"]
      resources: ["tokenrequests"]
      verbs: ["create"]

- apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata:
    name: exporter-kubernetes
    namespace: exporter
  subjects:
    - kind: ServiceAccount
      name: exporter-kubernetes
      namespace: exporter
  roleRef:
    kind: Role
    name: exporter-kubernetes
    apiGroup: rbac.authorization.k8s.io

```

### PrometheusRules
```yaml
groups:
  - name: PodAPIAccessAlerts
    rules:
      - alert: PodHasAPIAccess
        expr: k8s_pod_api_access == 1
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Pod '{{ $labels.pod }}' has API access"
          description: "Pod '{{ $labels.pod }}' in namespace '{{ $labels.namespace }}' has access to the Kubernetes API."
```

License
==================
- This is fully OpenSource tool.
- Apache License, Version 2.0, January 2004

Contact
==================

- E-mail: info@lukaspastva.sk
