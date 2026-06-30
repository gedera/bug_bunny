# Test — bug_bunny

> meta: artefacto test · RFC-013 · generado `arch-structure` (§a-§d) +
> `arch-enrich` (§e-§h) · anclado a `24ea397`, `Rakefile`, `bug_bunny.gemspec`,
> `spec/spec_helper.rb`, `spec/support/integration_helper.rb`,
> `.github/workflows/main.yml`, `CHANGELOG.md` · fecha 2026-06-30 · cobertura:
> §a-§d (estructura) + §e-§h (enrich, anclado a specs/CHANGELOG) completas.

## 1. Resumen

Suite principal **RSpec** (`spec/`, 22 specs: 15 unit + 7 integration). Tarea
`:test` legacy de **Minitest** (`test/`, 2 archivos) fuera del default y del CI.
CI corre `bundle exec rake` (= `:spec`) en Ruby 3.4.4. Sin coverage tool
configurado.

## 2. Cuerpo

### a. Suites, frameworks y niveles

| framework | dir | nivel | nº | propósito |
|---|---|---|---|---|
| **RSpec** `~> 3.0` | `spec/unit/` | unit | 15 | client/session pool, configuration, consumer, producer, controller, raise_error, remote_error, request, route, observability, otel, resource, middleware |
| **RSpec** | `spec/integration/` | integration | 7 | client, consumer_middleware, controller, error_handling, infrastructure, publisher_confirms, resource — **requieren RabbitMQ real** (usan `BugBunny.create_connection` + pool) |
| **Minitest** `~> 5.0` (+ `mocha`, `minitest-reporters`) | `test/integration/` | integration (legacy) | 2 | `manual_client_test.rb`, `infrastructure_test.rb` — tarea `:test`, **no** en default ni CI |

Sin tags declarados (`:slow`/`:js`) en la config de RSpec.

### b. Comando de corrida

| objetivo | comando | qué corre |
|---|---|---|
| default / CI | `bundle exec rake` | tarea `:spec` (toda la suite RSpec) — `Rakefile:` `task default: :spec` |
| solo unit | `bundle exec rake spec:unit` | `spec/unit/**/*_spec.rb` |
| solo integration | `bundle exec rake spec:integration` | `spec/integration/**/*_spec.rb` (requiere broker) |
| Minitest legacy | `bundle exec rake test` | `test/**/*_test.rb` |
| CI | `.github/workflows/main.yml` → `bundle exec rake` | matrix Ruby `3.4.4`, `ruby/setup-ruby@v1` + `bundler-cache`, on push `main` + PR |

> Todas las tareas RSpec corren con `--require spec_helper` (`Rakefile`).

### c. Fixtures / Factories

- **Sin FactoryBot ni fixtures YAML.** El setup vive en `spec/spec_helper.rb`:
  configura `BugBunny` (host/user/pass desde ENV con default `guest`), arma un
  `ConnectionPool` de test (`TEST_POOL`, size 5) y declara rutas globales para
  todos los specs (`resources :ping/:node/:user`, `get 'around'/'rescue'/'boom'/
  'echo'`, `post 'events'`).
- **Carga `.env`** si existe (parse manual, `spec_helper.rb`).
- **Soporte:** `spec/support/integration_helper.rb` (helpers + `TEST_WORKER_QUEUE_OPTS`
  para colas efímeras), `spec/support/bunny_mocks.rb` (mocks de Bunny para unit).
- `exchange_options = { durable: false, auto_delete: true }` → exchanges efímeros
  en test.

### d. Configuración de coverage

**n/a** — sin SimpleCov ni `.simplecov` ni `SimpleCov.start` en el repo. No hay
umbral de coverage declarado.

### e. Gaps de cobertura

- **Integration specs no corren en CI:** `main.yml` no declara servicio RabbitMQ;
  las 7 integration specs **se skipean** vía `rabbitmq_available?`
  (`spec/support/integration_helper.rb:14`, ver `publisher_confirms_spec.rb:10`).
  En CI solo se ejercitan las **15 unit specs** → el contrato AMQP real (publish/
  consume/confirms contra broker) **no se valida en pipeline**, solo localmente
  con broker. Gap relevante.
- **Sin medición de cobertura:** no hay SimpleCov ni umbral → la cobertura no está
  cuantificada (no se sabe el % de líneas ejercidas).

### f. Contract-assessment

¿Los tests cubren los contratos públicos? (RFC-020/018/012/003)

| contrato | specs que lo cubren | veredicto |
|---|---|---|
| **Errores RFC-020** (status→excepción, materia prima) | `raise_error_spec`, `remote_error_spec`, `communication_error_wrapping_spec`, `error_handling_spec` (integration) | **bien cubierto** (unit) |
| **Consumed RFC-018** (Bunny::Exception→`CommunicationError`) | `communication_error_wrapping_spec`, `client_session_pool_spec` | cubierto (unit) |
| **Config RFC-012** (validaciones de `Configuration`) | `configuration_spec` | cubierto |
| **Confirms** (`PublishNacked`/`PublishUnroutable`) | `producer_spec`, `publisher_confirms_spec` (integration) | parcial en CI (la parte integration skipea sin broker) |
| **Operaciones/routing** (RFC-003, capa F2) | `route_spec`, `request_spec`, `controller_spec`, `controller_after_action_spec`, `resource_spec` | cubierto (unit) |

### g. Link a incidente → test de regresión

| incidente | test de regresión | ancla |
|---|---|---|
| **#52** (`status`/`raw_response` en toda la jerarquía + hardening de `format_error_message`) | `raise_error_spec` — comentarios explícitos "Alcance issue #52" | `spec/unit/raise_error_spec.rb:59,120,169` |
| **#49** (leak de `Bunny::TCPConnectionFailedForAllHosts` en `try_create`) | `communication_error_wrapping_spec` — "Client#publish — TCP fail en try_create (issue #49 caso original)" | `spec/unit/communication_error_wrapping_spec.rb:41` |

### h. PII en fixtures / factories

- **Sin PII.** No hay fixtures con datos personales: `spec_helper` usa
  placeholders (`guest`/`localhost`), las rutas de test son `ping`/`node`/`user`
  **sin payloads de datos reales**, y `bunny_mocks.rb` mockea el driver. Cruza
  RFC-026: nada que clasificar/anonimizar. `confidence: high`.

## 3. Inferencias

- **Doble framework:** RSpec es el primario (default + CI); Minitest (`test/`,
  `mocha`, `minitest-reporters` en gemspec) es **legacy** — el comentario del
  `Rakefile` lo declara explícito ("tests de integración legacy de Minitest").
  `confidence: high`.
- ~~CI on `master` pero la rama principal es `main` (drift de naming)~~ →
  **resuelto** (`main.yml` ahora dispara `push: branches: [main]`). El trigger
  `push` corre en la rama por default; `pull_request` cubre los PRs.

## 4. Cobertura y fronteras

- §a-§d (estructura) + §e-§h (enrich, anclado a specs/CHANGELOG) **completas**.
- **Integration specs requieren un RabbitMQ vivo** y se skipean sin broker (§e) —
  por eso no se ejercitan en CI.
- **Contenido de cada test case** queda en el código, no se inventaria acá.
