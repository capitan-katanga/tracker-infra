#!/bin/bash
# Base y usuario propios de Keycloak, separados de ExpenseTracker.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v kc_password="$KEYCLOAK_DB_PASSWORD" <<-'SQL'
	CREATE ROLE keycloak LOGIN PASSWORD :'kc_password';
	CREATE DATABASE keycloak OWNER keycloak;
	REVOKE ALL ON DATABASE keycloak FROM PUBLIC;
SQL
