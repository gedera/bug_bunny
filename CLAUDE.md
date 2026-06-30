# BugBunny — Project Intelligence

## ¿Qué es BugBunny?

BugBunny es una gema Ruby que implementa una capa de enrutamiento RESTful sobre AMQP (RabbitMQ). Permite que microservicios se comuniquen via RabbitMQ usando patrones familiares de HTTP: verbos (GET, POST, PUT, DELETE), controladores, rutas declarativas, RPC síncrono y fire-and-forget.

**Problema que resuelve:** Eliminar el acoplamiento directo entre microservicios via HTTP, usando RabbitMQ como bus de mensajes con la misma ergonomía de un framework web.

## Documentación

- **Modelo `dev-*` (RFC-001):** artefactos de detalle en `docs/<capa>/`
  (`data/`, `glossary/`, `behavior/`); compuestos (`README.md` humano,
  `skill/SKILL.md` agente version-locked) **indexan, no duplican**.
  Artefactos generados por `dev-structure` / `dev-enrich`; compuestos por
  `dev-compose`. Verificación humana antes de commitear.
- **Estado actual:**
  - `docs/data` = n/a (gema sin DB, declarado solo en índice).
  - `docs/behavior` completo (6 flujos, backfill on-demand).
  - `docs/glossary` parcial (acreta por PR).
  - `docs/errors` (RFC-020) completo: §a/§b/§d (estructura) + §c política
    (enrich, **inferida** de HTTP/AMQP, verificación humana pendiente).
  - `docs/config` (RFC-012) completo: inventario §a-§e/§i + enrich §f/§g/§h
    (failure-mode/threading, anclado a YARD); §j n/a.
  - `docs/consumed` (RFC-018) RabbitMQ-vía-`bunny` completo: §a/§b/§d + enrich
    §c/§e (retry/backoff/degradación, anclado a `consumer.rb`).
  - `docs/test` (RFC-013) completo: estructura §a-§d + enrich §e-§h
    (contract-assessment, link a incidentes #49/#52, gaps de CI).
  - operaciones/interfaz/topología (RFC-003/004/006) = dev-structure F2 no
    implementado (interim RFC-008 §2).
- **Para agentes AI**: `skill/SKILL.md` (empaquetada en el `.gem`) +
  `skill/references/`.
- **Coexistencia transitoria con destino pendiente (RFC-008 §2 — interim de
  migración):** contrato/arquitectura sigue embebido en
  `README.md`/`skill/SKILL.md` y las guías how-to viven en `skill/references/`
  (pre-estándar) porque su capa destino (operaciones/interfaz/topología) es
  dev-structure F2 no implementado. Por norma: no se fabrica la capa, no se
  borra el contrato sin destino; migra cuando F2 entregue, mismo PR. Estado
  transitorio declarado en el índice de artefactos. Origen del gap (resuelto,
  normado): `sequre/ai_knowledge#95`.

## Knowledge Base
- Las skills en `.agents/skills/` incluyen conocimiento de dependencias.
- Leer la skill de una dependencia ANTES de responder sobre ella.
- Rebuild: `wispro-agent sync`

### Entorno
- Versión de Ruby: leer `.ruby-version`
- Versión de Rails y gemas: leer `Gemfile.lock`
- Gestor de Ruby: chruby (no usar rvm ni rbenv)
- Package manager: Bundler

### RuboCop
- Usamos rubocop-rails-omakase como base.
- Correr `bundle exec rubocop -a` antes de commitear.
- No deshabilitar cops sin justificación en el PR.

### YARD
- Documentación incremental: si tocás un método, documentalo con YARD.
- Consultar la skill `yard` para tags y tipos correctos.
- Verificar cobertura: `bundle exec yard stats --list-undoc`

### Testing
- Framework: RSpec
- Correr: `bundle exec rspec`
- Todo código nuevo debe tener tests.

### Releases o Nuevas versiones
- Usar `/gem-release` para publicar nuevas versiones.
- El GitHub Action publica a RubyGems automáticamente al pushear un tag `v*`.
