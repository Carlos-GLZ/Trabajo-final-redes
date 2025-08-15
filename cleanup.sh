#!/bin/bash
set -euo pipefail

REGION="us-east-1"
FORCE_EIP="false"
DRY_RUN="false"

print_usage() {
  cat <<EOF
Uso: $0 [--region <aws-region>] [--force-eip] [--dry-run]

Opciones:
  --region <r>    Región AWS (default: us-east-1)
  --force-eip     Desasocia y libera TODAS las EIPs (¡cuidado!)
  --dry-run       Modo simulación: muestra lo que haría, sin ejecutar

Ejemplos:
  $0
  $0 --region us-east-1
  $0 --force-eip
  $0 --dry-run
EOF
}

# --- Parseo simple de flags ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="${2:-$REGION}"; shift 2;;
    --force-eip) FORCE_EIP="true"; shift;;
    --dry-run) DRY_RUN="true"; shift;;
    -h|--help) print_usage; exit 0;;
    *) echo "Opción no reconocida: $1"; print_usage; exit 1;;
  esac
done

echo "=== 🔥 LIMPIEZA DE AWS Y LLAVES LOCALES ($REGION) ==="
echo "[INFO] force-eip=$FORCE_EIP  dry-run=$DRY_RUN"
echo

# 1) Instancias EC2 (running/stopped)
echo "➡️  Eliminando instancias EC2..."
EC2_IDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=running,stopped,stopping,pending" \
  --query "Reservations[].Instances[].InstanceId" --output text)
if [[ -n "${EC2_IDS:-}" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "🔎 [DRY-RUN] Terminaría instancias: $EC2_IDS"
  else
    aws ec2 terminate-instances --instance-ids $EC2_IDS --region "$REGION" >/dev/null
    aws ec2 wait instance-terminated --instance-ids $EC2_IDS --region "$REGION"
    echo "✅ Instancias eliminadas."
  fi
else
  echo "⚠️  No hay instancias activas para eliminar."
fi

# 2) Borrar KeyPairs en AWS (opcional: limita por prefijo)
echo "➡️  Eliminando KeyPairs en AWS..."
KEYS=$(aws ec2 describe-key-pairs --region "$REGION" --query "KeyPairs[].KeyName" --output text)
if [[ -n "${KEYS:-}" ]]; then
  for KEY in $KEYS; do
    # Si quieres solo tus llaves de proyecto, usa: [[ "$KEY" == pitchzone-* ]] || continue
    echo "🗑️  AWS KeyPair: $KEY"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "🔎 [DRY-RUN] Borraría KeyPair $KEY"
    else
      aws ec2 delete-key-pair --key-name "$KEY" --region "$REGION" || true
    fi
  done
else
  echo "⚠️  No hay KeyPairs en AWS."
fi

# 3) Borrar .pem locales (en el directorio actual)
echo "➡️  Eliminando archivos .pem locales en $(pwd)..."
if [[ "$DRY_RUN" == "true" ]]; then
  echo "🔎 [DRY-RUN] Eliminaría:"; find . -type f -name "*.pem" -print || true
else
  find . -type f -name "*.pem" -print -delete || true
  echo "✅ Archivos .pem locales eliminados."
fi

# 4) VPCs NO por defecto (con sus recursos)
echo "➡️  Eliminando VPCs personalizadas..."
VPCS=$(aws ec2 describe-vpcs --region "$REGION" \
  --query "Vpcs[?IsDefault==\`false\`].VpcId" --output text)
if [[ -n "${VPCS:-}" ]]; then
  for VPC in $VPCS; do
    echo "🗑️  VPC: $VPC"

    # Desasociar y borrar IGW
    IGWS=$(aws ec2 describe-internet-gateways --region "$REGION" \
      --filters Name=attachment.vpc-id,Values=$VPC \
      --query "InternetGateways[].InternetGatewayId" --output text)
    for IGW in $IGWS; do
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "🔎 [DRY-RUN] Desasociaría y borraría IGW $IGW"
      else
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC" --region "$REGION" || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$REGION" || true
      fi
    done

    # Subnets
    SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
      --filters Name=vpc-id,Values=$VPC --query "Subnets[].SubnetId" --output text)
    for S in $SUBNETS; do
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "🔎 [DRY-RUN] Borraría Subnet $S"
      else
        aws ec2 delete-subnet --subnet-id "$S" --region "$REGION" || true
      fi
    done

    # Route tables (no la principal)
    RTBS=$(aws ec2 describe-route-tables --region "$REGION" \
      --filters Name=vpc-id,Values=$VPC --query "RouteTables[].{Id:RouteTableId,Main:Associations[?Main].Main|[0]}" --output text)
    # Salida tipo: "rtb-12345    True" o "rtb-67890    False"
    while read -r RTB MAIN; do
      [[ -z "${RTB:-}" ]] && continue
      [[ "$MAIN" == "True" ]] && continue
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "🔎 [DRY-RUN] Borraría Route Table $RTB"
      else
        aws ec2 delete-route-table --route-table-id "$RTB" --region "$REGION" || true
      fi
    done <<< "$RTBS"

    # Security Groups (no el default)
    SGS=$(aws ec2 describe-security-groups --region "$REGION" \
      --filters Name=vpc-id,Values=$VPC --query "SecurityGroups[].{Id:GroupId,Name:GroupName}" --output text)
    while read -r SGID SGNAME; do
      [[ -z "${SGID:-}" ]] && continue
      [[ "$SGNAME" == "default" ]] && continue
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "🔎 [DRY-RUN] Borraría SG $SGID ($SGNAME)"
      else
        aws ec2 delete-security-group --group-id "$SGID" --region "$REGION" 2>/dev/null || true
      fi
    done <<< "$SGS"

    # Finalmente, la VPC
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "🔎 [DRY-RUN] Borraría VPC $VPC"
    else
      aws ec2 delete-vpc --vpc-id "$VPC" --region "$REGION"
      echo "✅ VPC $VPC eliminada."
    fi
  done
else
  echo "⚠️  No hay VPCs personalizadas."
fi

# 5) Elastic IPs
echo "➡️  Limpieza de Elastic IPs (EIP) ..."
if [[ "$FORCE_EIP" == "false" ]]; then
  # Solo EIPs sin asociar (seguro / Free Tier)
  mapfile -t EIP_FREE < <(aws ec2 describe-addresses --region "$REGION" \
    --query "Addresses[?AssociationId==null].AllocationId" --output text | tr '\t' '\n' | sed '/^$/d')

  if [[ ${#EIP_FREE[@]} -eq 0 ]]; then
    echo "✅ No hay EIPs libres para liberar. Nada que hacer."
  else
    echo "🧹 EIPs sin asociar detectadas (${#EIP_FREE[@]}): ${EIP_FREE[*]}"
    for alloc in "${EIP_FREE[@]}"; do
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "🔎 [DRY-RUN] Liberaría EIP $alloc"
      else
        aws ec2 release-address --region "$REGION" --allocation-id "$alloc"
        echo "✅ Liberada $alloc"
      fi
    done
  fi
else
  # Desasociar y liberar todas (¡cuidado!)
  mapfile -t ALL_ALLOC < <(aws ec2 describe-addresses --region "$REGION" \
    --query "Addresses[].AllocationId" --output text | tr '\t' '\n' | sed '/^$/d')
  mapfile -t ALL_ASSOC < <(aws ec2 describe-addresses --region "$REGION" \
    --query "Addresses[].AssociationId" --output text | tr '\t' '\n')

  if [[ ${#ALL_ALLOC[@]} -eq 0 ]]; then
    echo "✅ No hay EIPs en la región."
  else
    echo "⚠️  FORCE: Desasociando y liberando ${#ALL_ALLOC[@]} EIPs..."
    for idx in "${!ALL_ALLOC[@]}"; do
      alloc="${ALL_ALLOC[$idx]}"
      assoc="${ALL_ASSOC[$idx]}"

      if [[ "$assoc" != "None" && -n "$assoc" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
          echo "🔎 [DRY-RUN] Desasociaría $assoc (AllocationId $alloc)"
        else
          aws ec2 disassociate-address --region "$REGION" --association-id "$assoc" || true
        fi
      fi

      if [[ "$DRY_RUN" == "true" ]]; then
        echo "🔎 [DRY-RUN] Liberaría $alloc"
      else
        aws ec2 release-address --region "$REGION" --allocation-id "$alloc"
        echo "✅ Liberada $alloc"
      fi
    done
  fi
fi

# Fin de la limpieza
echo "=== ✅ LIMPIEZA FINALIZADA ==="
