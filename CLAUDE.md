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
- **Estado actual:** `docs/data` = n/a (gema sin DB, declarado solo en índice);
  `docs/glossary` parcial (acreta por PR); `docs/behavior` completo (6 flujos,
  backfill on-demand); operaciones/interfaz/topología = dev-structure F2 no
  implementado; `docs/errors` (RFC-020) **estructura completa** (§a inventario de
  excepciones + §b status→excepción + §d shape de payload; jerarquía bajo
  `BugBunny::Error`, #52 sumó `status`/`raw_response`), §c política sembrada `—`
  (pendiente de `arch-enrich`).
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
