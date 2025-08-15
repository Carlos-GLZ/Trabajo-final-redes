#!/bin/bash
set -euo pipefail

REGION="us-east-1"

echo "=== 🔥 LIMPIEZA DE AWS Y LLAVES LOCALES ($REGION) ==="

# 1) Instancias EC2 (running/stopped)
echo "➡️ Eliminando instancias EC2..."
EC2_IDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=running,stopped,stopping,pending" \
  --query "Reservations[].Instances[].InstanceId" --output text)
if [[ -n "${EC2_IDS:-}" ]]; then
  aws ec2 terminate-instances --instance-ids $EC2_IDS --region "$REGION" >/dev/null
  aws ec2 wait instance-terminated --instance-ids $EC2_IDS --region "$REGION"
  echo "✅ Instancias eliminadas."
else
  echo "⚠️ No hay instancias activas para eliminar."
fi

# 2) Borrar KeyPairs en AWS (opcional: limita por prefijo)
echo "➡️ Eliminando KeyPairs en AWS..."
KEYS=$(aws ec2 describe-key-pairs --region "$REGION" --query "KeyPairs[].KeyName" --output text)
if [[ -n "${KEYS:-}" ]]; then
  for KEY in $KEYS; do
    # Si quieres solo tus llaves de proyecto, usa: [[ "$KEY" == pitchzone-* ]] || continue
    echo "🗑️  AWS KeyPair: $KEY"
    aws ec2 delete-key-pair --key-name "$KEY" --region "$REGION" || true
  done
else
  echo "⚠️ No hay KeyPairs en AWS."
fi

# 3) Borrar .pem locales (en el directorio actual)
echo "➡️ Eliminando archivos .pem locales en $(pwd)..."
find . -type f -name "*.pem" -print -delete || true
echo "✅ Archivos .pem locales eliminados."

# 4) VPCs NO por defecto (con sus recursos)
echo "➡️ Eliminando VPCs personalizadas..."
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
      aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC" --region "$REGION" || true
      aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$REGION" || true
    done

    # Subnets
    SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
      --filters Name=vpc-id,Values=$VPC --query "Subnets[].SubnetId" --output text)
    for S in $SUBNETS; do
      aws ec2 delete-subnet --subnet-id "$S" --region "$REGION" || true
    done

    # Route tables (no la principal)
    RTBS=$(aws ec2 describe-route-tables --region "$REGION" \
      --filters Name=vpc-id,Values=$VPC --query "RouteTables[].{Id:RouteTableId,Main:Associations[?Main].Main|[0]}" --output text)
    # Salida tipo: "rtb-12345    True" o "rtb-67890    False"
    while read -r RTB MAIN; do
      [[ -z "${RTB:-}" ]] && continue
      [[ "$MAIN" == "True" ]] && continue
      aws ec2 delete-route-table --route-table-id "$RTB" --region "$REGION" || true
    done <<< "$RTBS"

    # Security Groups (no el default)
    SGS=$(aws ec2 describe-security-groups --region "$REGION" \
      --filters Name=vpc-id,Values=$VPC --query "SecurityGroups[].{Id:GroupId,Name:GroupName}" --output text)
    while read -r SGID SGNAME; do
      [[ -z "${SGID:-}" ]] && continue
      [[ "$SGNAME" == "default" ]] && continue
      aws ec2 delete-security-group --group-id "$SGID" --region "$REGION" 2>/dev/null || true
    done <<< "$SGS"

    # Finalmente, la VPC
    aws ec2 delete-vpc --vpc-id "$VPC" --region "$REGION"
    echo "✅ VPC $VPC eliminada."
  done
else
  echo "⚠️ No hay VPCs personalizadas."
fi

# Fin de la limpieza
echo "=== 🔥 LIMPIEZA FINALIZADA ==="