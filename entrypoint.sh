#!/bin/bash
set -euo pipefail

INTERNAL_PORT=5173

: "${WEB_USER:=admin}"
: "${WEB_PASSWORD:?WEB_PASSWORD is required: without it anyone with the URL could spend your API keys}"

# An empty provider variable would shadow a key typed into the app's settings.
for v in $(compgen -e); do
  case "$v" in *_API_KEY|*_API_BASE_URL) [ -n "${!v}" ] || unset "$v" ;; esac
done

# Hashed per boot so the variable stays readable in Railway.
PASSWORD_HASH="$(caddy hash-password --plaintext "$WEB_PASSWORD")"
unset WEB_PASSWORD

cd /app
node_modules/.bin/vite preview --host 127.0.0.1 --port "$INTERNAL_PORT" --strictPort &
APP_PID=$!
CADDY_PID=
trap 'kill "$APP_PID" ${CADDY_PID:+"$CADDY_PID"} 2>/dev/null || true' TERM INT

echo "==> waiting for bolt.diy on 127.0.0.1:${INTERNAL_PORT}"
ready=
for _ in $(seq 1 240); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${INTERNAL_PORT}/" || true)"
  if [ "$code" = 200 ]; then ready=1; break; fi
  kill -0 "$APP_PID" 2>/dev/null || { echo "FATAL: bolt.diy exited during startup" >&2; exit 1; }
  sleep 1
done
[ -n "$ready" ] || { echo "FATAL: bolt.diy did not answer (last status ${code:-none})" >&2; exit 1; }

cat > /tmp/Caddyfile <<CADDY
{
	admin off
	auto_https off
	persist_config off
	servers {
		trusted_proxies static private_ranges
	}
}

:${PORT} {
	route {
		# For Railway's healthcheck, which sends no password. Caddy starts only after
		# bolt.diy answers, and the container exits if either dies.
		respond /healthz "ok" 200

		basic_auth {
			${WEB_USER} ${PASSWORD_HASH}
		}

		reverse_proxy 127.0.0.1:${INTERNAL_PORT} {
			# The server only answers for a localhost Host.
			header_up Host localhost:${INTERNAL_PORT}
			# Chat replies are streamed.
			flush_interval -1
		}
	}
}
CADDY
chmod 600 /tmp/Caddyfile

echo "==> bolt.diy is up on :${PORT}, login user ${WEB_USER}"
caddy run --config /tmp/Caddyfile --adapter caddyfile &
CADDY_PID=$!

status=0
wait -n "$APP_PID" "$CADDY_PID" || status=$?
echo "==> a supervised process exited (status ${status}); shutting down"
kill "$APP_PID" "$CADDY_PID" 2>/dev/null || true
exit "$status"
