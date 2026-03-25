## Uso local

```bash
./aws_ai.sh ec2 describe-instances
```

`aws_ai.sh` carga `.env` automaticamente desde el mismo directorio.
Si quieres usar otro archivo, define `AWS_AI_ENV_FILE`.

La duración de la sesión temporal STS es configurable con `AWS_AI_SESSION_DURATION_SECONDS` (segundos; por defecto 900). Detalle en las notas al final.

## Skill del agente ([skills.sh](https://skills.sh))

El catálogo y la CLI del ecosistema están en [skills.sh](https://skills.sh). Para instalar solo la skill **aws-ai** de este repositorio (carpeta `skills/aws-ai/`) con [Skills CLI](https://github.com/vercel-labs/skills) (`npx skills`):

```bash
# Ver qué skills detecta el CLI en el repo
npx skills add KaribuLab/aws-cli-helper --list

# Instalar la skill aws-ai (ejemplo: Cursor, sin prompts)
npx skills add KaribuLab/aws-cli-helper --skill aws-ai -a cursor -y
```

Instalación global (disponible en todos los proyectos del usuario): añade `-g`.

```bash
npx skills add KaribuLab/aws-cli-helper --skill aws-ai -a cursor -g -y
```

Alternativa indicando la ruta del skill en GitHub:

```bash
npx skills add https://github.com/KaribuLab/aws-cli-helper/tree/main/skills/aws-ai
```

El CLI detecta agentes instalados; si no, te pedirá destino. Otros agentes: `-a claude-code`, `-a codex`, etc. Más opciones: `npx skills --help`.

## Uso con Docker (sin instalar AWS CLI en host)

Build:

```bash
docker build -t aws_ia .
```

Ejecutar pasando region explícita:

```bash
docker run --rm -it \
  -v ~/.aws:/home/user/.aws \
  --env-file .env \
  aws_ia us-east-2 ec2 describe-instances
```

Ejecutar sin region (usa `AWS_REGION`):

```bash
docker run --rm -it \
  -v ~/.aws:/home/user/.aws \
  --env-file .env \
  aws_ia ec2 describe-instances
```

Notas:
- El contenedor ya trae `awscli`, `bash` y `jq`.
- Si no hay `secret-tool`, el script usa cache local cifrada (`openssl`) en `~/.aws/.cache/aws_ai`.
- Puedes pasar `AWS_AI_CACHE_PASSPHRASE` por `--env-file .env` o ingresarla cuando el script la pida.
- El entrypoint desactiva el pager de AWS (`AWS_PAGER=""`) para evitar error por falta de `less`.
- Variables sensibles/configurables se leen desde entorno: `AWS_AI_PROFILE`, `AWS_AI_ASSUME_ROLE_ARN`, `AWS_AI_MFA_SERIAL_ARN`.
- Duración de la sesión temporal STS: `AWS_AI_SESSION_DURATION_SECONDS` (segundos, entre 900 y 43200; por defecto 900). El rol IAM puede tener un `MaxSessionDuration` menor que el valor que pidas; en ese caso AWS devolverá error al asumir el rol.
- `.env` no se ignora en git por defecto en este proyecto.

## TODO

- [ ] Publicar imagen Docker en Docker Hub
- [ ] Incluir ejemplo para crear role y policies de IAM para usar con este helper