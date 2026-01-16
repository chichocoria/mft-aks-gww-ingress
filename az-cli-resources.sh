#!/bin/bash

# --- 1. Variables de Configuración ---
RG_NAME="Lab-Microfrontends-RG"
LOCATION="eastus2"
ACR_PREFIX="acrchicholab" 
AKS_NAME="aks-mfe-lab"
VNET_NAME="vnet-mfe-lab"
AK_SUBNET="snet-aks"
AGW_SUBNET="snet-appgw"
AGW_NAME="agw-mfe-public"
AGW_PUBLIC_IP_NAME="pip-agw-mfe"
WAF_POLICY_NAME="waf-policy-mfe" # Nueva variable para la política
INTERNAL_INGRESS_IP="10.0.1.250"

# Colores
print_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
print_success() { echo -e "\e[32m[OK]\e[0m $1"; }
print_skip() { echo -e "\e[33m[OMITIDO]\e[0m $1"; }

# --- FUNCIÓN DE CREACIÓN ---
crear_recursos() {
    print_info "Iniciando despliegue en $LOCATION..."

    # 1. Grupo de Recursos
    if [ $(az group exists --name $RG_NAME) = "true" ]; then
        print_skip "El Grupo de Recursos '$RG_NAME' ya existe."
    else
        print_info "Creando Grupo de Recursos: $RG_NAME..."
        az group create --name $RG_NAME --location $LOCATION
    fi

    # 2. Red Virtual
    az network vnet show -g $RG_NAME -n $VNET_NAME &>/dev/null
    if [ $? -eq 0 ]; then
        print_skip "La VNet '$VNET_NAME' ya existe."
    else
        print_info "Creando VNet y Subredes..."
        az network vnet create \
          --resource-group $RG_NAME \
          --name $VNET_NAME \
          --address-prefix 10.0.0.0/16 \
          --subnet-name $AK_SUBNET \
          --subnet-prefix 10.0.1.0/24

        az network vnet subnet create \
          --resource-group $RG_NAME \
          --vnet-name $VNET_NAME \
          --name $AGW_SUBNET \
          --address-prefix 10.0.2.0/24
    fi

    # 3. ACR
    EXISTING_ACR=$(az acr list -g $RG_NAME --query "[?starts_with(name, '$ACR_PREFIX')].name | [0]" -o tsv)
    if [ -n "$EXISTING_ACR" ]; then
        ACR_NAME=$EXISTING_ACR
        print_skip "Se encontró ACR existente: '$ACR_NAME'. Se reutilizará."
    else
        ACR_NAME="${ACR_PREFIX}${RANDOM}"
        print_info "Creando ACR nuevo: $ACR_NAME..."
        az acr create --resource-group $RG_NAME --name $ACR_NAME --sku Basic
    fi

    # 4. AKS (FIX CIDR APLICADO)
    az aks show -g $RG_NAME -n $AKS_NAME &>/dev/null
    if [ $? -eq 0 ]; then
        print_skip "El Cluster AKS '$AKS_NAME' ya existe."
    else
        print_info "Creando Cluster AKS (esto puede tardar unos 5-7 minutos)..."
        SUBNET_ID=$(az network vnet subnet show --resource-group $RG_NAME --vnet-name $VNET_NAME --name $AK_SUBNET --query id -o tsv)
        
        # FIX: --service-cidr y --dns-service-ip para evitar conflicto con la VNet 10.0.0.0/16
        az aks create \
          --resource-group $RG_NAME \
          --name $AKS_NAME \
          --node-count 1 \
          --node-vm-size Standard_B2s \
          --tier "Free" \
          --network-plugin azure \
          --network-plugin-mode "overlay" \
          --service-cidr 10.1.0.0/16 \
          --dns-service-ip 10.1.0.10 \
          --enable-managed-identity \
          --vnet-subnet-id $SUBNET_ID \
          --attach-acr $ACR_NAME \
          --enable-addons azure-keyvault-secrets-provider \
          --generate-ssh-keys
    fi

    # 5. IP Pública
    az network public-ip show -g $RG_NAME -n $AGW_PUBLIC_IP_NAME &>/dev/null
    if [ $? -eq 0 ]; then
        print_skip "La IP Pública '$AGW_PUBLIC_IP_NAME' ya existe."
    else
        print_info "Creando IP Pública..."
        az network public-ip create \
          --resource-group $RG_NAME \
          --name $AGW_PUBLIC_IP_NAME \
          --allocation-method Static \
          --sku Standard
    fi

    # 6. Política WAF (NUEVO PASO REQUERIDO PARA WAF_v2)
    az network application-gateway waf-policy show -g $RG_NAME -n $WAF_POLICY_NAME &>/dev/null
    if [ $? -eq 0 ]; then
        print_skip "La Política WAF '$WAF_POLICY_NAME' ya existe."
    else
        print_info "Creando Política WAF (Firewall)..."
        az network application-gateway waf-policy create \
          --resource-group $RG_NAME \
          --name $WAF_POLICY_NAME \
          --location $LOCATION \
          --type OWASP \
          --version 3.2
    fi

    # 7. Application Gateway (FIX WAF APLICADO)
    az network application-gateway show -g $RG_NAME -n $AGW_NAME &>/dev/null
    if [ $? -eq 0 ]; then
        print_skip "El Application Gateway '$AGW_NAME' ya existe."
    else
        print_info "Creando Application Gateway (WAF v2)... Esto tarda unos 10-15 min."
        
        # FIX: Agregado --waf-policy para solucionar el error de configuración faltante
        az network application-gateway create \
          --name $AGW_NAME \
          --resource-group $RG_NAME \
          --location $LOCATION \
          --sku WAF_v2 \
          --capacity 1 \
          --vnet-name $VNET_NAME \
          --subnet $AGW_SUBNET \
          --public-ip-address $AGW_PUBLIC_IP_NAME \
          --priority 100 \
          --http-settings-protocol Http \
          --http-settings-port 80 \
          --waf-policy $WAF_POLICY_NAME \
          --servers "$INTERNAL_INGRESS_IP"
    fi

    print_success "--- Infraestructura Lista ---"
    echo " > ACR Name: $ACR_NAME"
    echo " > IP Publica Gateway: $(az network public-ip show --resource-group $RG_NAME --name $AGW_PUBLIC_IP_NAME --query ipAddress -o tsv)"
    echo " > IMPORTANTE: Usa la IP interna $INTERNAL_INGRESS_IP al instalar el Nginx Ingress."
}

# --- FUNCIÓN DE DESTRUCCIÓN ---
eliminar_recursos() {
    if [ $(az group exists --name $RG_NAME) = "false" ]; then
        print_skip "El grupo de recursos $RG_NAME no existe."
        return
    fi

    echo -e "\e[31m[PELIGRO]\e[0m Estás a punto de borrar TODO el grupo de recursos: $RG_NAME"
    read -p "¿Estás seguro? (s/n): " confirm
    if [[ $confirm == "s" || $confirm == "S" ]]; then
        print_info "Eliminando Grupo de Recursos (esto se ejecuta en segundo plano)..."
        az group delete --name $RG_NAME --yes --no-wait
        print_success "Orden de eliminación enviada."
    else
        print_info "Operación cancelada."
    fi
}

# --- MENÚ ---
echo "--------------------------------------------"
echo "   LABORATORIO MICROFRONTENDS - GESTOR      "
echo "--------------------------------------------"
PS3='Selecciona una opción: '
opciones=("Crear Laboratorio" "Destruir Laboratorio" "Salir")
select opt in "${opciones[@]}"
do
    case $opt in
        "Crear Laboratorio") crear_recursos; break ;;
        "Destruir Laboratorio") eliminar_recursos; break ;;
        "Salir") echo "Saliendo..."; break ;;
        *) echo "Opción inválida $REPLY";;
    esac
done