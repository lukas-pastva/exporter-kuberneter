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
    image: lukaspastva/exporter-kubernetes:1.0.2
    resources:
      limits:
        memory: 350Mi
      requests:
        cpu: 30m
        memory: 100Mi
    # TODO podSecurityContextRestricted: true
    ports:
      - name: http
        port: 9199
    rbacDisabled: true
    env:
    - name: "RUN_BEFORE_MINUTE"
      value: "5"
    serviceMonitor:
      enabled: true
      interval: 3600s

extraObjects:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: exporter-kubernetes
    labels:
      argocd.argoproj.io/instance: exporter-kubernetes
  rules:
    - apiGroups:
        - ""
      resources:
        - pods
        - namespaces
        - serviceaccounts
        - secrets
      verbs:
        - get
        - list
    - apiGroups:
        - authentication.k8s.io
      resources:
        - serviceaccounts/token
      verbs:
        - create
        - get
    - apiGroups:
        - ""
      resources:
        - pods/exec
      verbs:
        - create
- apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: exporter-kubernetes
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: exporter-kubernetes
  subjects:
    - kind: ServiceAccount
      name: exporter-kubernetes
      namespace: exporter
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
