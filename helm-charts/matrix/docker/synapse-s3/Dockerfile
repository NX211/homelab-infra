# Synapse + synapse-s3-storage-provider.
#
# The base element-hq/synapse image does not ship the S3 storage provider, which
# the media_repository worker (and the future s3_media_upload cron) require.
#
# Build & push (GHCR) — run from this directory:
#   docker build --build-arg SYNAPSE_VERSION=1.155.0 \
#     -t ghcr.io/nx211/synapse-s3:1.155.0 .
#   echo "$GHCR_TOKEN" | docker login ghcr.io -u nx211 --password-stdin
#   docker push ghcr.io/nx211/synapse-s3:1.155.0
#
# Keep the tag in sync with matrix-synapse.image.tag in values.yaml and bump
# both together when upgrading Synapse.
ARG SYNAPSE_VERSION=1.155.0
FROM ghcr.io/element-hq/synapse:${SYNAPSE_VERSION}

# pip install needs root; the image entrypoint drops privileges at runtime.
USER root
RUN pip install --no-cache-dir synapse-s3-storage-provider
