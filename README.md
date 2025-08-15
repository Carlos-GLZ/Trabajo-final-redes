# PitchZone

Repositorio del proyecto final de la materia de Redes. Incluye el sitio web estático y los scripts necesarios para desplegar la plataforma **PitchZone** ("Súbelo. Preséntalo. Véndelo.") sobre Amazon Web Services.

## Contenido del repositorio

| Archivo | Descripción |
|--------|-------------|
| `index.html` | Página principal con estilo y lógica para mostrar proyectos, alianzas y autenticación. |
| `proyectos.json`, `alianzas.json` | Datos de ejemplo consumidos por el frontend. |
| `logo_pitchzone.png` | Imagen utilizada en la interfaz. |
| `create-infraestructura.sh` | Crea la infraestructura base en AWS: VPC, Subnet, Security Group, instancia EC2, Elastic IP y bucket S3. |
| `deploy-web-site.sh` | Copia los archivos al servidor, despliega la API (Lambda + DynamoDB + API Gateway) y configura Cognito. |
| `cleanup.sh` | Elimina los recursos creados en AWS (EC2, VPC, EIP, KeyPairs, etc.). |
| `pitchzone-backend.yml` | Plantilla CloudFormation para la API REST y la base de datos. |
| `pitchzone-auth.yml` | Plantilla CloudFormation para el User Pool de Cognito y su authorizer. |

## Prerrequisitos

- Cuenta de AWS con permisos para EC2, S3, IAM, Lambda, DynamoDB y API Gateway.
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configurado con credenciales.
- Herramientas de línea de comandos: `bash`, `ssh`, `scp` y `curl`.

## Flujo de uso

### 1. Crear infraestructura básica

```bash
./create-infraestructura.sh
```

Genera `infraestructura-info.txt` con los identificadores de la VPC, EC2, bucket S3 y otros recursos.

### 2. Desplegar aplicación y backend

```bash
./deploy-web-site.sh
```

Copia los archivos estáticos al servidor, levanta la API (Lambda + DynamoDB) y configura la autenticación mediante Cognito.

### 3. Limpiar recursos

```bash
./cleanup.sh        # modo interactivo
./cleanup.sh --dry-run   # muestra lo que eliminaría
```

## Personalización

- Edita `index.html`, `proyectos.json` o `alianzas.json` para adaptar el contenido del sitio.
- Las variables de API y Cognito se inyectan automáticamente en `index.html` durante `deploy-web-site.sh`.
- Puedes modificar la región o el tipo de instancia exportando variables antes de ejecutar los scripts:
  ```bash
  REGION=us-west-2 INSTANCE_TYPE=t3.micro ./create-infraestructura.sh
  ```

## Advertencia

Los scripts crean y destruyen recursos en AWS que podrían generar costos. Revisa el código y confirma que tu cuenta tiene los permisos adecuados antes de ejecutarlos.
