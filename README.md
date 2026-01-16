1. Infraestructura en Azure (AKS + App Gateway).
2. Networking complejo (NSGs + Health Probes).
3. Microfrontends comunicándose (Server Side Includes - SSI).


# 📘 Guía Lab Microfrontends en Azure (AKS + AppGateway)

## ☁️ Fase 1: Infraestructura y Networking (Azure)

Asumimos que ya creaste el AKS, el ACR y el Application Gateway. Ahora aplicaremos las configuraciones críticas de red que desbloquearon el tráfico.

### 1. Instalar Ingress Controller Interno

Instalamos NGINX escuchando en una IP privada fija dentro de la VNET.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Instalación con IP Fija y Sonda en /healthz
helm install nginx-internal ingress-nginx/ingress-nginx \
    --namespace ingress-internal --create-namespace \
    --set controller.service.loadBalancerIP=10.0.1.250 \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"=true \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
    --set controller.service.externalTrafficPolicy=Cluster

```

### 2. Abrir el Firewall (NSG) del AKS

El Application Gateway vive en otra subred (`10.0.2.0/24`) y el AKS lo bloquea por defecto.

**Acción:** Buscar el NSG en el grupo de recursos de los nodos (`MC_...`) y aplicar:

* **Regla:** `AllowAGWInbound`
* **Origen:** `10.0.2.0/24` (Subred del Gateway)
* **Destino:** `Any` (o puertos 80/443)
* **Acción:** `Allow`

```
#!/bin/bash

RG="Lab-Microfrontends-RG"
VNET_NAME="vnet-mfe-lab"
AKS_SUBNET_NAME="snet-aks"
AGW_SUBNET_PREFIX="10.0.2.0/24" # El rango de tu subred de Gateway

echo "--- Diagnóstico de Seguridad ---"
# 1. Obtener el ID del NSG que protege a la subred del AKS
NSG_ID=$(az network vnet subnet show -g $RG -n $AKS_SUBNET_NAME --vnet-name $VNET_NAME --query networkSecurityGroup.id -o tsv)

if [ -z "$NSG_ID" ]; then
    echo "ALERTA: La subred del AKS no tiene un NSG asociado explícitamente."
    echo "Intentando buscar el NSG en el grupo de recursos 'MC_...' (el que crea AKS automáticamente)..."
    # Buscamos el grupo de recursos gestionado por AKS (suele empezar por MC_)
    NODE_RG=$(az aks show -g $RG -n aks-mfe-lab --query nodeResourceGroup -o tsv)
    echo "Grupo de nodos: $NODE_RG"
    
    # Buscamos el NSG dentro de ese grupo (normalmente se llama aks-agentpool-...)
    NSG_NAME=$(az network nsg list -g $NODE_RG --query "[0].name" -o tsv)
    
    if [ -z "$NSG_NAME" ]; then
        echo "ERROR: No pude encontrar el NSG del AKS automáticamete. Tendrás que hacerlo manual."
        exit 1
    fi
    echo "NSG Encontrado: $NSG_NAME en $NODE_RG"
    
    echo "--- Aplicando Regla de Firewall (Allow-AGW) ---"
    az network nsg rule create \
      --resource-group $NODE_RG \
      --nsg-name $NSG_NAME \
      --name AllowAGWInbound \
      --priority 150 \
      --source-address-prefixes $AGW_SUBNET_PREFIX \
      --destination-port-ranges 80 443 \
      --direction Inbound \
      --access Allow \
      --protocol Tcp \
      --description "Permitir trafico desde App Gateway"
      
else
    # Caso 2: El NSG está en tu grupo de recursos principal (menos común en setups default pero posible)
    NSG_NAME=$(echo $NSG_ID | cut -d/ -f9)
    echo "NSG Encontrado asociado a la subnet: $NSG_NAME"
    
    echo "--- Aplicando Regla de Firewall (Allow-AGW) ---"
    az network nsg rule create \
      --resource-group $RG \
      --nsg-name $NSG_NAME \
      --name AllowAGWInbound \
      --priority 150 \
      --source-address-prefixes $AGW_SUBNET_PREFIX \
      --destination-port-ranges 80 443 \
      --direction Inbound \
      --access Allow \
      --protocol Tcp \
      --description "Permitir trafico desde App Gateway"
fi

echo "--- REGLA APLICADA ---"
echo "Espera 1 minuto y verifica nuevamente el Backend Health."
```

### 3. Permitir Sonda del Balanceador Azure

Para que Azure sepa que el Nginx está vivo.

* **Regla:** `AllowAzureLBProbe`
* **Origen:** `168.63.129.16` (IP Publica reservada de Azure)
* **Acción:** `Allow`



---

## 🚀 Fase 3: Configuración del Application Gateway

Para evitar el error **502 Bad Gateway** o **Unhealthy Backend**.

### Crear Health Probe Personalizada

El Gateway debe preguntar por `/healthz` y aceptar códigos 200-399.

```bash
# 1. Variables
RG="Lab-Microfrontends-RG"
AGW_NAME="agw-mfe-public"
PROBE_NAME="probe-nginx-internal"
HTTP_SETTINGS="appGatewayBackendHttpSettings"

echo "--- 1. Creando (o corrigiendo) la Sonda /healthz ---"
# Usamos 'create' para asegurar que se genere si no existía
az network application-gateway probe create \
  --resource-group $RG \
  --gateway-name $AGW_NAME \
  --name $PROBE_NAME \
  --path "/healthz" \
  --protocol Http \
  --host "127.0.0.1" \
  --interval 30 \
  --timeout 30 \
  --threshold 3 \
  --match-status-codes "200-399"

echo "--- 2. Asociando Sonda al Backend ---"
# Es fundamental volver a ejecutar esto para asegurar que el Gateway la use
az network application-gateway http-settings update \
  --resource-group $RG \
  --gateway-name $AGW_NAME \
  --name $HTTP_SETTINGS \
  --probe $PROBE_NAME

```

---

## 📦 Fase 4: Despliegue Automatizado (Script Final)

Este script hace todo: Build, Push, Generación de YAML dinámico y Apply.

**Archivo:** `deploy-apps.sh`

```bash
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

```

---

## ✅ Resumen de la Arquitectura Final

1. **Usuario** entra por la IP Pública del App Gateway.
2. **App Gateway** valida salud contra `10.0.1.250/healthz` (Status 200).
3. **App Gateway** envía tráfico a la IP privada del Load Balancer Interno (`10.0.1.250`).
4. **Nginx Ingress** recibe la petición.
* Si es `/`, manda a `foo-team`.
* Si el HTML de `foo-team` tiene ``, Nginx hace una sub-petición interna a `bar-team` (SSI).


5. **Nginx** combina todo y devuelve la página completa con el coche y la barra lateral.