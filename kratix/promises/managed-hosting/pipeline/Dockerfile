# Thin Kratix pipeline adapter — reads the Tenant object + POSTs the Restate
# reconcile. curl + yq only; runs non-root.
FROM alpine:3.20
RUN apk add --no-cache curl yq
COPY reconcile.sh /usr/local/bin/reconcile.sh
RUN chmod +x /usr/local/bin/reconcile.sh && adduser -D -u 1000 adapter
USER 1000
ENTRYPOINT ["/usr/local/bin/reconcile.sh"]
