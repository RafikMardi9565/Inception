#!/bin/sh
set -e

if [ ! -f /etc/nginx/ssl/server.crt ]; then
	mkdir -p /etc/nginx/ssl
	openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
		-keyout /etc/nginx/ssl/server.key \
		-out /etc/nginx/ssl/server.crt \
		-subj "/C=FR/ST=Paris/L=Paris/O=42/OU=42/CN=rmardi.42.fr" \
		-addext "subjectAltName=DNS:rmardi.42.fr"
fi

exec nginx -g "daemon off;"
