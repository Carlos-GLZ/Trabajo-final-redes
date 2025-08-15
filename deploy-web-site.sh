#!/bin/bash
set -euo pipefail

# =============================== #
#  PitchZone - deploy-web-site.sh #
#      WEB + BACKEND (CFN)        #
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

# --- 2) Plantilla CFN del backend (corregida) ---
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

# --- 4) Script remoto: HTML + assets (SIN inyectar JSON en HTML) ---
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
  # alias de compatibilidad (si quedara alguna referencia antigua)
  sudo ln -sf /var/www/html/assets/alianzas.json /var/www/html/assets/universidades-empresas.json
fi

# === HTML ===
USE_SNIPPET_ONLY=0
if [ -f /tmp/index.html ]; then
  # Si el archivo subido NO contiene <html>, lo trataremos como snippet para anexar
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
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
<style>
:root{--primary-orange:#FB9833;--primary-light:#FCEFEF;--primary-teal:#1B768E;--primary-dark:#012538;--primary-gray:#4D555B;--success-green:#10B981;--warning-yellow:#F59E0B}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:"Montserrat",Arial,sans-serif;background:linear-gradient(135deg,var(--primary-dark),var(--primary-teal));color:var(--primary-light);min-height:100vh;overflow-x:hidden}
header{background:rgba(1,37,56,.95);backdrop-filter:blur(10px);padding:15px 40px;display:flex;align-items:center;justify-content:space-between;border-bottom:2px solid var(--primary-teal);position:sticky;top:0;z-index:100;transition:.3s}
.logo-zone{display:flex;align-items:center;gap:15px;cursor:pointer;transition:.3s}
.logo-zone img{height:45px;border-radius:12px;box-shadow:0 0 20px rgba(251,152,51,.5)}
.logo-zone span{font-weight:800;font-size:1.8em;letter-spacing:2px;background:linear-gradient(45deg,var(--primary-orange),var(--primary-teal));-webkit-background-clip:text;-webkit-text-fill-color:transparent}
nav{display:flex;gap:22px}
nav a{color:var(--primary-light);text-decoration:none;font-weight:600;letter-spacing:1px;padding:8px 14px;border-radius:18px;transition:.2s}
nav a:hover{color:var(--primary-orange);background:rgba(251,152,51,.12)}
.hero{display:flex;flex-direction:column;align-items:center;padding:80px 20px 60px;text-align:center}
.hero-logo{width:120px;height:120px;border-radius:25px;box-shadow:0 10px 40px rgba(251,152,51,.4);margin-bottom:30px}
.hero h1{font-size:3.6em;font-weight:800;margin-bottom:10px;background:linear-gradient(45deg,var(--primary-orange),#fff);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.hero p{font-size:1.2em;color:var(--primary-orange);font-weight:600;margin-bottom:30px}
.hero-buttons{display:flex;gap:14px;flex-wrap:wrap;justify-content:center;margin-bottom:20px}
.hero-btn{background:linear-gradient(45deg,var(--primary-orange),#FF6B35);color:var(--primary-dark);font-weight:800;border:none;padding:14px 26px;border-radius:26px;cursor:pointer;box-shadow:0 8px 25px rgba(251,152,51,.35)}
.hero-btn.secondary{background:transparent;color:#fff;border:2px solid var(--primary-orange)}
.stats{display:flex;justify-content:center;gap:30px;margin:30px 0;flex-wrap:wrap}
.stat-item{text-align:center;background:rgba(255,255,255,.08);padding:14px 16px;border-radius:12px;border:1px solid rgba(251,152,51,.3)}
.stat-number{font-size:2em;font-weight:800;color:var(--primary-orange)}
.main-content{background:var(--primary-light);color:var(--primary-dark);padding:60px 0;margin-top:40px;border-radius:38px 38px 0 0;box-shadow:0 -10px 40px rgba(1,37,56,.3)}
.container{max-width:1200px;margin:0 auto;padding:0 20px}
.section-title{text-align:center;font-size:2.4em;margin-bottom:34px;font-weight:800;color:var(--primary-dark);position:relative}
.section-title:after{content:"";position:absolute;bottom:-12px;left:50%;transform:translateX(-50%);width:90px;height:4px;background:linear-gradient(45deg,var(--primary-orange),var(--primary-teal));border-radius:2px}
.projects-section{margin:60px 0}
.projects-controls{display:flex;justify-content:center;gap:12px;margin-bottom:22px;flex-wrap:wrap}
.filter-btn{background:transparent;border:2px solid var(--primary-teal);color:var(--primary-teal);padding:8px 16px;border-radius:22px;cursor:pointer;font-weight:600}
.filter-btn.active,.filter-btn:hover{background:var(--primary-teal);color:#fff}
.projects-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:22px}
.project-card{background:#fff;border-radius:18px;padding:22px;border:2px solid transparent;box-shadow:0 8px 22px rgba(0,0,0,.08);transition:.2s}
.project-card:hover{transform:translateY(-6px);border-color:var(--primary-orange)}
.project-header{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:12px}
.project-title{font-size:1.25em;font-weight:800;color:var(--primary-dark)}
.project-funding{background:linear-gradient(45deg,var(--success-green),#06B6D4);color:#fff;padding:6px 12px;border-radius:16px;font-weight:700;font-size:.85em}
.project-description{color:var(--primary-gray);line-height:1.55;margin-bottom:10px}
.team-label{font-weight:700;color:var(--primary-teal);margin-bottom:6px;display:block}
.team-members{display:flex;flex-wrap:wrap;gap:6px}
.team-member{background:var(--primary-light);color:var(--primary-dark);padding:4px 10px;border-radius:14px;font-size:.85em}
.vote-btn{background:var(--primary-orange);color:#fff;border:none;padding:10px 16px;border-radius:20px;cursor:pointer;font-weight:700}
.vote-count{font-weight:800;color:var(--primary-teal)}
footer{background:linear-gradient(135deg,var(--primary-dark),#0F172A);color:#fff;text-align:center;padding:48px 20px;margin-top:60px;border-top:3px solid var(--primary-teal)}
.footer-links{display:flex;justify-content:center;gap:24px;margin:18px 0;flex-wrap:wrap}
.badge{display:inline-block;background:var(--success-green);color:#fff;padding:6px 10px;border-radius:14px;font-weight:800;font-size:.8em;margin-left:8px}

/* Pill badge eventos */
.pill-badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:.75em;font-weight:800;background:var(--success-green);color:#fff;margin-left:8px;box-shadow:0 2px 10px rgba(16,185,129,.35);vertical-align:middle}
.pill-badge.warn{background:#F59E0B;box-shadow:0 2px 10px rgba(245,158,11,.35)}

/* 🚀 Rocket */
.rocket-fx{position:fixed;left:-80px;top:60%;transform:translate(-50%,-50%) rotate(-20deg);font-size:64px;line-height:1;z-index:9999;filter:drop-shadow(0 8px 16px rgba(0,0,0,.35));pointer-events:none;animation:rocketFly 1.6s ease-in forwards}
@keyframes rocketFly{0%{transform:translate(-50%,-50%) rotate(-20deg)}40%{transform:translate(40vw,-55vh) rotate(-10deg)}70%{transform:translate(70vw,-25vh) rotate(0deg)}100%{transform:translate(110vw,-80vh) rotate(8deg)}}
.rocket-fx::after{content:"🔥";position:absolute;right:-14px;top:26px;font-size:28px;filter:blur(.4px);animation:flame .2s infinite alternate}
@keyframes flame{from{transform:translateY(0) scale(1);opacity:.9}to{transform:translateY(3px) scale(.9);opacity:.6}}

@media(max-width:768px){header{padding:14px 16px;flex-direction:column;gap:10px}}
</style>
</head>
<body>
<header>
  <div class="logo-zone" onclick="window.scrollTo({top:0,behavior:'smooth'})">
    <img src="logo_pitchzone.png" alt="PitchZone" onerror="this.style.display='none'">
    <span>PITCHZONE</span>
    <span id="dbBadge" class="badge" style="display:none;">Cargando...</span>
  </div>
  <nav>
    <a href="#inicio"><i class="fas fa-home"></i> Inicio</a>
    <a href="#proyectos"><i class="fas fa-rocket"></i> Proyectos</a>
    <a href="#alianzas"><i class="fas fa-handshake"></i> Alianzas</a>
    <a href="#eventos"><i class="fas fa-calendar"></i> Eventos</a>
    <a href="#contacto"><i class="fas fa-envelope"></i> Contacto</a>
  </nav>
</header>

<section class="hero" id="inicio">
  <img class="hero-logo" src="logo_pitchzone.png" alt="" onerror="this.style.display='none'">
  <h1>PITCHZONE</h1>
  <p>"Súbelo. Preséntalo. Véndelo."</p>
  <div class="hero-buttons">
    <button class="hero-btn" onclick="openModal('uploadModal')"><i class="fas fa-upload"></i> ¡Sube tu proyecto!</button>
    <button class="hero-btn secondary" onclick="document.getElementById('proyectos').scrollIntoView({behavior:'smooth'})"><i class="fas fa-eye"></i> Ver Proyectos</button>
  </div>
  <div class="stats">
    <div class="stat-item"><span class="stat-number" id="totalProjects">0</span><div class="stat-label">Proyectos</div></div>
    <div class="stat-item"><span class="stat-number" id="totalFunding">$0</span><div class="stat-label">Funding Total</div></div>
    <div class="stat-item"><span class="stat-number" id="totalVotes">0</span><div class="stat-label">Votos</div></div>
  </div>
  <div id="dbInfo" style="margin-top:10px;font-weight:700;"></div>
</section>

<div class="main-content">
  <div class="container">
    <h2 class="section-title" id="caracteristicas">¿Qué puedes hacer en PitchZone?</h2>
    <div class="projects-controls" style="gap:16px;flex-wrap:wrap;justify-content:center">
      <div class="project-card" onclick="animateFeature(this)"><div class="project-header"><div><h3 class="project-title">🎬 Reels de Proyectos</h3></div></div><p class="project-description">Muestra tu pitch en video y destaca ante inversores.</p></div>
      <div class="project-card" onclick="animateFeature(this)"><div class="project-header"><div><h3 class="project-title">🏫 Alianzas Universitarias</h3></div></div><p class="project-description">Difunde tu proyecto con el apoyo de universidades.</p></div>
      <div class="project-card" onclick="openEvents()" id="demoDayCard"><div class="project-header"><div><h3 class="project-title">🚀 Demo Day y Eventos <span id="eventsBadge" class="pill-badge" style="display:none;">0</span></h3></div></div><p class="project-description">Presentaciones, concursos y networking exclusivo.</p></div>
      <div class="project-card" onclick="animateFeature(this)"><div class="project-header"><div><h3 class="project-title">💡 Proyectos Olvidados</h3></div></div><p class="project-description">Revive y publica ideas con potencial.</p></div>
    </div>
  </div>
</div>

<section class="projects-section" id="proyectos">
  <div class="container">
    <h2 class="section-title">Proyectos Destacados</h2>
    <div class="projects-controls">
      <button class="filter-btn active" onclick="filterProjects('all', this)">Todos</button>
      <button class="filter-btn" onclick="filterProjects('tech', this)">Tecnología</button>
      <button class="filter-btn" onclick="filterProjects('social', this)">Social</button>
      <button class="filter-btn" onclick="filterProjects('eco', this)">Ecología</button>
      <button class="filter-btn" onclick="filterProjects('health', this)">Salud</button>
      <button class="filter-btn" onclick="filterProjects('education', this)">Educación</button>
    </div>
    <div class="projects-grid" id="projectsGrid"></div>
  </div>
</section>

<section class="projects-section" id="alianzas">
  <div class="container">
    <h2 class="section-title">Alianzas Universitarias</h2>
    <div class="projects-controls" style="gap:12px;align-items:center">
      <span style="font-weight:700;color:#1B768E">Total:</span>
      <span id="alliancesCount" style="font-weight:800">0</span>
      <select id="alliancesFilter" class="filter-btn" onchange="renderAlliances()">
        <option value="all">Todas</option>
        <option value="Pública">Públicas</option>
        <option value="Privada">Privadas</option>
      </select>
    </div>
    <div class="projects-grid" id="alliancesGrid"></div>
  </div>
</section>

<section class="projects-section" id="eventos">
  <div class="container">
    <h2 class="section-title">Próximos Eventos</h2>
    <div id="eventsInfo" style="text-align:center;margin-bottom:16px;color:#1B768E;font-weight:700;"></div>
    <div class="projects-grid" id="eventsGrid"></div>
  </div>
</section>

<footer id="contacto">
  <div class="footer-links">
    <a href="#" onclick="showToast('Instagram próximamente', 'info')"><i class="fab fa-instagram"></i> Instagram</a>
    <a href="#" onclick="showToast('LinkedIn próximamente', 'info')"><i class="fab fa-linkedin"></i> LinkedIn</a>
    <a href="#" onclick="showToast('YouTube próximamente', 'info')"><i class="fab fa-youtube"></i> YouTube</a>
  </div>
  <p>© 2025 PitchZone • Desplegado en AWS EC2</p>
</footer>

<!-- Seeds (marcadores vacíos: NO se inyectan JSON en el HTML) -->
<script id="projectsSeed" type="application/json"></script>
<script id="universidadesSeed" type="application/json"></script>
<script id="eventsSeed" type="application/json"></script>

<script>
// ========= CONFIG =========
const API_BASE = "%%API_BASE%%";
const API_PROJECTS = API_BASE + "/projects";
// ==========================

function escapeHtml(s){return String(s||'').replace(/[&<>\"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',\"'\":'&#039;'}[m]))}
window.addEventListener('scroll',()=>{const h=document.querySelector('header');h.style.background=window.scrollY>100?'rgba(1,37,56,.98)':'rgba(1,37,56,.95)'});

// ===== Proyectos =====
let projectsData=[], currentFilter='all', projectVotes={};
const projectCategories={'EcoSmart Delivery':'eco','PetMatch':'social','Exxxtasis':'social','SmartWaste':'eco','FitFinance':'finance','EduPlay':'education','AgroScan':'tech','SaludYA':'health','JobQuest':'tech','CleanOcean':'eco'};

document.addEventListener('DOMContentLoaded',async ()=>{
  // Preferir backend (si existe)
  await fetchProjectsFromApi().catch(()=>{});
  if (!projectsData.length) loadProjects();  // fallback seed/archivo
  loadUniversidades();
  loadEvents(updateEventsBadge);

  if (window.location.hash === '#eventos') setTimeout(openEvents, 500);
  setTimeout(()=>showToast('¡Bienvenido a PitchZone! 🎉','info'),700);

  // Badge de disponibilidad de alianzas.json
  try{
    const r = await fetch('/assets/alianzas.json?v=' + Date.now(), {cache:'no-store'});
    const ok = r.ok;
    document.getElementById('dbBadge').style.display='inline-block';
    if(ok){
      document.getElementById('dbBadge').textContent='Alianzas OK';
      document.getElementById('dbBadge').style.background='#10B981';
    } else {
      document.getElementById('dbBadge').textContent='Alianzas N/D';
      document.getElementById('dbBadge').style.background='#F59E0B';
      document.getElementById('dbBadge').style.color='#012538';
    }
  }catch(e){}
});

async function fetchProjectsFromApi(){
  if (!API_BASE || API_BASE.includes('%%API_BASE%%')) return; // aún no reemplazado
  const r=await fetch(API_PROJECTS); const arr=await r.json(); if(!Array.isArray(arr)) return;
  projectsData=arr.map(x=>({nombre_proyecto:x.nombre_proyecto,descripcion:x.descripcion,integrantes:x.integrantes||[],funding_necesario:Number(x.funding_necesario)||0,categoria:x.categoria||'tech'}));
  updateStats(); renderProjects(); updateDbStatus(true,projectsData.length);
}

function loadProjects(){
  const seed=document.getElementById('projectsSeed'); 
  try{const t=(seed&&seed.textContent||'').trim(); if(t.startsWith('[')){projectsData=JSON.parse(t); updateStats(); renderProjects(); updateDbStatus(true,projectsData.length); return;}}catch{}
  fetch('./proyectos.json?t='+Date.now(),{cache:'no-store'})
    .then(r=>r.ok?r.json():Promise.reject(r.status))
    .then(d=>{projectsData=d; updateStats(); renderProjects(); updateDbStatus(true,d.length);})
    .catch(()=>{projectsData=getSampleProjects(); updateStats(); renderProjects(); updateDbStatus(false,projectsData.length);});
}
function getSampleProjects(){return[
 {nombre_proyecto:"EcoSmart Delivery",descripcion:"Optimiza rutas con IA.",integrantes:["Ana","Luis","María"],funding_necesario:25000},
 {nombre_proyecto:"PetMatch",descripcion:"Adopción interactiva.",integrantes:["Julia","Fer","Renata"],funding_necesario:18000},
 {nombre_proyecto:"SmartWaste",descripcion:"IoT para recolección inteligente.",integrantes:["Carlos","Lucía"],funding_necesario:22000}
];}
function initializeVotes(){projectsData.forEach(p=>{if(!projectVotes[p.nombre_proyecto])projectVotes[p.nombre_proyecto]=Math.floor(Math.random()*50)+5;});}
function updateStats(){initializeVotes();const tp=projectsData.length;const tf=projectsData.reduce((s,p)=>s+Number(p.funding_necesario||0),0);const tv=Object.values(projectVotes).reduce((s,v)=>s+v,0);animate('totalProjects',tp);animate('totalFunding',tf,true);animate('totalVotes',tv);}
function animate(id,val,money=false){const el=document.getElementById(id);const t0=performance.now(),d=900;const from=0;function step(t){const k=Math.min((t-t0)/d,1);const v=Math.floor(from+(val-from)*k);el.textContent=money?('$'+v.toLocaleString()):v.toLocaleString();if(k<1)requestAnimationFrame(step);}requestAnimationFrame(step);}
function renderProjects(){const grid=document.getElementById('projectsGrid');const list=currentFilter==='all'?projectsData:projectsData.filter(p=>projectCategories[p.nombre_proyecto]===currentFilter);grid.innerHTML=list.map(p=>`
  <div class="project-card">
    <div class="project-header"><div><h3 class="project-title">${escapeHtml(p.nombre_proyecto)}</h3></div>
    <div class="project-funding">$${Number(p.funding_necesario||0).toLocaleString()}</div></div>
    <p class="project-description">${escapeHtml(p.descripcion)}</p>
    <div class="team-label"><i class="fas fa-users"></i> Equipo:</div>
    <div class="team-members">${(p.integrantes||[]).map(n=>`<span class="team-member">${escapeHtml(n)}</span>`).join('')}</div>
    <div style="display:flex;justify-content:space-between;align-items:center;margin-top:10px">
      <button class="vote-btn" onclick="voteProject('${p.nombre_proyecto.replace(/'/g,"\\'")}')"><i class="fas fa-thumbs-up"></i> Votar</button>
      <span class="vote-count"><i class="fas fa-heart"></i> ${projectVotes[p.nombre_proyecto]||0}</span>
    </div>
  </div>`).join('');}
function voteProject(name){projectVotes[name]=(projectVotes[name]||0)+1;updateStats();renderProjects();showToast('¡Voto registrado! 🎉','success');}
function filterProjects(cat,btn){currentFilter=cat;document.querySelectorAll('.filter-btn').forEach(b=>b.classList.remove('active'));if(btn)btn.classList.add('active');renderProjects();}
function updateDbStatus(ok,count){const b=document.getElementById('dbBadge'),i=document.getElementById('dbInfo');b.style.display='inline-block';if(ok){b.textContent='DB: '+count+' proyectos';b.style.background='var(--success-green)';i.innerHTML='📊 Base de datos conectada • <span style="color:var(--primary-orange)">'+count+' proyectos</span>';}else{b.textContent='DEMO';b.style.background='var(--warning-yellow)';b.style.color='var(--primary-dark)';i.innerHTML='🔧 Modo demostración';}}

// ===== Universidades =====
let universidadesData=[];
async function loadUniversidades(){
  // 1) Intentar tu archivo principal
  try{
    const r = await fetch('/assets/alianzas.json?v='+Date.now(),{cache:'no-store'});
    if(r.ok){
      const obj = await r.json();
      universidadesData = Array.isArray(obj)?obj:(Array.isArray(obj.alianzas_universitarias)?obj.alianzas_universitarias:[]);
      renderAlliances();
      return;
    }
  }catch(e){}
  // 2) Fallback clásico
  fetch('./universidades.json?t='+Date.now(),{cache:'no-store'})
    .then(r=>r.ok?r.json():Promise.reject(r.status))
    .then(obj=>{universidadesData=Array.isArray(obj)?obj:(Array.isArray(obj.alianzas_universitarias)?obj.alianzas_universitarias:[]);renderAlliances();})
    .catch(()=>{universidadesData=[{id:0,nombre:"Universidad Demo",siglas:"DEMO",tipo:"Pública",ubicacion:"Ciudad Demo",sitio_web:"https://example.com"}];renderAlliances();});
}
function renderAlliances(){
  const grid=document.getElementById('alliancesGrid'),count=document.getElementById('alliancesCount'),sel=document.getElementById('alliancesFilter');
  const filtro=sel?sel.value:'all'; let data=universidadesData.slice();
  if(filtro!=='all') data=data.filter(a=>(a.tipo||'').toLowerCase()===filtro.toLowerCase());
  if(count) count.textContent=data.length;
  grid.innerHTML=data.map(a=>`
    <div class="project-card">
      <div class="project-header">
        <div style="display:flex;align-items:center;gap:10px">
          ${a.logo?`<img src="${a.logo}" alt="${(a.siglas||a.nombre||'logo')}" style="width:42px;height:42px;object-fit:contain;border-radius:8px" onerror="this.style.display='none'">`:``}
          <div>
            <h3 class="project-title">${escapeHtml(a.nombre||a.siglas||'Universidad')}</h3>
            <div style="color:#1B768E;font-weight:700">${escapeHtml(a.siglas||'')} ${a.tipo?'• '+escapeHtml(a.tipo):''} ${a.ubicacion?'• '+escapeHtml(a.ubicacion):''}</div>
          </div>
        </div>
        ${a.sitio_web?`<a class="project-funding" href="${a.sitio_web}" target="_blank" rel="noopener">Sitio</a>`:''}
      </div>
      ${a.sitio_web?`<p class="project-description"><a href="${a.sitio_web}" target="_blank" rel="noopener">${escapeHtml(a.sitio_web)}</a></p>`:''}
    </div>`).join('');
}

// ===== Eventos =====
let eventsData=[];
function openEvents() {
  const rocket=document.createElement('div'); rocket.className='rocket-fx'; rocket.textContent='🚀'; document.body.appendChild(rocket);
  const go=()=>{rocket.addEventListener('animationend',()=>{rocket.remove();document.getElementById('eventos').scrollIntoView({behavior:'smooth'});showToast('Mostrando próximos eventos 🚀','info');},{once:true});};
  if (!eventsData.length) loadEvents(()=>{updateEventsBadge();go();}); else {updateEventsBadge();go();}
}
function loadEvents(done){
  fetch('./eventos.json?t='+Date.now(),{cache:'no-store'})
    .then(r=>r.ok?r.json():Promise.reject(r.status))
    .then(d=>{eventsData=normalizeEvents(d); renderEvents(); updateEventsBadge(); if(done)done();})
    .catch(()=>{eventsData=[{titulo:"PitchZone Demo Day LATAM",fecha:proxDia(7),hora:"18:00",modalidad:"Online",descripcion:"Presenta tu pitch a mentores e inversionistas.",registro_url:"#"},
                           {titulo:"Taller: Storytelling para Pitches",fecha:proxDia(14),hora:"17:00",modalidad:"Híbrido",descripcion:"Estructura un pitch ganador en 60 minutos.",registro_url:"#"},
                           {titulo:"Matchmaking Startups × Universidades",fecha:proxDia(21),hora:"19:00",modalidad:"Online",descripcion:"Conecta con universidades para alianzas y talento.",registro_url:"#"}];
             renderEvents(); updateEventsBadge(); if(done)done();});
}
function normalizeEvents(o){if(Array.isArray(o))return o; if(Array.isArray(o.eventos))return o.eventos; return [];}
function renderEvents(){const now=new Date();const up=eventsData.map(e=>({...e,_d:new Date(e.fecha||e.date||Date.now())})).filter(e=>!isNaN(e._d)&&e._d>=new Date(now.toDateString())).sort((a,b)=>a._d-b._d).slice(0,3);
  const grid=document.getElementById('eventsGrid'),info=document.getElementById('eventsInfo'); info.textContent=up.length?`Mostrando ${up.length} próximos`:'Sin eventos próximos';
  grid.innerHTML=up.map(e=>`<div class="project-card"><div class="project-header"><div><h3 class="project-title">${escapeHtml(e.titulo||'Evento')}</h3>
  <div style="color:#1B768E;font-weight:700">${formatFecha(e._d)} ${e.hora?'• '+escapeHtml(e.hora):''} ${e.modalidad?'• '+escapeHtml(e.modalidad):''}</div></div>
  ${e.registro_url?`<a class="project-funding" href="${e.registro_url}" target="_blank" rel="noopener">Registrarme</a>`:''}</div>
  ${e.descripcion?`<p class="project-description">${escapeHtml(e.descripcion)}</p>`:''}</div>`).join('');}
function formatFecha(d){try{return d.toLocaleDateString('es-MX',{weekday:'short',day:'2-digit',month:'short',year:'numeric'});}catch{return d.toISOString().slice(0,10);}}
function proxDia(n){const d=new Date();d.setDate(d.getDate()+n);return d.toISOString().slice(0,10);}
function upcomingCountFrom(data){const today=new Date(),mid=new Date(today.toDateString());return (data||[]).map(e=>new Date(e.fecha||e.date||e._d||Date.now())).filter(d=>!isNaN(d)&&d>=mid).length;}
function updateEventsBadge(){const b=document.getElementById('eventsBadge'); if(!b)return; const c=upcomingCountFrom(eventsData); if(c>0){b.textContent=c;b.classList.remove('warn');b.style.display='inline-block';}else{b.textContent='0';b.classList.add('warn');b.style.display='inline-block';}}

// ===== UI =====
function openModal(id){const m=document.getElementById(id); if(!m) return; m.style.display='block'; document.body.style.overflow='hidden';}
function showToast(msg,type='success'){const t=document.createElement('div');t.className='toast '+type; t.style.position='fixed';t.style.top='20px';t.style.right='20px';t.style.background=type==='success'?'#10B981':(type==='info'?'#1B768E':'#EF4444');t.style.color='#fff';t.style.padding='12px 18px';t.style.borderRadius='10px';t.style.fontWeight='800';t.textContent=msg;document.body.appendChild(t);setTimeout(()=>t.remove(),2400);}
function animateFeature(el){ el.style.transform='scale(.95)'; setTimeout(()=>el.style.transform='scale(1)',200); showToast('¡Funcionalidad próximamente! 🚀','info'); }

// === Form submit con API ===
async function submitProject(event){
  event.preventDefault();
  const formData={
    nombre_proyecto:document.getElementById('projectName')?.value.trim(),
    descripcion:document.getElementById('projectDescription')?.value.trim(),
    integrantes:(document.getElementById('teamMembers')?.value||'').split(',').map(s=>s.trim()).filter(Boolean),
    funding_necesario:parseInt(document.getElementById('fundingAmount')?.value||'0',10),
    categoria:document.getElementById('projectCategory')?.value
  };
  const btn=event.target.querySelector('.submit-btn');const orig=btn.innerHTML;btn.innerHTML='<div class="loading"></div> Enviando...';btn.disabled=true;
  try{
    if (!API_BASE || API_BASE.includes('%%API_BASE%%')) throw new Error('API no configurada');
    const res=await fetch(API_PROJECTS,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(formData)});
    const data=await res.json(); if(!res.ok||!data.ok) throw new Error(data.error||'Error al guardar');
    projectsData.unshift(formData); projectCategories[formData.nombre_proyecto]=formData.categoria; projectVotes[formData.nombre_proyecto]=0; updateStats(); renderProjects();
    closeModal('uploadModal'); showToast('¡Proyecto enviado y guardado! 🚀','success'); event.target.reset();
  }catch(e){console.error(e); showToast('Error: '+e.message,'error');}
  finally{btn.innerHTML=orig; btn.disabled=false;}
}
</script>

<!-- Modal -->
<div id="uploadModal" class="modal" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:9990;">
  <div class="modal-content" style="background:#fff;margin:5% auto;padding:30px;max-width:600px;border-radius:16px;position:relative;color:#012538">
    <span style="position:absolute;top:10px;right:16px;font-size:28px;cursor:pointer" onclick="this.closest('.modal').style.display='none';document.body.style.overflow='auto';">&times;</span>
    <h2 style="margin-bottom:14px"><i class="fas fa-rocket"></i> Sube tu Proyecto</h2>
    <form id="uploadForm" onsubmit="submitProject(event)">
      <div class="form-group"><label>Nombre del Proyecto *</label><input id="projectName" required style="width:100%;padding:10px;border:1px solid #ddd;border-radius:8px"></div>
      <div class="form-group"><label>Descripción *</label><textarea id="projectDescription" required rows="4" style="width:100%;padding:10px;border:1px solid #ddd;border-radius:8px"></textarea></div>
      <div class="form-group"><label>Integrantes (separados por coma) *</label><input id="teamMembers" required style="width:100%;padding:10px;border:1px solid #ddd;border-radius:8px"></div>
      <div class="form-group"><label>Funding Necesario (USD) *</label><input id="fundingAmount" required type="number" min="1000" style="width:100%;padding:10px;border:1px solid #ddd;border-radius:8px"></div>
      <div class="form-group"><label>Categoría *</label>
        <select id="projectCategory" required style="width:100%;padding:10px;border:1px solid #ddd;border-radius:8px">
          <option value="">Selecciona</option><option value="tech">Tecnología</option><option value="social">Social</option><option value="eco">Ecología</option><option value="health">Salud</option><option value="education">Educación</option><option value="finance">Finanzas</option>
        </select>
      </div>
      <button type="submit" class="submit-btn" style="margin-top:10px;background:#FB9833;color:#012538;border:none;padding:12px 16px;border-radius:10px;font-weight:800;cursor:pointer">Enviar</button>
    </form>
  </div>
</div>

</body>
</html>
HTMLEOF

  if [ -f /tmp/index.html ] && [ "${USE_SNIPPET_ONLY}" -eq 1 ]; then
  echo "➕ Anexando snippet de index.html (envuelto en <script>)"
  sudo bash -c 'printf "\n<script>\n" >> /var/www/html/index.html'
  sudo bash -c 'cat /tmp/index.html >> /var/www/html/index.html'
  sudo bash -c 'printf "\n</script>\n" >> /var/www/html/index.html'
fi

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

# --- 6) Sustituir API_BASE en el HTML (en la EC2) ---
echo "✏️ Inyectando API_BASE en index.html remoto ..."
ssh -i "$KEY_PEM" -o StrictHostKeyChecking=no "$REMOTE" "sudo sed -i \"s|%%API_BASE%%|$API_BASE|g\" /var/www/html/index.html && sudo systemctl restart httpd"

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
echo "🎉 ¡PITCHZONE desplegado con BACKEND + JSON unificado!"
echo "🌐 Web:   http://$PUBLIC_IP"
echo "🛠️  API:  $API_BASE"
echo "   • POST $API_BASE/projects"
echo "   • GET  $API_BASE/projects"
echo "📦 JSON:  http://$PUBLIC_IP/assets/alianzas.json"
echo ""
echo "Sugerencia front-end: fetch('/assets/alianzas.json?v=' + Date.now())"
echo ""