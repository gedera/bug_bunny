# AGENTS.md — bug_bunny

Entrada de harness para agentes que trabajan en este repo. Para el contrato de
proyecto y convenciones de equipo, ver `CLAUDE.md`. Para la entrada humana, ver
`README.md`; para la entrada agente version-locked, `skill/SKILL.md`.

## Mapa de conocimiento

> Stanza RFC-008 r2 — **indexa, no duplica**. Cada fila apunta al artefacto de
> detalle que es la fuente de verdad de esa capa. Leé el artefacto antes de
> responder sobre su capa.

| capa | artefacto | estado | qué responde |
|---|---|---|---|
| Comportamiento | `docs/behavior/behavior.md` | completo (6 flujos) | secuencias de publish/RPC/consume/confirms, contrato de error-wrapping |
| Glosario | `docs/glossary/glossary.md` | parcial (acreta por PR) | término de negocio → binding físico en `lib/` |
| Errores | `docs/errors/errors.md` | completo (§a/b/d estructura + §c política inferida) | jerarquía de excepciones públicas, mapeo `status→excepción`, shape del payload, política retry |
| Configuración | `docs/config/configuracion.md` | completo (estructura + enrich §f/g/h) | opciones de `Configuration`, defaults, failure-mode/threading, inyecciones del `Railtie`, ENV sugeridas |
| Dependencias consumidas | `docs/consumed/rabbitmq.md` | completo (estructura + enrich §c/e) | qué consume del broker RabbitMQ vía `bunny`, mapeo error-Bunny→excepción, retry/degradación |
| Test | `docs/test/test.md` | completo (estructura + enrich §e-h) | suites RSpec/Minitest, CI, contract-assessment, link a incidentes (#49/#52) |
| Release | `docs/release/release.md` | completo | patrón gema-tag, versionado, publish a RubyGems |
| Datos | — | n/a | gema sin DB |
| Operaciones / Interfaz / Topología | — | dev-structure F2 no implementado | contrato embebido en `README.md`/`skill/SKILL.md` (interim RFC-008 §2) |
| Eventos (RFC-005) | — | n/a | la gema es el transporte de eventos, no declara un catálogo de eventos de dominio propio |
| Seguridad (RFC-017) | — | n/a | sin authn/authz propias; el único control es `SecurityError` (validación de herencia de controladores), cubierto en `docs/errors/` |
| Multi-tenancy (RFC-023) | — | n/a | sin modelo de tenant propio; el aislamiento es por `vhost` de RabbitMQ (config) |
| Data-lifecycle (RFC-026) | — | n/a | gema sin DB ni datos persistidos propios |

## Enriquecimiento

Completo en errors (§c), config (§f/g/h), consumed (§c/e) y test (§e-h), anclado
a YARD/specs/CHANGELOG. Pendiente de **verificación humana** (inferencias):

- `docs/errors/errors.md` §c — política retry inferida de HTTP/AMQP (`confidence:medium`); confirmar idempotencia de re-publish y caso `RemoteError` con consumidores reales.
- `docs/glossary/glossary.md` — parcial por diseño, acreta por PR.

## Convenciones operativas

- Ruby: `.ruby-version` · gemas: `Gemfile.lock` · manager: chruby + Bundler.
- Antes de commitear: `bundle exec rubocop -a` (base `rubocop-rails-omakase`),
  `bundle exec rspec`, YARD incremental (`bundle exec yard stats --list-undoc`).
- Releases: `/gem-release` (el GitHub Action publica a RubyGems al pushear tag `v*`).
- Doc por-PR: si tocás una capa, mové su artefacto en el mismo PR (régimen RFC-001).
