## Uso con Docker (recomendado)

El flujo soportado es **usar la imagen Docker**: no hace falta instalar AWS CLI, `jq` ni `openssl` en el host; todo va dentro del contenedor.

### Construir la imagen

```bash
docker build -t aws_ia .
```

(Obtén una imagen publicada con `docker pull <tu-registry>/aws_ia:latest` si la usáis en registro.)

### Ejecutar con región explícita

```bash
docker run --rm -it \
  -v ~/.aws:/home/user/.aws \
  --env-file .env \
  aws_ia us-east-2 ec2 describe-instances
```

### Ejecutar sin región en la línea de comandos (usa `AWS_REGION` del `.env`)

```bash
docker run --rm -it \
  -v ~/.aws:/home/user/.aws \
  --env-file .env \
  aws_ia ec2 describe-instances
```

### Persistencia y cifrado

- La imagen incluye **OpenSSL**. Las credenciales temporales se guardan solo como **archivo cifrado** bajo `~/.aws/.cache/aws_ai` en el volumen montado (`~/.aws` del host). **No** se escribe sesión en texto plano.
- Necesitas `AWS_AI_CACHE_PASSPHRASE` en el entorno (por ejemplo `--env-file .env`) o el script la pedirá en modo interactivo.
- Quien ejecuta la imagen **no** tiene que instalar OpenSSL en su máquina.

### Notas

- El contenedor incluye `awscli`, `bash`, `jq` y `openssl`.
- El entrypoint desactiva el pager de AWS (`AWS_PAGER=""`) para evitar errores por falta de `less`.
- Variables habituales: `AWS_AI_PROFILE`, `AWS_AI_ASSUME_ROLE_ARN`, `AWS_AI_MFA_SERIAL_ARN`, `AWS_REGION`.
- Duración STS: `AWS_AI_SESSION_DURATION_SECONDS` (900–43200; por defecto 900). El rol IAM puede tener un `MaxSessionDuration` menor.
- Los `.env` reales están en `.gitignore`; solo se versiona `.env.example`.

## Skill del agente ([skills.sh](https://skills.sh))

El catálogo y la CLI del ecosistema están en [skills.sh](https://skills.sh). Para instalar la skill **aws-ai** de este repositorio (`skills/aws-ai/`) con [Skills CLI](https://github.com/vercel-labs/skills) (`npx skills`):

```bash
npx skills add KaribuLab/aws-cli-helper --list

npx skills add KaribuLab/aws-cli-helper --skill aws-ai -a cursor -y
```

Instalación global: añade `-g`.

```bash
npx skills add KaribuLab/aws-cli-helper --skill aws-ai -a cursor -g -y
```

Por ruta en GitHub:

```bash
npx skills add https://github.com/KaribuLab/aws-cli-helper/tree/main/skills/aws-ai
```

Más agentes: `-a claude-code`, `-a codex`, etc. Ayuda: `npx skills --help`.

## Modo desatendido (agentes y automatización)

Para CI/CD o agentes sin TTY, el helper permite MFA por variable de entorno y código de salida `2` cuando falta token.

Por defecto el uso **humano** con la imagen sigue siendo interactivo (`-it`) cuando hace falta MFA o la passphrase de cache. El modo desatendido se activa **por invocación** con `-e` en `docker run`, sin obligar a fijarlo en `.env`.

### Variables (desatendido / reintento MFA)

- `AWS_AI_UNATTENDED` — `true` o `1`: no bloquea en `read`; si falta MFA, sale con código `2`. Usar `-e AWS_AI_UNATTENDED=true` en ese `docker run`.
- `AWS_AI_MFA_TOKEN` — TOTP de 6 dígitos en el reintento. Pasar con `-e AWS_AI_MFA_TOKEN=...` en esa ejecución; no guardar en `.env`.

### Códigos de salida

| Código | Significado |
|--------|-------------|
| `0` | Éxito |
| `1` | Error (STS, validación, AWS CLI, token MFA inválido) |
| `2` | MFA requerido (stderr puede incluir `AWS_AI_MFA_REQUIRED=1`) |

### Ejemplo de flujo para agentes

```bash
if ! docker run --rm \
  -v ~/.aws:/home/user/.aws \
  --env-file .env \
  -e AWS_AI_UNATTENDED=true \
  aws_ia sts get-caller-identity; then
  exit_code=$?
  if [ $exit_code -eq 2 ]; then
    echo "MFA requerido. Reintenta con AWS_AI_MFA_TOKEN."
  fi
fi

AWS_AI_MFA_TOKEN=123456 docker run --rm \
  -v ~/.aws:/home/user/.aws \
  --env-file .env \
  -e AWS_AI_MFA_TOKEN \
  aws_ia sts get-caller-identity
```

### Seguridad

- No guardes `AWS_AI_MFA_TOKEN` en `.env` ni lo subas a git.
- Los valores en `-e` pueden verse en inspección del contenedor o logs; úsalos de forma puntual.

## Script en el host (solo desarrollo avanzado)

El repositorio incluye `aws_ai.sh` para pruebas locales. **Requiere `openssl` en el PATH** (sin openssl el script termina con error: no hay persistencia en texto plano). El uso documentado para equipos es **Docker** arriba.

## TODO

- [ ] Incluir ejemplo para crear role y policies de IAM para usar con este helper
