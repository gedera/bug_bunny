# docs/_index.md — Documentation Manifest

This file is the source of truth for the `docs/` directory structure.
It is read by the `/release` command to know which files to generate or update.

---

## Human documentation (developers integrating BugBunny)

| File | Purpose |
|---|---|
| `concepts.md` | AMQP in 5 min, architecture diagram, RPC vs fire-and-forget, connection pool |
| `howto/routing.md` | Routes DSL: `resources`, `namespace`, `member`, `collection`, `recognize` |
| `howto/controller.md` | `params`, `before_action`, `after_action`, `around_action`, `rescue_from`, `render` |
| `howto/resource.md` | CRUD methods, typed vs dynamic attributes, dirty tracking, validations, `.with` |
| `howto/middleware_client.md` | Client-side middlewares: built-ins, custom, usage in Client and Resource |
| `howto/middleware_consumer.md` | Consumer-side middlewares: execution order, writing, registering |
| `howto/tracing.md` | Trace context propagation: `rpc_reply_headers`, `on_rpc_reply`, consumer middleware |
| `howto/rails.md` | Full Rails setup: initializer, connection pool, Zeitwerk, Puma, Sidekiq, K8s health checks |
| `howto/testing.md` | Bunny doubles, unit tests for controllers/middleware, integration helper |

These files are referenced by `README.md`. Update them before updating the README.

---

## AI documentation (agents consuming or maintaining BugBunny)

Managed by `docs/ai/_index.md`. See that file for the full manifest and audience breakdown.

| File | Audience | Purpose |
|---|---|---|
| `ai/_index.md` | internal + external | Manifest: version, profile, file index |
| `ai/glossary.md` | internal + external | Domain terms with precise definitions |
| `ai/architecture.md` | internal | Internal patterns, component map, data flows |
| `ai/api.md` | external | Public API contracts |
| `ai/faq_internal.md` | internal | Q&A for gem maintainers |
| `ai/faq_external.md` | external | Q&A for gem integrators |
| `ai/antipatterns.md` | internal + external | What NOT to do and why |
| `ai/errors.md` | external | All exceptions with cause and resolution |

---

## Update rules for `/release`

1. Run tests first. If they fail, stop.
2. Read this file to discover all files to update.
3. For each file in **Human documentation**: update only sections affected by the changes in this release.
4. For each file in **AI documentation**: update only sections affected by the changes. Update `version` in `ai/_index.md`.
5. Update `README.md` last — it depends on `docs/howto/` being up to date.
6. Show the full diff to the developer and wait for approval before touching version or CHANGELOG.
