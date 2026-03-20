FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        awscli \
        bash \
        jq \
        ca-certificates \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 -s /bin/bash user && \
    mkdir -p /home/user/.aws/.cache/aws_ai && \
    chown -R 1000:1000 /home/user/.aws

WORKDIR /app

COPY aws_ai.sh /app/aws_ai.sh
COPY docker-entrypoint.sh /app/docker-entrypoint.sh

RUN chmod +x /app/aws_ai.sh /app/docker-entrypoint.sh

ENV HOME=/home/user

USER user

ENTRYPOINT ["/app/docker-entrypoint.sh"]
