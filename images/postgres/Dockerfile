FROM ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        barman-cli-cloud \
    && rm -rf /var/lib/apt/lists/*

USER postgres