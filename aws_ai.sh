#!/bin/bash

# ----------------------------

# Utiles

# ----------------------------

log(){
    local level=$1
    local message=$2

    local COLOR_RESET="\033[0m"
    local COLOR_INFO="\033[0;34m"
    local COLOR_DEBUG="\033[0;90m"
    local COLOR_ERROR="\033[0;31m"
    local color="$COLOR_RESET"

    case "$level" in
        INFO)
            color="$COLOR_INFO"
            ;;
        DEBUG)
            color="$COLOR_DEBUG"
            ;;
        ERROR)
            color="$COLOR_ERROR"
            ;;
    esac

    printf "%b[%s]: %s%b\n" "$color" "$level" "$message" "$COLOR_RESET"
}

log_debug(){
    if [ "${CLI_DEBUG}" == "true" ]; then
        log "DEBUG" "$1"
    fi
}

log_info(){
    log "INFO" "$1"
}

log_error(){
    log "ERROR" "$1"
}

# ----------------------------

# Validación de argumentos

# ----------------------------

if [ $# -lt 1 ]; then
log_info "Uso: aws_ai.sh [region] <aws command...>"
log_info "Ejemplo: aws_ai.sh us-east-1 ec2 describe-instances"
log_info "Ejemplo: aws_ai.sh ec2 describe-instances (usa AWS_REGION)"
exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${AWS_AI_ENV_FILE:-${script_dir}/.env}"

if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
    log_debug "Archivo de entorno cargado: $env_file"
fi

aws_profile="${AWS_AI_PROFILE:-}"
assume_role_arn="${AWS_AI_ASSUME_ROLE_ARN:-}"
mfa_serial_arn="${AWS_AI_MFA_SERIAL_ARN:-}"
secret_app="${AWS_AI_SECRET_APP:-aws-ai}"
assume_role_name="${AWS_AI_ASSUME_ROLE_NAME:-${assume_role_arn##*/}}"
secret_role="${AWS_AI_SECRET_ROLE:-$assume_role_name}"

# Modo desatendido: si no hay sesión y no hay token, salir con código 2 en lugar de bloquear en read
unattended_mode="${AWS_AI_UNATTENDED:-false}"
# Token MFA para modo no interactivo (6 dígitos TOTP)
mfa_token="${AWS_AI_MFA_TOKEN:-}"

# Duración de la sesión STS (segundos). Límite API: 900–43200; el rol puede imponer un máximo menor.
session_duration_seconds="${AWS_AI_SESSION_DURATION_SECONDS:-900}"
if ! [[ "$session_duration_seconds" =~ ^[0-9]+$ ]]; then
    log_error "AWS_AI_SESSION_DURATION_SECONDS debe ser un entero (segundos). Valor actual: ${session_duration_seconds}"
    exit 1
fi
if [ "$session_duration_seconds" -lt 900 ] || [ "$session_duration_seconds" -gt 43200 ]; then
    log_error "AWS_AI_SESSION_DURATION_SECONDS debe estar entre 900 y 43200 (segundos). Valor actual: ${session_duration_seconds}"
    exit 1
fi

if [ -z "$aws_profile" ] || [ -z "$assume_role_arn" ] || [ -z "$mfa_serial_arn" ]; then
    log_error "Faltan variables requeridas: AWS_AI_PROFILE, AWS_AI_ASSUME_ROLE_ARN y AWS_AI_MFA_SERIAL_ARN"
    exit 1
fi

if [[ "$1" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
    aws_region=$1
    shift 1
else
    aws_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
fi

if [ -z "$aws_region" ]; then
    log_error "No se definió region. Pasa [region] o define AWS_REGION/AWS_DEFAULT_REGION"
    exit 1
fi

if [ $# -lt 1 ]; then
    log_error "Falta comando AWS. Ejemplo: ec2 describe-instances"
    exit 1
fi
cache_dir="${AWS_AI_CACHE_DIR:-$HOME/.aws/.cache/aws_ai}"
cache_file="${cache_dir}/${aws_profile}_${secret_role}.enc"

persist_backend=encrypted_file
if command -v secret-tool >/dev/null 2>&1; then
    persist_backend=keyring
elif ! command -v openssl >/dev/null 2>&1; then
    persist_backend=file
fi

log_debug "Persistencia de sesión: ${persist_backend}"

is_assumed_role_session(){
    local arn
    arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
    [[ "$arn" == *":assumed-role/${assume_role_name}/"* ]]
}

clear_session_env(){
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN
    unset AWS_CREDENTIAL_EXPIRATION
    unset AWS_CREDENTIAL_EXPIRATION_EPOCH
}

ensure_cache_passphrase(){
    if [ -n "${AWS_AI_CACHE_PASSPHRASE:-}" ]; then
        export AWS_AI_CACHE_PASSPHRASE
        return 0
    fi

    if [ ! -t 0 ]; then
        log_error "Falta AWS_AI_CACHE_PASSPHRASE para usar cache cifrada en modo no interactivo"
        return 1
    fi

    read -r -s -p "Clave para cache cifrada: " AWS_AI_CACHE_PASSPHRASE
    echo

    if [ -z "$AWS_AI_CACHE_PASSPHRASE" ]; then
        log_error "La clave de cache cifrada no puede estar vacia"
        return 1
    fi

    export AWS_AI_CACHE_PASSPHRASE
    return 0
}

load_encrypted_file_session(){
    local tmp_file

    if [ ! -f "$cache_file" ]; then
        return 1
    fi

    if ! ensure_cache_passphrase; then
        return 1
    fi

    tmp_file="${cache_file}.dec.$$"

    if ! openssl enc -d -aes-256-cbc -pbkdf2 -salt \
        -pass env:AWS_AI_CACHE_PASSPHRASE \
        -in "$cache_file" \
        -out "$tmp_file" >/dev/null 2>&1; then
        log_debug "No pude descifrar cache de sesión (clave incorrecta o archivo corrupto)"
        rm -f "$tmp_file"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$tmp_file"
    rm -f "$tmp_file"

    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN
    export AWS_CREDENTIAL_EXPIRATION
    export AWS_CREDENTIAL_EXPIRATION_EPOCH
}

store_encrypted_file_session(){
    local tmp_file
    local plain_tmp_file
    tmp_file="${cache_file}.tmp.$$"
    plain_tmp_file="${cache_file}.plain.$$"

    if ! ensure_cache_passphrase; then
        return 1
    fi

    if ! mkdir -p "$cache_dir" 2>/dev/null; then
        log_error "No pude crear cache_dir: $cache_dir"
        return 1
    fi

    if [ ! -w "$cache_dir" ]; then
        log_error "Sin permisos de escritura en cache_dir: $cache_dir"
        return 1
    fi

    if ! {
        printf 'AWS_ACCESS_KEY_ID=%q\n' "$AWS_ACCESS_KEY_ID"
        printf 'AWS_SECRET_ACCESS_KEY=%q\n' "$AWS_SECRET_ACCESS_KEY"
        printf 'AWS_SESSION_TOKEN=%q\n' "$AWS_SESSION_TOKEN"
        printf 'AWS_CREDENTIAL_EXPIRATION=%q\n' "$AWS_CREDENTIAL_EXPIRATION"
        printf 'AWS_CREDENTIAL_EXPIRATION_EPOCH=%q\n' "$AWS_CREDENTIAL_EXPIRATION_EPOCH"
    } > "$plain_tmp_file"; then
        log_error "No pude escribir cache temporal: $plain_tmp_file"
        rm -f "$plain_tmp_file"
        return 1
    fi

    if ! openssl enc -aes-256-cbc -pbkdf2 -salt \
        -pass env:AWS_AI_CACHE_PASSPHRASE \
        -in "$plain_tmp_file" \
        -out "$tmp_file" >/dev/null 2>&1; then
        log_error "No pude cifrar la cache de sesión"
        rm -f "$plain_tmp_file" "$tmp_file"
        return 1
    fi

    rm -f "$plain_tmp_file"

    if ! mv "$tmp_file" "$cache_file"; then
        log_error "No pude mover cache temporal a: $cache_file"
        rm -f "$tmp_file"
        return 1
    fi

    chmod 600 "$cache_file"
}

load_file_session(){
    if [ ! -f "$cache_file" ]; then
        return 1
    fi

    # shellcheck disable=SC1090
    source "$cache_file"
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN
    export AWS_CREDENTIAL_EXPIRATION
    export AWS_CREDENTIAL_EXPIRATION_EPOCH
}

store_file_session(){
    local tmp_file
    tmp_file="${cache_file}.tmp.$$"

    if ! mkdir -p "$cache_dir" 2>/dev/null; then
        log_error "No pude crear cache_dir: $cache_dir"
        return 1
    fi

    if [ ! -w "$cache_dir" ]; then
        log_error "Sin permisos de escritura en cache_dir: $cache_dir"
        return 1
    fi

    if ! {
        printf 'AWS_ACCESS_KEY_ID=%q\n' "$AWS_ACCESS_KEY_ID"
        printf 'AWS_SECRET_ACCESS_KEY=%q\n' "$AWS_SECRET_ACCESS_KEY"
        printf 'AWS_SESSION_TOKEN=%q\n' "$AWS_SESSION_TOKEN"
        printf 'AWS_CREDENTIAL_EXPIRATION=%q\n' "$AWS_CREDENTIAL_EXPIRATION"
        printf 'AWS_CREDENTIAL_EXPIRATION_EPOCH=%q\n' "$AWS_CREDENTIAL_EXPIRATION_EPOCH"
    } > "$tmp_file"; then
        log_error "No pude escribir cache temporal: $tmp_file"
        rm -f "$tmp_file"
        return 1
    fi

    if ! mv "$tmp_file" "$cache_file"; then
        log_error "No pude mover cache temporal a: $cache_file"
        rm -f "$tmp_file"
        return 1
    fi

    chmod 600 "$cache_file"
}

clear_file_session(){
    rm -f "$cache_file"
}

secret_store(){
    local key=$1
    local value=$2
    printf '%s' "$value" | secret-tool store \
        --label="AWS AI ${key}" \
        app "$secret_app" \
        profile "$aws_profile" \
        role "$secret_role" \
        key "$key" >/dev/null
}

secret_lookup(){
    local key=$1
    secret-tool lookup \
        app "$secret_app" \
        profile "$aws_profile" \
        role "$secret_role" \
        key "$key" 2>/dev/null || true
}

clear_keyring_session(){
    secret-tool clear app "$secret_app" profile "$aws_profile" role "$secret_role" key access_key_id >/dev/null 2>&1 || true
    secret-tool clear app "$secret_app" profile "$aws_profile" role "$secret_role" key secret_access_key >/dev/null 2>&1 || true
    secret-tool clear app "$secret_app" profile "$aws_profile" role "$secret_role" key session_token >/dev/null 2>&1 || true
    secret-tool clear app "$secret_app" profile "$aws_profile" role "$secret_role" key expiration >/dev/null 2>&1 || true
    secret-tool clear app "$secret_app" profile "$aws_profile" role "$secret_role" key expiration_epoch >/dev/null 2>&1 || true
}

clear_persisted_session(){
    if [ "$persist_backend" = "keyring" ]; then
        clear_keyring_session
    elif [ "$persist_backend" = "encrypted_file" ]; then
        clear_file_session
    else
        clear_file_session
    fi
}

load_keyring_session(){
    export AWS_ACCESS_KEY_ID="$(secret_lookup access_key_id)"
    export AWS_SECRET_ACCESS_KEY="$(secret_lookup secret_access_key)"
    export AWS_SESSION_TOKEN="$(secret_lookup session_token)"
    export AWS_CREDENTIAL_EXPIRATION="$(secret_lookup expiration)"
    export AWS_CREDENTIAL_EXPIRATION_EPOCH="$(secret_lookup expiration_epoch)"

    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_SESSION_TOKEN" ]; then
        log_debug "No hay sesión guardada en keyring"
        clear_session_env
        return 1
    fi

    if [ -n "$AWS_CREDENTIAL_EXPIRATION_EPOCH" ] && [ "$AWS_CREDENTIAL_EXPIRATION_EPOCH" -le "$(date +%s)" ]; then
        log_debug "Credenciales de keyring expiradas"
        clear_keyring_session
        clear_session_env
        return 1
    fi

    return 0
}

load_persisted_session(){
    if [ "$persist_backend" = "keyring" ]; then
        load_keyring_session
    elif [ "$persist_backend" = "encrypted_file" ]; then
        load_encrypted_file_session
    else
        load_file_session
    fi
}

store_persisted_session(){
    if [ "$persist_backend" = "keyring" ]; then
        if ! secret_store access_key_id "$AWS_ACCESS_KEY_ID" || \
           ! secret_store secret_access_key "$AWS_SECRET_ACCESS_KEY" || \
           ! secret_store session_token "$AWS_SESSION_TOKEN" || \
           ! secret_store expiration "$AWS_CREDENTIAL_EXPIRATION" || \
           ! secret_store expiration_epoch "$AWS_CREDENTIAL_EXPIRATION_EPOCH"; then
            log_error "No pude guardar la sesión en keyring. Esta ejecución funciona, pero no persistirá."
        fi
    elif [ "$persist_backend" = "encrypted_file" ]; then
        if store_encrypted_file_session; then
            log_debug "Sesión guardada en archivo cifrado: $cache_file"
        else
            log_error "No pude persistir la sesión cifrada. Esta ejecución funciona, pero no persistirá."
        fi
    else
        if store_file_session; then
            log_debug "Sesión guardada en archivo local (texto plano): $cache_file"
        else
            log_error "No pude persistir la sesión en archivo. Esta ejecución funciona, pero no persistirá."
        fi
    fi
}

# ----------------------------

# Verifica sesión existente

# ----------------------------

log_debug "Verificando sesión activa"

session_ready=false

if is_assumed_role_session; then
    log_debug "Sesión actual ya autenticada en ${assume_role_name}"
    session_ready=true
elif load_persisted_session; then
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_SESSION_TOKEN" ]; then
        clear_session_env
    elif [ -n "$AWS_CREDENTIAL_EXPIRATION_EPOCH" ] && [ "$AWS_CREDENTIAL_EXPIRATION_EPOCH" -le "$(date +%s)" ]; then
        log_debug "Credenciales persistidas expiradas"
        clear_persisted_session
        clear_session_env
    elif is_assumed_role_session; then
        log_info "✅ Sesión temporal reutilizada desde ${persist_backend}"
        session_ready=true
    else
        log_debug "Sesión persistida no válida para ${assume_role_name}"
        clear_persisted_session
        clear_session_env
    fi
fi

if [ "$session_ready" != "true" ]; then
    log_debug "Solicitando MFA"

    # Modo con token proporcionado por variable de entorno
    if [ -n "$mfa_token" ]; then
        log_debug "Usando MFA_TOKEN desde variable de entorno"
        # Validar formato: 6 dígitos
        if ! [[ "$mfa_token" =~ ^[0-9]{6}$ ]]; then
            log_error "AWS_AI_MFA_TOKEN debe ser un código de 6 dígitos numéricos"
            exit 1
        fi
        MFA_CODE="$mfa_token"
        # Limpiar la variable para reducir ventana de exposición
        unset mfa_token
        unset AWS_AI_MFA_TOKEN
    # Modo desatendido o sin TTY: no bloquear, reportar que se necesita MFA
    elif [ "$unattended_mode" = "true" ] || [ "$unattended_mode" = "1" ] || [ ! -t 0 ]; then
        log_debug "Modo desatendido o sin TTY: MFA requerido"
        echo "AWS_AI_MFA_REQUIRED=1" >&2
        echo "🔐 Necesito MFA" >&2
        exit 2
    else
        # Modo interactivo tradicional
        echo "🔐 Necesito MFA"
        read -r -p "Código MFA: " MFA_CODE
    fi

    log_debug "Obteniendo credenciales temporales con STS"

CREDS=$(aws sts assume-role \
--profile "$aws_profile" \
--role-arn "$assume_role_arn" \
--role-session-name ai-session \
--serial-number "$mfa_serial_arn" \
--token-code "$MFA_CODE" \
--duration-seconds "$session_duration_seconds")

# Validar que STS respondió correctamente

log_debug "Validando respuesta de STS"

if [ -z "$CREDS" ] || [ "$(echo "$CREDS" | jq -r '.Credentials.AccessKeyId')" == "null" ]; then
log_error "❌ Error obteniendo credenciales temporales"
exit 1
fi

export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Credentials.SessionToken')
export AWS_CREDENTIAL_EXPIRATION=$(echo "$CREDS" | jq -r '.Credentials.Expiration')
export AWS_CREDENTIAL_EXPIRATION_EPOCH=$(date -d "$AWS_CREDENTIAL_EXPIRATION" +%s 2>/dev/null || true)

store_persisted_session

session_duration_min=$((session_duration_seconds / 60))
log_info "✅ Sesión temporal generada (${session_duration_seconds}s, ~${session_duration_min} min)"
fi

# ----------------------------

# Ejecuta comando AWS

# ----------------------------

log_debug "Ejecutando comando: aws --region ${aws_region} $*"

aws --region "$aws_region" "$@"
