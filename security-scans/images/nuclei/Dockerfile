# Nuclei with its template set baked in at a pinned release, so a scan is
# reproducible and the evidence manifest can name the exact templates
# (security-scans/scripts). Renovate bumps both pins.
FROM docker.io/projectdiscovery/nuclei:v3.11.1@sha256:582d5546902e67052097cb2d07296c642d50a1afc5e44623cb038845df9a32eb

ARG TEMPLATES_VERSION=v10.5.2
ADD --checksum=sha256:016b7abbf931d4d1a851a5a568e44510dc61691dc8a5202e3b24e701515ec574 \
    https://github.com/projectdiscovery/nuclei-templates/archive/refs/tags/${TEMPLATES_VERSION}.tar.gz /tmp/templates.tgz
RUN mkdir -p /opt/nuclei-templates \
 && tar -xzf /tmp/templates.tgz -C /opt/nuclei-templates --strip-components=1 \
 && rm /tmp/templates.tgz \
 && echo "${TEMPLATES_VERSION}" > /opt/nuclei-templates/VERSION

USER 65532:65532
