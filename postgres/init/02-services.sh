#!/bin/bash
# Rol y schema propios por servicio dentro de ExpenseTracker (ADR-009) y su CONNECTION LIMIT (ADR-013).
# Flyway de cada servicio corre con su rol y solo crea objetos dentro de su schema.
# Idempotente: se puede re-ejecutar sobre un volumen existente (no cambia passwords de roles ya creados).
set -euo pipefail
: "${TRANSACTIONAL_DB_PASSWORD:?falta TRANSACTIONAL_DB_PASSWORD (.env)}"
: "${RECEIPT_PARSER_DB_PASSWORD:?falta RECEIPT_PARSER_DB_PASSWORD (.env)}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v transactional_password="$TRANSACTIONAL_DB_PASSWORD" \
  -v receipt_parser_password="$RECEIPT_PARSER_DB_PASSWORD" <<-'SQL'
	-- Nadie crea en public ni se conecta a la DB sin GRANT explícito
	REVOKE CREATE ON SCHEMA public FROM PUBLIC;
	REVOKE ALL ON DATABASE "ExpenseTracker" FROM PUBLIC;

	-- Extensiones: requieren superusuario; viven fuera de los schemas de servicio
	CREATE SCHEMA IF NOT EXISTS extensions;
	CREATE EXTENSION IF NOT EXISTS vector SCHEMA extensions;

	-- Roles (CREATE ROLE no tiene IF NOT EXISTS)
	SELECT format('CREATE ROLE transactional LOGIN PASSWORD %L', :'transactional_password')
	 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'transactional') \gexec
	SELECT format('CREATE ROLE receipt_parser LOGIN PASSWORD %L', :'receipt_parser_password')
	 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'receipt_parser') \gexec

	-- transactional
	GRANT CONNECT ON DATABASE "ExpenseTracker" TO transactional;
	CREATE SCHEMA IF NOT EXISTS transactional AUTHORIZATION transactional;
	ALTER ROLE transactional IN DATABASE "ExpenseTracker" SET search_path = transactional;

	-- receipt_parser
	GRANT CONNECT ON DATABASE "ExpenseTracker" TO receipt_parser;
	CREATE SCHEMA IF NOT EXISTS receipt_parser AUTHORIZATION receipt_parser;
	GRANT USAGE ON SCHEMA extensions TO receipt_parser;
	ALTER ROLE receipt_parser IN DATABASE "ExpenseTracker" SET search_path = receipt_parser, extensions;

	-- Presupuesto de conexiones (ADR-013): límite = pool del servicio + 2 (psql o debug con su rol).
	-- Subir un <ROL>_DB_POOL_SIZE exige subir su límite acá y re-ejecutar el script.
	ALTER ROLE transactional CONNECTION LIMIT 12;
	ALTER ROLE receipt_parser CONNECTION LIMIT 7;
SQL
