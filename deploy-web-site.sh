#!/bin/bash
set -euo pipefail

# =============================== #
#  PitchZone - deploy-web-site.sh #
#   WEB + BACKEND (CFN) + AUTH    #
# =============================== #

# --- 0) Infra info ---
if [ ! -f "infraestructura-info.txt" ]; then
  echo "❌ No se encontró infraestructura-info.txt"
  echo "📝 Ejecuta primero create-infraestructura.sh"
  exit 1
fi
# shellcheck disable=SC1091
source infraestructura-info.txt

: "${PUBLIC_IP:?PUBLIC_IP faltante en infraestructura-info.txt}"
: "${KEY_PEM:?KEY_PEM faltante en infraestructura-info.txt}"

EC2_USER="${EC2_USER:-ec2-user}"
REMOTE="$EC2_USER@$PUBLIC_IP"

echo "🚀 Iniciando despliegue de PitchZone en $PUBLIC_IP ..."

# --- 1) Archivos locales opcionales ---
LOGO_FILE="logo_pitchzone.png"
DB_FILE="proyectos.json"
UNI_FILE="universidades.json"
EVENTS_FILE="eventos.json"
INDEX_FILE="index.html"                       # puede ser full HTML o solo overrides <script>…
UE_JSON_FILE="${UE_JSON_FILE:-alianzas.json}" # JSON unificado (nombre final: /assets/alianzas.json)

upload_if_exists () {
  local f="$1"
  local dst="/tmp/"
  if [ -f "$f" ]; then
    echo "⬆️  Subiendo $f ..."
    scp -i "$KEY_PEM" -o StrictHostKeyChecking=no "$f" "$REMOTE":"$dst"
  else
    echo "ℹ️  No se encontró $f (se usará seed/demo)."
  fi
}

upload_if_exists "$LOGO_FILE"
upload_if_exists "$DB_FILE"
upload_if_exists "$UNI_FILE"
upload_if_exists "$EVENTS_FILE"
upload_if_exists "$INDEX_FILE"
upload_if_exists "$UE_JSON_FILE"

# --- 2) Plantilla CFN del backend (API + Lambdas + Dynamo) ---
CFN_FILE="pitchzone-backend.yml"
cat > "$CFN_FILE" <<'YML'
AWSTemplateFormatVersion: '2010-09-09'
Description: PitchZone backend - API Gateway + Lambda + DynamoDB (POST/GET projects)

Parameters:
  TableName:
    Type: String
    Default: pitchzone-projects
  StageName:
    Type: String
    Default: prod
  CorsAllowOrigin:
    Type: String
    Default: "*"

Resources:
  ProjectsTable:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: !Ref TableName
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: id
          AttributeType: S
        - AttributeName: createdAt
          AttributeType: S
      KeySchema:
        - AttributeName: id
          KeyType: HASH
      GlobalSecondaryIndexes:
        - IndexName: createdAtIndex
          KeySchema:
            - AttributeName: createdAt
              KeyType: HASH
          Projection:
            ProjectionType: ALL

  LambdaRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: { Service: lambda.amazonaws.com }
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
      Policies:
        - PolicyName: DynamoWriteRead
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Action:
                  - dynamodb:PutItem
                  - dynamodb:Scan
                Resource:
                  - !GetAtt ProjectsTable.Arn
                  - !Sub "${ProjectsTable.Arn}/index/*"

  PostProjectLambda:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: !Sub pitchzone-post-project-${AWS::StackName}
      Runtime: nodejs18.x
      Handler: index.handler
      Role: !GetAtt LambdaRole.Arn
      Timeout: 10
      Environment:
        Variables:
          TABLE_NAME: !Ref TableName
          CORS_ORIGIN: !Ref CorsAllowOrigin
      Code:
        ZipFile: |
          const AWS = require('aws-sdk');
          const ddb = new AWS.DynamoDB.DocumentClient();
          const crypto = require('crypto');
          const TABLE = process.env.TABLE_NAME;

          exports.handler = async (event) => {
            try {
              const method = (event?.requestContext?.http?.method || event.httpMethod || '').toUpperCase();
              if (method === 'OPTIONS') return cors(200, { ok: true });

              const body = event.body ? JSON.parse(event.body) : {};
              const req = ["nombre_proyecto","descripcion","integrantes","funding_necesario","categoria"];
              for (const k of req) {
                if (body[k] === undefined || body[k] === null || String(body[k]).trim() === "") {
                  return cors(400, { ok:false, error:`Falta campo: ${k}` });
                }
              }
              if (!Array.isArray(body.integrantes)) {
                return cors(400, { ok:false, error:"'integrantes' debe ser array" });
              }

              const id = crypto.randomUUID();
              const now = new Date().toISOString();

              const item = {
                id,
                nombre_proyecto: String(body.nombre_proyecto),
                descripcion: String(body.descripcion),
                integrantes: body.integrantes,
                funding_necesario: Number(body.funding_necesario),
                categoria: String(body.categoria),
                createdAt: now
              };

              await ddb.put({ TableName: TABLE, Item: item }).promise();
              return cors(201, { ok:true, id, createdAt: now });
            } catch (err) {
              console.error(err);
              return cors(500, { ok:false, error:"Error interno" });
            }
          };

          function cors(statusCode, body){
            return {
              statusCode,
              headers: {
                "Content-Type":"application/json",
                "Access-Control-Allow-Origin": process.env.CORS_ORIGIN || "*",
                "Access-Control-Allow-Headers":"*",
                "Access-Control-Allow-Methods":"OPTIONS,POST,GET"
              },
              body: JSON.stringify(body)
            };
          }

  GetProjectsLambda:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: !Sub pitchzone-get-projects-${AWS::StackName}
      Runtime: nodejs18.x
      Handler: index.handler
      Role: !GetAtt LambdaRole.Arn
      Timeout: 10
      Environment:
        Variables:
          TABLE_NAME: !Ref TableName
          CORS_ORIGIN: !Ref CorsAllowOrigin
      Code:
        ZipFile: |
          const AWS = require('aws-sdk');
          const ddb = new AWS.DynamoDB.DocumentClient();
          const TABLE = process.env.TABLE_NAME;

          exports.handler = async (event) => {
            try {
              const method = (event?.requestContext?.http?.method || event.httpMethod || '').toUpperCase();
              if (method === 'OPTIONS') return cors(200, { ok: true });

              const scan = await ddb.scan({ TableName: TABLE }).promise();
              const items = scan.Items || [];
              items.sort((a,b) => String(b.createdAt||'').localeCompare(String(a.createdAt||'')));
              return cors(200, items);
            } catch (err) {
              console.error(err);
              return cors(500, { ok:false, error:"Error interno" });
            }
          };

          function cors(statusCode, body){
            return {
              statusCode,
              headers: {
                "Content-Type":"application/json",
                "Access-Control-Allow-Origin": process.env.CORS_ORIGIN || "*",
                "Access-Control-Allow-Headers":"*",
                "Access-Control-Allow-Methods":"OPTIONS,POST,GET"
              },
              body: JSON.stringify(body)
            };
          }

  HttpApi:
    Type: AWS::ApiGatewayV2::Api
    Properties:
      Name: !Sub pitchzone-api-${AWS::StackName}
      ProtocolType: HTTP
      CorsConfiguration:
        AllowMethods: [ "OPTIONS", "GET", "POST" ]
        AllowOrigins: [ !Ref CorsAllowOrigin ]
        AllowHeaders: [ "*" ]

  PostProjectsIntegration:
    Type: AWS::ApiGatewayV2::Integration
    Properties:
      ApiId: !Ref HttpApi
      IntegrationType: AWS_PROXY
      IntegrationUri: !Sub arn:aws:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${PostProjectLambda.Arn}/invocations
      PayloadFormatVersion: "2.0"

  GetProjectsIntegration:
    Type: AWS::ApiGatewayV2::Integration
    Properties:
      ApiId: !Ref HttpApi
      IntegrationType: AWS_PROXY
      IntegrationUri: !Sub arn:aws:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${GetProjectsLambda.Arn}/invocations
      PayloadFormatVersion: "2.0"

  PostProjectsRoute:
    Type: AWS::ApiGatewayV2::Route
    Properties:
      ApiId: !Ref HttpApi
      RouteKey: "POST /projects"
      Target: !Sub "integrations/${PostProjectsIntegration}"

  GetProjectsRoute:
    Type: AWS::ApiGatewayV2::Route
    Properties:
      ApiId: !Ref HttpApi
      RouteKey: "GET /projects"
      Target: !Sub "integrations/${GetProjectsIntegration}"

  ApiStage:
    Type: AWS::ApiGatewayV2::Stage
    Properties:
      ApiId: !Ref HttpApi
      StageName: !Ref StageName
      AutoDeploy: true

  AllowInvokePost:
    Type: AWS::Lambda::Permission
    Properties:
      Action: lambda:InvokeFunction
      FunctionName: !GetAtt PostProjectLambda.Arn
      Principal: apigateway.amazonaws.com
      SourceArn: !Sub arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${HttpApi}/*/POST/projects

  AllowInvokeGet:
    Type: AWS::Lambda::Permission
    Properties:
      Action: lambda:InvokeFunction
      FunctionName: !GetAtt GetProjectsLambda.Arn
      Principal: apigateway.amazonaws.com
      SourceArn: !Sub arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${HttpApi}/*/GET/projects

Outputs:
  ApiBaseUrl:
    Description: Base URL de la API
    Value: !Sub https://${HttpApi}.execute-api.${AWS::Region}.amazonaws.com/${StageName}
  PostProjectsEndpoint:
    Description: Endpoint POST para crear proyectos
    Value: !Sub https://${HttpApi}.execute-api.${AWS::Region}.amazonaws.com/${StageName}/projects
  GetProjectsEndpoint:
    Description: Endpoint GET para listar proyectos
    Value: !Sub https://${HttpApi}.execute-api.${AWS::Region}.amazonaws.com/${StageName}/projects
  DynamoTableName:
    Description: Nombre de la tabla DynamoDB
    Value: !Ref TableName
YML

# --- 3) Desplegar/actualizar backend ---
STACK_NAME="pitchzone-backend"
TABLE_NAME="pitchzone-projects"
STAGE_NAME="prod"
CORS_ORIGIN="*"

echo "📡 Desplegando backend (CloudFormation) ..."
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$CFN_FILE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides TableName="$TABLE_NAME" StageName="$STAGE_NAME" CorsAllowOrigin="$CORS_ORIGIN"

API_BASE="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiBaseUrl'].OutputValue" --output text)"

if [ -z "$API_BASE" ] || [ "$API_BASE" = "None" ]; then
  echo "❌ No pude obtener ApiBaseUrl del stack"
  exit 1
fi
echo "🌐 API_BASE: $API_BASE"

# --- 3.1) AUTH: Cognito (UserPool + Client) y Authorizer JWT ---
CFN_AUTH="pitchzone-auth.yml"

# Deducir API_ID y REGION desde API_BASE (robusto + sin supuestos de config local)
API_HOST="${API_BASE#https://}"; API_HOST="${API_HOST%%/*}"
API_ID="${API_HOST%%.*}"                                          # ej. 0d54r1dg36
AWS_REGION_FROM_URL="$(echo "$API_BASE" | sed -n 's#https\?://[^.]*\.execute-api\.\([^.]*\)\.amazonaws\.com/.*#\1#p')"
AWS_REGION="${AWS_REGION_FROM_URL:-$(aws configure get region || echo us-east-1)}"

cat > "$CFN_AUTH" <<'YML'
AWSTemplateFormatVersion: '2010-09-09'
Description: PitchZone Auth - Cognito + Authorizer para API

Parameters:
  ApiId:
    Type: String
  StageName:
    Type: String
    Default: prod

Resources:
  UserPool:
    Type: AWS::Cognito::UserPool
    Properties:
      UserPoolName: pitchzone-users
      UsernameAttributes: [email]
      AutoVerifiedAttributes: [email]
      Policies:
        PasswordPolicy:
          MinimumLength: 8
          RequireLowercase: true
          RequireNumbers: true
          RequireSymbols: false
          RequireUppercase: true
      VerificationMessageTemplate:
        DefaultEmailOption: CONFIRM_WITH_CODE

  UserPoolClient:
    Type: AWS::Cognito::UserPoolClient
    Properties:
      UserPoolId: !Ref UserPool
      ClientName: web-client
      GenerateSecret: false
      ExplicitAuthFlows:
        - ALLOW_USER_PASSWORD_AUTH
        - ALLOW_REFRESH_TOKEN_AUTH
        - ALLOW_USER_SRP_AUTH

  JwtAuthorizer:
    Type: AWS::ApiGatewayV2::Authorizer
    Properties:
      ApiId: !Ref ApiId
      AuthorizerType: JWT
      Name: cognito-jwt
      IdentitySource:
        - "$request.header.Authorization"
      JwtConfiguration:
        Audience: [ !Ref UserPoolClient ]
        Issuer: !Sub "https://cognito-idp.${AWS::Region}.amazonaws.com/${UserPool}"

Outputs:
  UserPoolId:       { Value: !Ref UserPool }
  UserPoolClientId: { Value: !Ref UserPoolClient }
  AuthorizerId:     { Value: !Ref JwtAuthorizer }
  Region:           { Value: !Ref AWS::Region }
YML

echo "🔐 Desplegando auth (Cognito)..."
aws cloudformation deploy \
  --stack-name pitchzone-auth \
  --template-file "$CFN_AUTH" \
  --parameter-overrides ApiId="$API_ID" StageName="$STAGE_NAME"

USER_POOL_ID="$(aws cloudformation describe-stacks --stack-name pitchzone-auth \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)"
APP_CLIENT_ID="$(aws cloudformation describe-stacks --stack-name pitchzone-auth \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text)"
AUTHORIZER_ID="$(aws cloudformation describe-stacks --stack-name pitchzone-auth \
  --query "Stacks[0].Outputs[?OutputKey=='AuthorizerId'].OutputValue" --output text)"

echo "🆔 Cognito: pool=$USER_POOL_ID client=$APP_CLIENT_ID region=$AWS_REGION"

# Proteger POST /projects con JWT
ROUTE_ID_POST="$(aws apigatewayv2 get-routes --api-id "$API_ID" \
  --query "Items[?RouteKey=='POST /projects'].RouteId" --output text || true)"
if [ -n "${ROUTE_ID_POST:-}" ] && [ "$ROUTE_ID_POST" != "None" ]; then
  aws apigatewayv2 update-route --api-id "$API_ID" --route-id "$ROUTE_ID_POST" \
    --authorization-type JWT --authorizer-id "$AUTHORIZER_ID" >/dev/null
  echo "✅ Protegido POST /projects con JWT Authorizer"
else
  echo "⚠️  No pude obtener RouteId del POST /projects (¿se creó correctamente la API?)."
fi

# --- 4) Script remoto: HTML + assets ---
cat > deploy-pitchzone-remote.sh <<'RSCRIPT'
#!/bin/bash
set -euo pipefail

echo "🔧 Configurando Apache..."
sudo yum -y install httpd || true
sudo systemctl enable --now httpd

# Conf básica
sudo bash -c 'cat > /etc/httpd/conf.d/pitchzone.conf' <<APACHEEOF
ServerTokens Prod
ServerSignature Off
<IfModule mod_headers.c>
  Header always set X-Frame-Options DENY
  Header always set X-Content-Type-Options nosniff
  Header always set Referrer-Policy "strict-origin-when-cross-origin"
</IfModule>
APACHEEOF
sudo systemctl restart httpd || true

# Docroot y assets
sudo mkdir -p /var/www/html/assets

# Mover assets si llegaron
[ -f /tmp/logo_pitchzone.png ] && sudo mv /tmp/logo_pitchzone.png /var/www/html/logo_pitchzone.png && sudo chown apache:apache /var/www/html/logo_pitchzone.png && sudo chmod 644 /var/www/html/logo_pitchzone.png
[ -f /tmp/proyectos.json ] && sudo mv /tmp/proyectos.json /var/www/html/proyectos.json && sudo chown apache:apache /var/www/html/proyectos.json && sudo chmod 644 /var/www/html/proyectos.json
[ -f /tmp/universidades.json ] && sudo mv /tmp/universidades.json /var/www/html/universidades.json && sudo chown apache:apache /var/www/html/universidades.json && sudo chmod 644 /var/www/html/universidades.json
[ -f /tmp/eventos.json ] && sudo mv /tmp/eventos.json /var/www/html/eventos.json && sudo chown apache:apache /var/www/html/eventos.json && sudo chmod 644 /var/www/html/eventos.json

# JSON unificado → /assets/alianzas.json (acepta ambos nombres)
if [ -f /tmp/alianzas.json ]; then
  SRC="/tmp/alianzas.json"
elif [ -f /tmp/universidades-empresas.json ]; then
  SRC="/tmp/universidades-empresas.json"
else
  SRC=""
fi

if [ -n "${SRC}" ]; then
  sudo mv "${SRC}" /var/www/html/assets/alianzas.json
  sudo chown apache:apache /var/www/html/assets/alianzas.json
  sudo chmod 644 /var/www/html/assets/alianzas.json
  # alias de compatibilidad
  sudo ln -sf /var/www/html/assets/alianzas.json /var/www/html/assets/universidades-empresas.json
fi

# === HTML ===
USE_SNIPPET_ONLY=0
if [ -f /tmp/index.html ]; then
  if ! grep -qi "<html" /tmp/index.html; then
    USE_SNIPPET_ONLY=1
  fi
fi

if [ -f /tmp/index.html ] && [ "${USE_SNIPPET_ONLY}" -eq 0 ]; then
  echo "📄 Usando index.html subido por el usuario"
  sudo mv /tmp/index.html /var/www/html/index.html
  sudo chown apache:apache /var/www/html/index.html
  sudo chmod 644 /var/www/html/index.html
else
  echo "🎨 Generando index.html (fallback) ..."
  sudo bash -c 'cat > /var/www/html/index.html' <<'HTMLEOF'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PitchZone - Súbelo. Preséntalo. Véndelo.</title>
<link href="https://fonts.googleapis.com/css2?family=Montserrat:wght@400;600;700;800&display=swap" rel="stylesheet">
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css" rel="stylesheet">
<script src="https://unpkg.com/amazon-cognito-identity-js@6.3.9/dist/amazon-cognito-identity.min.js"></script>
<style>
/* estilos base del fallback (omitidos por brevedad) */
body{font-family:Montserrat,Arial,sans-serif}
</style>
</head>
<body>
<h1>PitchZone</h1>
<script>
const API_BASE="%%API_BASE%%";
const COGNITO={region:'%%COGNITO_REGION%%',userPoolId:'%%COGNITO_USER_POOL_ID%%',clientId:'%%COGNITO_APP_CLIENT_ID%%'};
</script>
</body>
</html>
HTMLEOF
fi

# Si subiste solo un snippet JS, lo anexamos envuelto en <script>
if [ -f /tmp/index.html ] && [ "${USE_SNIPPET_ONLY}" -eq 1 ]; then
  echo "➕ Anexando snippet de index.html (envuelto en <script>)"
  sudo bash -c 'printf "\n<script>\n" >> /var/www/html/index.html'
  sudo bash -c 'cat /tmp/index.html >> /var/www/html/index.html'
  sudo bash -c 'printf "\n</script>\n" >> /var/www/html/index.html'
fi

sudo chown -R apache:apache /var/www/html/
sudo chmod -R 755 /var/www/html/
sudo systemctl restart httpd
echo "✅ Sitio desplegado (sin inyectar JSON en el HTML)."
RSCRIPT

chmod +x deploy-pitchzone-remote.sh

# --- 5) Esperar SSH real, subir script remoto y ejecutarlo ---
echo "⏳ Esperando a que la instancia esté lista (SSH)..."
for i in {1..30}; do
  if ssh -i "$KEY_PEM" -o StrictHostKeyChecking=no -o ConnectTimeout=2 "$REMOTE" "echo ok" >/dev/null 2>&1; then
    echo "✅ SSH disponible."
    break
  fi
  sleep 3
done

echo "📤 Subiendo script remoto..."
scp -i "$KEY_PEM" -o StrictHostKeyChecking=no deploy-pitchzone-remote.sh "$REMOTE":/tmp/

echo "🖥️  Ejecutando script remoto..."
ssh -i "$KEY_PEM" -o StrictHostKeyChecking=no "$REMOTE" "chmod +x /tmp/deploy-pitchzone-remote.sh && sudo /tmp/deploy-pitchzone-remote.sh"

# --- 6) Sustituir variables en el HTML (en la EC2) ---
echo "✏️ Inyectando variables (API_BASE + Cognito) en index.html remoto ..."
ssh -i "$KEY_PEM" -o StrictHostKeyChecking=no "$REMOTE" "\
  sudo sed -i \
  -e \"s|%%API_BASE%%|$API_BASE|g\" \
  -e \"s|%%COGNITO_REGION%%|$AWS_REGION|g\" \
  -e \"s|%%COGNITO_USER_POOL_ID%%|$USER_POOL_ID|g\" \
  -e \"s|%%COGNITO_APP_CLIENT_ID%%|$APP_CLIENT_ID|g\" \
  /var/www/html/index.html && sudo systemctl restart httpd"

# --- 7) Verificación de alianzas.json ---
echo "🔎 Verificando alianzas.json por HTTP ..."
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://$PUBLIC_IP/assets/alianzas.json?v=$(date +%s)")"
if [ "$HTTP_CODE" = "200" ]; then
  echo "✅ Disponible: http://$PUBLIC_IP/assets/alianzas.json"
  curl -s "http://$PUBLIC_IP/assets/alianzas.json?v=$(date +%s)" | head -n 10
else
  echo "❌ No se pudo verificar /assets/alianzas.json (HTTP $HTTP_CODE). Revisa ruta y permisos."
fi

# --- 8) Limpieza local ---
rm -f deploy-pitchzone-remote.sh

echo ""
echo "🎉 ¡PITCHZONE desplegado con BACKEND + AUTH + JSON unificado!"
echo "🌐 Web:   http://$PUBLIC_IP"
echo "🛠️  API:  $API_BASE"
echo "   • POST $API_BASE/projects   (protegido con JWT)"
echo "   • GET  $API_BASE/projects"
echo "🔐 Cognito"
echo "   • Pool: $USER_POOL_ID"
echo "   • App Client: $APP_CLIENT_ID"
echo "📦 JSON:  http://$PUBLIC_IP/assets/alianzas.json"
echo ""
echo "Sugerencia front-end: fetch('/assets/alianzas.json?v=' + Date.now())"
echo ""

#codigo con login