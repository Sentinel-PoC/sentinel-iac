# keycloak-backup container image
# Layers 1+2 of the three-layer Keycloak backup procedure (OPS-632)
#
# Layer 1: pg_dump via kubectl exec into postgresql pod (bypasses NetworkPolicy)
# Layer 2: kcadm.sh realm JSON export via kubectl exec into keycloak pod
# Upload:  MinIO via mc client
#
# Build: docker build -t harbor.208.haist.farm/sentinel/keycloak-backup:v1 .
# Push:  docker push harbor.208.haist.farm/sentinel/keycloak-backup:v1

FROM alpine:3.19

ARG KUBECTL_VERSION=v1.29.3

RUN apk add --no-cache \
    postgresql16-client \
    curl \
    jq \
    bash \
    ca-certificates \
    openssl

# kubectl — used to exec into pods without direct pod-to-pod networking
RUN curl -sL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl && \
    kubectl version --client --short 2>/dev/null || kubectl version --client

# mc (MinIO client) — for S3 uploads
RUN curl -sL https://dl.min.io/client/mc/release/linux-amd64/mc \
    -o /usr/local/bin/mc && \
    chmod +x /usr/local/bin/mc && \
    mc --version

COPY scripts/ /scripts/
RUN chmod +x /scripts/backup.sh

# Run as non-root user (SEC-79: DS-0002 — no root in containers)
RUN addgroup -S backup && adduser -S -G backup backup
USER backup

# /tmp is the workspace; will be mounted as emptyDir in CronJob
WORKDIR /tmp

ENTRYPOINT ["/scripts/backup.sh"]
