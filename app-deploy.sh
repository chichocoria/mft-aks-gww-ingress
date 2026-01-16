#!/bin/bash
# Script Maestro de Despliegue Microfrontends

RG_NAME="Lab-Microfrontends-RG"
NAMESPACE="mfe-lab"
ACR_NAME=$(az acr list -g $RG_NAME --query "[0].name" -o tsv)
ACR_LOGIN_SERVER=$(az acr show -n $ACR_NAME --query loginServer -o tsv)

echo "--- 1. Construyendo Imágenes en $ACR_NAME ---"
# Usamos tag v5 (o la versión final corregida)
az acr build --registry $ACR_NAME --image foo-team:v5 ./foo-team
az acr build --registry $ACR_NAME --image bar-team:v5 ./bar-team

echo "--- 2. Desplegando en Kubernetes ---"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Generación del Manifiesto
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: foo-team
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: foo-team
  template:
    metadata:
      labels:
        app: foo-team
    spec:
      containers:
      - name: foo
        image: $ACR_LOGIN_SERVER/foo-team:v5
        ports:
        - containerPort: 3001
---
apiVersion: v1
kind: Service
metadata:
  name: foo-team
  namespace: $NAMESPACE
spec:
  ports:
  - port: 80
    targetPort: 3001
  selector:
    app: foo-team
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bar-team
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bar-team
  template:
    metadata:
      labels:
        app: bar-team
    spec:
      containers:
      - name: bar
        image: $ACR_LOGIN_SERVER/bar-team:v5
        ports:
        - containerPort: 3002
---
apiVersion: v1
kind: Service
metadata:
  name: bar-team
  namespace: $NAMESPACE
spec:
  ports:
  - port: 80
    targetPort: 3002
  selector:
    app: bar-team
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mfe-ingress
  namespace: $NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/ssi: "true"
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /bar
        pathType: Prefix
        backend:
          service:
            name: bar-team
            port:
              number: 80
      - path: /
        pathType: Prefix
        backend:
          service:
            name: foo-team
            port:
              number: 80
EOF

echo "--- ¡Despliegue Exitoso! ---"