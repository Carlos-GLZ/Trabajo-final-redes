#!/bin/bash
# ============================================================
# create-infraestructura.sh
# Crea VPC mínima, Subnet pública, IGW, RT, SG (HTTP/SSH),
# EC2 Amazon Linux 2023 (t2.micro), asigna Elastic IP, crea S3.
# Escribe infraestructura-info.txt con todos los datos.
# Región por defecto: us-east-1 (Free Tier friendly).
# ============================================================

set -Eeuo pipefail
AWS_PAGER=""

# ====== Config ======
PROJECT_NAME="pitchzone"
REGION="${REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"
KEY_NAME="${PROJECT_NAME}-keypair-$(date +%s)"
TAG_STACK="${PROJECT_NAME}-stack"
PROFILE_OPT=${AWS_PROFILE:+--profile "$AWS_PROFILE"}

# ====== Helpers ======
blue(){ echo -e "\033[34m[STEP]\033[0m $*"; }
green(){ echo -e "\033[32m[SUCCESS]\033[0m $*"; }
yellow(){ echo -e "\033[33m[WARN]\033[0m $*"; }
red(){ echo -e "\033[31m[ERROR]\033[0m $*"; }

trap 'red "Falló en la línea $LINENO"; exit 1' ERR

# ====== 0) Descubrir IP pública local para SSH (22) ======
MYIP=$(curl -s https://checkip.amazonaws.com || true)
if [[ -z "${MYIP}" ]]; then
  yellow "No pude obtener tu IP; abriré SSH (22) a 0.0.0.0/0 (ajústalo luego)."
  SSH_CIDR="0.0.0.0/0"
else
  SSH_CIDR="${MYIP}/32"
fi

# ====== 1) AMI Amazon Linux 2023 (vía SSM) ======
blue "Obteniendo AMI AL2023 por SSM..."
AMI_ID=$(aws ssm get-parameters $PROFILE_OPT --region "$REGION" \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 \
  --query 'Parameters[0].Value' --output text)
green "AMI_ID: $AMI_ID"

# ====== 2) VPC mínima ======
blue "Creando VPC..."
VPC_ID=$(aws ec2 create-vpc $PROFILE_OPT --region "$REGION" --cidr-block 10.0.0.0/16 \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute $PROFILE_OPT --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames
aws ec2 create-tags $PROFILE_OPT --region "$REGION" --resources "$VPC_ID" --tags Key=Name,Value="$TAG_STACK"
green "VPC_ID: $VPC_ID"

# ====== 3) Subnet pública ======
blue "Creando Subnet pública..."
SUBNET_ID=$(aws ec2 create-subnet $PROFILE_OPT --region "$REGION" \
  --vpc-id "$VPC_ID" --cidr-block 10.0.1.0/24 --availability-zone "${REGION}a" \
  --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute $PROFILE_OPT --region "$REGION" --subnet-id "$SUBNET_ID" --map-public-ip-on-launch
aws ec2 create-tags $PROFILE_OPT --region "$REGION" --resources "$SUBNET_ID" --tags Key=Name,Value="$TAG_STACK-public"
green "SUBNET_ID: $SUBNET_ID"

# ====== 4) IGW + Route Table ======
blue "Creando Internet Gateway y rutas..."
IGW_ID=$(aws ec2 create-internet-gateway $PROFILE_OPT --region "$REGION" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway $PROFILE_OPT --region "$REGION" --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"
RT_ID=$(aws ec2 create-route-table $PROFILE_OPT --region "$REGION" --vpc-id "$VPC_ID" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route $PROFILE_OPT --region "$REGION" --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
aws ec2 associate-route-table $PROFILE_OPT --region "$REGION" --route-table-id "$RT_ID" --subnet-id "$SUBNET_ID" >/dev/null
green "IGW_ID: $IGW_ID  RT_ID: $RT_ID"

# ====== 5) Security Group (HTTP/SSH) ======
blue "Creando Security Group (HTTP 80, SSH 22)..."
SG_ID=$(aws ec2 create-security-group $PROFILE_OPT --region "$REGION" \
  --group-name "${PROJECT_NAME}-sg-$(date +%s)" --description "HTTP+SSH for ${PROJECT_NAME}" \
  --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress $PROFILE_OPT --region "$REGION" --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=\"HTTP\"}]" >/dev/null
aws ec2 authorize-security-group-ingress $PROFILE_OPT --region "$REGION" --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${SSH_CIDR},Description=\"SSH\"}]" >/dev/null
# IPv6 opcional para HTTP:
aws ec2 authorize-security-group-ingress $PROFILE_OPT --region "$REGION" --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,Ipv6Ranges=[{CidrIpv6=::/0,Description=\"HTTPv6\"}]" >/dev/null || true
green "SG_ID: $SG_ID (SSH desde ${SSH_CIDR})"

# ====== 6) Key Pair ======
blue "Creando Key Pair..."
KEY_PEM="${PROJECT_NAME}-$(date +%s).pem"
aws ec2 create-key-pair $PROFILE_OPT --region "$REGION" --key-name "$KEY_NAME" \
  --query 'KeyMaterial' --output text > "$KEY_PEM"
chmod 400 "$KEY_PEM"
green "KEY_NAME: $KEY_NAME  PEM: $KEY_PEM"

# ====== 7) EC2 Instance ======
blue "Lanzando instancia EC2 ${INSTANCE_TYPE} en ${REGION}..."
EC2_ID=$(aws ec2 run-instances $PROFILE_OPT --region "$REGION" \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
  --network-interfaces "DeviceIndex=0,SubnetId=${SUBNET_ID},Groups=${SG_ID},AssociatePublicIpAddress=true" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-ec2}]" \
  --query 'Instances[0].InstanceId' --output text)
green "EC2_ID: $EC2_ID"

blue "Esperando a que la instancia esté 'running'..."
aws ec2 wait instance-running $PROFILE_OPT --region "$REGION" --instance-ids "$EC2_ID"
green "Instancia en estado running."

# ====== 7.1) Elastic IP ======
blue "Asignando Elastic IP..."
EIP_ALLOC_ID=$(aws ec2 allocate-address $PROFILE_OPT --region "$REGION" --domain vpc --query AllocationId --output text)
EIP_ASSOC_ID=$(aws ec2 associate-address $PROFILE_OPT --region "$REGION" --instance-id "$EC2_ID" --allocation-id "$EIP_ALLOC_ID" --query AssociationId --output text)
PUBLIC_IP=$(aws ec2 describe-addresses $PROFILE_OPT --region "$REGION" --allocation-ids "$EIP_ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)
green "Elastic IP: $PUBLIC_IP"

# ====== 8) S3 Bucket (estáticos/logs) ======
blue "Creando bucket S3..."
UNIQ=$(date +%Y%m%d%H%M%S)$RANDOM
S3_BUCKET="${PROJECT_NAME}-assets-${UNIQ}"
if [[ "$REGION" == "us-east-1" ]]; then
  aws s3api create-bucket $PROFILE_OPT --region "$REGION" --bucket "$S3_BUCKET" >/dev/null
else
  aws s3api create-bucket $PROFILE_OPT --region "$REGION" --bucket "$S3_BUCKET" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
fi
aws s3api put-public-access-block $PROFILE_OPT --region "$REGION" --bucket "$S3_BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null
echo "hola" > hello.txt
aws s3 cp $PROFILE_OPT --region "$REGION" hello.txt "s3://${S3_BUCKET}/hello.txt" >/dev/null
rm -f hello.txt
green "S3_BUCKET: $S3_BUCKET (Public Access Block habilitado)"

# ====== 9) Guardar datos en infraestructura-info.txt ======
cat > infraestructura-info.txt <<EOT
# ====== Infraestructura ${PROJECT_NAME} ======
PROJECT_NAME=$PROJECT_NAME
REGION=$REGION
KEY_NAME=$KEY_NAME
KEY_PEM=$KEY_PEM
VPC_ID=$VPC_ID
SUBNET_ID=$SUBNET_ID
IGW_ID=$IGW_ID
RT_ID=$RT_ID
SG_ID=$SG_ID
EC2_ID=$EC2_ID
PUBLIC_IP=$PUBLIC_IP
EIP_ALLOCATION_ID=$EIP_ALLOC_ID
EIP_ASSOCIATION_ID=$EIP_ASSOC_ID
S3_BUCKET=$S3_BUCKET
EOT

green "Listo ✅
- EC2:        $EC2_ID
- Elastic IP: $PUBLIC_IP
- SG:         $SG_ID
- S3:         $S3_BUCKET
- PEM:        $KEY_PEM

Archivo: infraestructura-info.txt generado."

