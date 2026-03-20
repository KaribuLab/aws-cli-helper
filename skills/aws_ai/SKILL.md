---
name: skills/aws_ai
description: Run AWS commands through the aws_ai helper with MFA-aware session priming and refresh guidance for agents.
---

# skills/aws_ai

Use this skill to execute AWS operations through this repo's `aws_ai` CLI wrapper (local script or Docker image), keeping MFA/session flow predictable for agent-driven work.

## When to use

- User asks to run AWS CLI commands via this project helper.
- User wants the agent to operate AWS without installing AWS CLI locally.
- Session/MFA handling is needed (assume-role + temporary credentials).

## Instructions

1. Validate prerequisites before first command:
   - Confirm `.env` exists (or required env vars are present): `AWS_AI_PROFILE`, `AWS_AI_ASSUME_ROLE_ARN`, `AWS_AI_MFA_SERIAL_ARN`, `AWS_REGION`.
   - Prefer Docker flow when user requested no local dependencies:
     `docker run --rm -it -v ~/.aws:/home/user/.aws --env-file .env aws_ia <aws args>`

2. Prime credentials on first use by asking the user to run this exact command themselves:
   - `docker run --rm -it -v ~/.aws:/home/user/.aws --env-file .env aws_ia sts get-caller-identity`
   - If using local script instead of Docker:
     `./aws_ai.sh sts get-caller-identity`
   - Reason: this captures MFA once and stores temporary session credentials for later agent commands.

3. After priming, run requested AWS operations through the helper (not raw `aws`):
   - Docker: `docker run --rm -i -v ~/.aws:/home/user/.aws --env-file .env aws_ia <service> <operation> [flags]`
   - Local: `./aws_ai.sh <service> <operation> [flags]`

4. MFA refresh rule for agents (15-minute STS sessions):
   - Track the time when priming succeeded.
   - At 13 minutes (2 minutes before expiration), pause and ask the user to rerun:
     `docker run --rm -it -v ~/.aws:/home/user/.aws --env-file .env aws_ia sts get-caller-identity`
   - Resume automation only after that command succeeds.

5. Error-handling policy:
   - If helper output indicates MFA/session failure (`AccessDenied`, `MultiFactorAuthentication failed`, expired token), request re-priming with `sts get-caller-identity` and retry the original command once.
   - If credentials persistence fails, continue with current command result but warn that next commands may require MFA again.

6. Safety and output behavior:
   - Do not expose MFA codes, session tokens, or secret values in responses.
   - Summarize command outcomes clearly for the user instead of dumping raw logs unless explicitly requested.
