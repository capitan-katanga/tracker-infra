# tracker-infra

Infraestructura compartida de desarrollo del expense tracker: Postgres, stack LGTM y Keycloak. Cuando el
proyecto pase a monorepo (ADR-008), esta carpeta se mueve tal cual a `infra/`.

## Uso

```bash
cp .env.example .env          # una vez; valores solo para dev
docker compose up -d          # todo
docker compose up -d keycloak # una parte (trae postgres por depends_on)
docker compose ps             # los 3 deben quedar healthy
```

Los servicios Spring con `spring-boot-docker-compose` (hoy `crud-tracker`) lo levantan solos con
`spring.docker.compose.file: ../tracker-infra/compose.yaml`, así que este repo se clona al lado de ellos.

## Organización

`compose.yaml` solo hace `include:` de un fragmento por componente. Cada fragmento vive en su carpeta junto
a sus archivos, y sus paths relativos resuelven contra esa carpeta. Todos comparten el proyecto
`tracker-infra` y su red, así que se ven por nombre de servicio (`postgres`, `keycloak`, `grafana-lgtm`).
Un componente nuevo (Kafka, Redis, MinIO) suma su carpeta y una línea en `include:`.

| Carpeta | Servicio | Puertos (host) |
|---|---|---|
| `postgres/` | `postgres` (pgvector/pgvector:pg17, DB `ExpenseTracker` (schemas `transactional`, `receipt_parser`, `extensions`) + DB `keycloak`) | 5332 |
| `observability/` | `grafana-lgtm` (grafana/otel-lgtm) | 3001 (Grafana), 4317 (OTLP gRPC), 4318 (OTLP HTTP) |
| `keycloak/` | `keycloak` (26.8.1, `start-dev`) | 8180 (admin en `/admin`, usuario `admin`) |

## Usuarios por servicio (ADR-009)

> **Recrear el volumen (FEAT-002).** Una vez, después de actualizar este repo:
> `docker compose down -v && docker compose up -d`. Se pierden las tablas viejas (`public.*` de
> crud-tracker, schema `ocr_service`) y la DB `keycloak`. El realm se reimporta del JSON, pero
> cualquier cambio manual en Keycloak se pierde.

Cada servicio tiene su rol y su schema dentro de `ExpenseTracker`. Los crea `postgres/init/02-services.sh`
como superusuario; el superusuario (`POSTGRES_USER`) no lo usa ningún servicio.

| Rol | Schema (dueño) | Password (`.env`) | `search_path` |
|---|---|---|---|
| `transactional` | `transactional` | `TRANSACTIONAL_DB_PASSWORD` | `transactional` |
| `receipt_parser` | `receipt_parser` | `RECEIPT_PARSER_DB_PASSWORD` | `receipt_parser, extensions` |

- Solo los roles de servicio tienen CONNECT a `ExpenseTracker` (`keycloak` no) y nadie más que el
  superusuario puede crear en `public`, que queda vacío.
- La extensión `vector` vive en el schema `extensions`, con USAGE solo para `receipt_parser`.
- Flyway de cada servicio corre con su rol y no crea schemas: si el schema no existe, el arranque falla.
- El script es idempotente. Para sumar un servicio sin borrar el volumen, agregar su bloque y
  re-ejecutarlo: `docker compose exec postgres bash /docker-entrypoint-initdb.d/02-services.sh`.
- No cambia passwords de roles que ya existen; para eso, `ALTER ROLE <rol> PASSWORD '...'`.

## Realm `expense-tracker`

Se importa al arrancar desde `keycloak/realms/expense-tracker-realm.json`. Los secretos son placeholders
`${VAR}` que Keycloak resuelve con el entorno del contenedor, así que el JSON no guarda ninguno.

- **`api-gateway`**: client confidencial con Authorization Code + PKCE S256 obligatorio (ADR-002).
  Redirect `http://localhost:8090/login/oauth2/code/keycloak`, para el Gateway en el 8090.
- **`expense-manager`**: client confidencial, solo Client Credentials. Su token lleva
  `scope=transactions:write-on-behalf` y `aud=transactional` (ADR-005).
- **Client scope `transactions:write-on-behalf`**: tiene el audience mapper a `transactional` y lo usa
  solo `expense-manager`.
- **Usuario `demo`**: password `KEYCLOAK_DEMO_USER_PASSWORD`, solo para probar el login.

Endpoints: issuer `http://localhost:8180/realms/expense-tracker`, discovery en
`/realms/expense-tracker/.well-known/openid-configuration`.

```bash
# Token M2M de expense-manager
curl -s -u expense-manager:$EXPENSE_MANAGER_CLIENT_SECRET -d grant_type=client_credentials \
  http://localhost:8180/realms/expense-tracker/protocol/openid-connect/token
```

## Trampas

- **Client scopes built-in en el JSON.** Si un realm importado declara `clientScopes`, Keycloak no crea los
  de fábrica (`basic`, `profile`, `email`, `roles`, `service_account`…), y sin `basic` el token pierde
  `sub`. Por eso el JSON los incluye todos, tal como los genera la 26.8.1, junto a
  `defaultDefaultClientScopes` y `defaultOptionalClientScopes`. Si se actualiza Keycloak, conviene
  regenerarlos desde un realm vacío.
- **El issuer está fijo.** `KC_HOSTNAME=http://localhost:8180` hace que el `iss` sea siempre
  `localhost:8180`. Desde el host funciona. Un servicio que corra en un contenedor no resuelve ese host
  para bajar el JWKS: va a necesitar `jwk-set-uri` hacia `http://keycloak:8080/...` (y
  `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true`) sin dejar de validar el issuer `localhost:8180`.
- **`--import-realm` no pisa un realm que ya existe** (estrategia `IGNORE_EXISTING`). Para aplicar
  cambios del JSON, borrar el realm (consola admin o
  `docker compose exec keycloak /opt/keycloak/bin/kcadm.sh delete realms/expense-tracker` después de
  `kcadm.sh config credentials`) y hacer `docker compose restart keycloak`. La alternativa es
  `docker compose down -v`, que también borra Postgres.
- **Los scripts de `postgres/init/` solo corren con el volumen vacío.** Si el volumen `postgres-data` ya
  existe, la DB `keycloak` no se crea sola.
- **Arranque más lento.** Spring Boot hace `docker compose up --wait`, que también espera el healthcheck
  de Keycloak (unos 30 s en frío). Keycloak y Postgres llevan el label `org.springframework.boot.ignore`:
  en Postgres evita que Boot le cree un `JdbcConnectionDetails` con el superusuario, que pisaría
  `spring.datasource.*`. La espera la sigue dando `up --wait` por healthcheck.
- **Si un init script falla, el data dir queda inicializado** y los scripts no vuelven a correr: hay que
  hacer `docker compose down -v` de nuevo. Por eso el compose exige las passwords de los roles (`:?`)
  antes de crear el contenedor.
- **`psql` por socket local entra por `trust`** dentro del contenedor. Para probar passwords hay que usar
  `-h postgres` (red de Docker, `scram-sha-256`).
- **La imagen de Keycloak no trae curl.** El healthcheck consulta `/health/ready` del puerto de
  management (9000) por `/dev/tcp`.
