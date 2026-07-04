#!/bin/sh
# entrypoint.sh — render the mosquitto config from a template, injecting secrets
# from the environment, then start the broker.
#
# Two supported modes:
#   1. Secret-injected (preferred): set REDIS_PASSWORD. The template at
#      $MOSQ_TEMPLATE is rendered to $MOSQ_CONF with ${REDIS_PASSWORD}
#      substituted. No plaintext secret is ever baked into the image or repo.
#   2. Legacy override: leave REDIS_PASSWORD unset and volume-mount a fully
#      rendered config at $MOSQ_CONF. It is used as-is.
#
# If neither a secret+template nor a mounted config is present, we fail loudly
# instead of silently starting with a bad/placeholder credential.
set -eu

MOSQ_CONF="${MOSQ_CONF:-/etc/mosquitto/mosquitto.conf}"
MOSQ_TEMPLATE="${MOSQ_TEMPLATE:-/etc/mosquitto/mosquitto.conf.template}"

if [ -n "${REDIS_PASSWORD:-}" ]; then
    if [ ! -f "$MOSQ_TEMPLATE" ]; then
        echo "[entrypoint] ERROR: REDIS_PASSWORD is set but template $MOSQ_TEMPLATE is missing" >&2
        exit 1
    fi
    # Only substitute REDIS_PASSWORD so other $-tokens in the config survive verbatim.
    envsubst '${REDIS_PASSWORD}' < "$MOSQ_TEMPLATE" > "$MOSQ_CONF"
    echo "[entrypoint] Rendered $MOSQ_CONF from $MOSQ_TEMPLATE"
elif [ -f "$MOSQ_CONF" ]; then
    echo "[entrypoint] REDIS_PASSWORD unset; using pre-provided $MOSQ_CONF as-is"
else
    echo "[entrypoint] ERROR: set REDIS_PASSWORD (to render $MOSQ_TEMPLATE) or mount a config at $MOSQ_CONF" >&2
    exit 1
fi

exec /usr/sbin/mosquitto -c "$MOSQ_CONF"
