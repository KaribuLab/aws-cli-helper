## Uso local

```bash
./aws_ai.sh ec2 describe-instances
```

`aws_ai.sh` carga `.env` automaticamente desde el mismo directorio.
Si quieres usar otro archivo, define `AWS_AI_ENV_FILE`.

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
- `.env` no se ignora en git por defecto en este proyecto.
