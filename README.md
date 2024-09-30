About Exporter Kubernetes
==================

Exporter Kubernetes is a Prometheus exporter

TLDR: Have the Kubernetes incorrect settings in Your Grafana! This exporter will perform such process for You.

Usage
==================

- Run it as Your k8s with approriate rights.
- Feel free to use below helm-charts and settings

### Cluster Role:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pod-k8s-api-access-checker
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
```

License
==================
- This is fully OpenSource tool.
- Apache License, Version 2.0, January 2004

Contact
==================

- E-mail: info@lukaspastva.sk
