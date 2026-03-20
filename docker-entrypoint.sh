#!/usr/bin/env bash

set -euo pipefail

# Evita depender de `less` dentro del contenedor
export AWS_PAGER="${AWS_PAGER:-}"

if [ $# -lt 1 ]; then
    echo "Uso: docker run --rm -it -v ~/.aws:/home/user/.aws --env-file .env aws_ia <region|aws-subcommand> <aws command...>"
    echo "Ejemplo 1 (con region): docker run --rm -it -v ~/.aws:/home/user/.aws --env-file .env aws_ia us-east-2 ec2 describe-instances"
    echo "Ejemplo 2 (sin region, usa AWS_REGION del .env): docker run --rm -it -v ~/.aws:/home/user/.aws --env-file .env aws_ia ec2 describe-instances"
    exit 1
fi

if [[ "$1" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
    exec /app/aws_ai.sh "$@"
fi

region="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
exec /app/aws_ai.sh "$region" "$@"
