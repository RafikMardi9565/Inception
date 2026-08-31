#!/bin/sh
set -e

mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld

if [ ! -d /var/lib/mysql/mysql ]; then

	mariadb-install-db --user=mysql --datadir=/var/lib/mysql

	mysqld --user=mysql --skip-networking &
	pid=$!

	for i in $(seq 1 30); do
		if mariadb-admin ping --silent; then
			break
		fi
		sleep 1
	done

	MYSQL_PASSWORD=$(cat /run/secrets/db_password)
	MYSQL_ROOT_PASSWORD=$(cat /run/secrets/db_root_password)

	mariadb -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
SQL

	mariadb-admin -u root -p"${MYSQL_ROOT_PASSWORD}" shutdown
	wait $pid || true
fi

exec mysqld --user=mysql
