#!/bin/sh
set -e

MYSQL_PASSWORD=$(cat /run/secrets/db_password)
WP_ADMIN_PASSWORD=$(cat /run/secrets/wp_admin_password)
WP_USER_PASSWORD=$(cat /run/secrets/wp_user_password)

for i in $(seq 1 30); do
	if mariadb-admin -h mariadb -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" ping --silent; then
		break
	fi
	sleep 1
done

if [ ! -f /var/www/html/index.php ]; then
	wp core download --path=/var/www/html --allow-root
fi

if [ ! -f /var/www/html/wp-config.php ]; then
	wp config create \
		--dbname="${MYSQL_DATABASE}" \
		--dbuser="${MYSQL_USER}" \
		--dbpass="${MYSQL_PASSWORD}" \
		--dbhost=mariadb:3306 \
		--path=/var/www/html \
		--allow-root
fi

if ! wp core is-installed --path=/var/www/html --allow-root; then
	wp core install \
		--url="https://${DOMAIN_NAME}" \
		--title="Inception" \
		--admin_user="${WP_ADMIN_USER}" \
		--admin_password="${WP_ADMIN_PASSWORD}" \
		--admin_email="${WP_ADMIN_EMAIL}" \
		--skip-email \
		--path=/var/www/html \
		--allow-root
	wp user create "${WP_USER}" "${WP_USER_EMAIL}" \
		--role=author \
		--user_pass="${WP_USER_PASSWORD}" \
		--path=/var/www/html \
		--allow-root
fi

chown -R www-data:www-data /var/www/html

exec php-fpm8.2 -F
