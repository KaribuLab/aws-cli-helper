---
name: aws-ai
description: Run AWS commands through the aws-ai CLI helper with MFA-aware session priming using unattended mode.
---

# aws-ai

Use this skill to execute AWS CLI commands through the **Docker image** for the `aws-ai` helper (supported path). All agent-driven operations must use **unattended mode** (`-e AWS_AI_UNATTENDED=true`) to avoid blocking on MFA prompts.

## When to use

- User asks to run AWS CLI commands via this project's helper.
- User wants the agent to operate AWS without installing AWS CLI locally.
- Session/MFA handling is needed (assume-role + temporary credentials).

## Prerequisites

- Docker installed (`docker --version`).
- Environment file at `~/.aws-ai/.env` with required variables:
  - `AWS_AI_PROFILE`
  - `AWS_AI_ASSUME_ROLE_ARN`
  - `AWS_AI_MFA_SERIAL_ARN`
  - `AWS_REGION`

## Agent execution policy (always unattended)

### First aws-ai run in the conversation

On the **first** time in the current chat session that the user asks you to run the helper (Docker flow), run **`docker pull`** for the image **before** any `docker run`, so the local image matches the registry (e.g. `docker pull karibu/aws-ai:latest`). Do this **once per conversation session**, not before every command.

The agent must **always** run the helper in **unattended mode** by passing `-e AWS_AI_UNATTENDED=true` in every `docker run` invocation. Do not use `-i` or `-it`: MFA is supplied via `-e AWS_AI_MFA_TOKEN` on retry, not from stdin, so a fully non-interactive `docker run --rm` (no TTY, no stdin attach) is enough.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success — AWS command executed correctly. |
| `1` | Generic error — STS failure, validation error, AWS CLI error, or invalid MFA token. |
| `2` | **MFA required** — Unattended mode without cached session and no `AWS_AI_MFA_TOKEN` provided. Stderr includes `AWS_AI_MFA_REQUIRED=1`. |

## Execution flow

### 1. Prime credentials (first time or after expiration)

Always use unattended mode. If MFA is needed, the helper exits with code `2`.

```bash
docker run --rm \
  -v ~/.aws:/home/user/.aws \
  --env-file ~/.aws-ai/.env \
  -e AWS_AI_UNATTENDED=true \
  karibu/aws-ai:latest sts get-caller-identity
```

**If exit code is `2`:**
1. Ask the user for their MFA code from their authenticator app. Do not ask them to paste it in chat.
2. Retry with the token provided via environment variable:

```bash
docker run --rm \
  -v ~/.aws:/home/user/.aws \
  --env-file ~/.aws-ai/.env \
  -e AWS_AI_UNATTENDED=true \
  -e AWS_AI_MFA_TOKEN=123456 \
  karibu/aws-ai:latest sts get-caller-identity
```

After successful priming, credentials are cached for the session duration.

### 2. Run AWS operations

Once primed (session cached), execute AWS commands in unattended mode:

```bash
docker run --rm \
  -v ~/.aws:/home/user/.aws \
  --env-file ~/.aws-ai/.env \
  -e AWS_AI_UNATTENDED=true \
  karibu/aws-ai:latest ec2 describe-instances
```

**Note:** Always include `-e AWS_AI_UNATTENDED=true` in every invocation. The helper will use cached credentials if valid; if expired, it will exit with code `2` and you must re-prime as described above.

### 3. Session refresh

Temporary STS sessions expire (duration configurable via `AWS_AI_SESSION_DURATION_SECONDS`, default 900 seconds). Track session age.

At 2 minutes before expiration (or immediately after detecting exit code `2` on any command):
1. Re-prime using the flow in step 1 (unattended mode, handle MFA code `2` if needed).
2. Only after successful re-priming, continue with AWS operations.

## Error handling

### MFA/session failures

If output indicates MFA/session issues (`MultiFactorAuthentication failed`, expired session token, invalid session) **without** naming a denied API action like `service:Action`:
- Re-prime with `sts get-caller-identity` using unattended mode.
- Retry the original command once.
- Do not confuse these with IAM permission errors.

### Missing IAM permissions

If AWS returns `AccessDenied`, `UnauthorizedOperation`, `not authorized to perform`, or `is not authorized to perform` **and** the message names one or more API actions (e.g., `ec2:DescribeInstances`, `iam:GetRole`, `s3:GetObject`):
- Treat as insufficient policy on the assumed role.
- Tell the user exactly which `Action`(s) to allow in the IAM policy attached to that role.
- If the error includes a resource ARN, provide a minimal `Statement` example (`Action` + `Resource` / `Condition` as appropriate).
- If the message does not list the action, infer it from the CLI subcommand (e.g., `aws ec2 describe-instances` → `ec2:DescribeInstances`) and state any uncertainty.

### Credentials persistence failures

If credential caching fails:
- Continue with the current command result.
- Warn that subsequent commands may require MFA re-priming.

## Security guidelines

- Do not expose MFA codes, session tokens, or secret values in responses.
- Never ask users to paste MFA codes in chat. For the retry, they can export the code in their shell and pass `-e AWS_AI_MFA_TOKEN` (still without `-i`/`-it`).
- Summarize command outcomes clearly instead of dumping raw logs unless explicitly requested.
- `AWS_AI_MFA_TOKEN` is a single-use, short-lived value. Do not store it in `.env` or commit it.

## Notes for human users (documented in README)

Human users can use interactive mode (`-it`) for manual MFA entry. This skill focuses on agent-driven unattended execution only. Refer to the repository README for human-interactive usage patterns.
