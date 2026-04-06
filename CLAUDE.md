# BugBunny — Project Intelligence

## ¿Qué es BugBunny?

BugBunny es una gema Ruby que implementa una capa de enrutamiento RESTful sobre AMQP (RabbitMQ). Permite que microservicios se comuniquen via RabbitMQ usando patrones familiares de HTTP: verbos (GET, POST, PUT, DELETE), controladores, rutas declarativas, RPC síncrono y fire-and-forget.

**Problema que resuelve:** Eliminar el acoplamiento directo entre microservicios via HTTP, usando RabbitMQ como bus de mensajes con la misma ergonomía de un framework web.

## Documentación

- **Para humanos**: `docs/` (5 archivos) + `README.md`. Ver README para índice.
- **Para agentes AI**: `skill/SKILL.md` + `skill/references/`. Es la skill empaquetada que otros proyectos consumen via `skill-manager sync`.
- **Nunca referenciar `skill/` desde `docs/` o `README.md`** — son audiencias distintas.

## Knowledge Base
- Las skills en `.agents/skills/` incluyen conocimiento de dependencias.
- Leer la skill de una dependencia ANTES de responder sobre ella.
- Rebuild: `ruby .agents/skills/skill-manager/scripts/sync.rb`

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
