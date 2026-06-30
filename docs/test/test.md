# Test — bug_bunny

> meta: artefacto test · RFC-013 (estructural §a/§b/§c/§d) · generado
> `arch-structure` · anclado a `5eea236`, `Rakefile`, `bug_bunny.gemspec`,
> `spec/spec_helper.rb`, `.github/workflows/main.yml` · fecha 2026-06-30 ·
> cobertura: §a/§b/§c/§d completas; §e gaps · §f contract-assessment · §g
> link-incidente · §h PII sembrados `—` (→ `arch-enrich`).

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

### e/f/g/h. Enriquecimiento

`—` (gaps de cobertura · contract-assessment de RFC-003/018/020 · link a
incidente del que nació un test de regresión · PII en fixtures → `arch-enrich`,
RFC-013).

## 3. Inferencias

- **Doble framework:** RSpec es el primario (default + CI); Minitest (`test/`,
  `mocha`, `minitest-reporters` en gemspec) es **legacy** — el comentario del
  `Rakefile` lo declara explícito ("tests de integración legacy de Minitest").
  `confidence: high`.
- ~~CI on `master` pero la rama principal es `main` (drift de naming)~~ →
  **resuelto** (`main.yml` ahora dispara `push: branches: [main]`). El trigger
  `push` corre en la rama por default; `pull_request` cubre los PRs.

## 4. Cobertura y fronteras

- §a/§b/§c/§d **completas** al commit ancla; §e-§h sembrados `—`.
- **Integration specs requieren un RabbitMQ vivo** — no corren aislados sin
  broker. La evaluación de qué contratos públicos (RFC-003/018/020) cubren los
  tests es §f, fuera de structure.
- **Contenido de cada test case** queda en el código, no se inventaria acá.
