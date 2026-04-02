---
type: knowledge_base
kind: gem
name: bug_bunny
version: 4.8.0
profile: full
language: ruby
generated_by: gem-ai-setup@1.0.0
audiences:
  - internal
  - external
files:
  - path: glossary.md
    audience: [internal, external]
  - path: architecture.md
    audience: [internal]
  - path: api.md
    audience: [external]
  - path: faq_internal.md
    audience: [internal]
  - path: faq_external.md
    audience: [external]
  - path: antipatterns.md
    audience: [internal, external]
  - path: errors.md
    audience: [external]
---

## What is BugBunny?

BugBunny is a Ruby gem that implements a RESTful routing layer over AMQP (RabbitMQ). It lets microservices communicate via RabbitMQ using familiar HTTP patterns: verbs (GET, POST, PUT, DELETE), controllers, declarative routes, synchronous RPC, and fire-and-forget.

**Problem solved:** Eliminates direct HTTP coupling between microservices. RabbitMQ acts as the message bus with the same ergonomics as a web framework.

## Version

4.8.0 — April 2026

## Key features in this version

- Namespace routing (`namespace :admin { resources :users }`)
- `after_action` filter (runs after action, not after `before_action` halts)
- `render(headers:)` — inject custom headers into RPC replies
- `Consumer#shutdown` — explicit graceful shutdown with health check cleanup
- `Configuration#validate!` — invoked automatically at end of `BugBunny.configure`
- Producer/Session caching per connection slot (prevents double-consumer AMQP error)
- Expanded `SENSITIVE_KEYS` filter in `safe_log`
- `ConsumerMiddleware::Stack` mutex for thread-safe registration

## How to use this knowledge base

- **Building an integration** → start with `api.md`, then `faq_external.md`
- **Debugging errors** → `errors.md`
- **Avoiding mistakes** → `antipatterns.md`
- **Understanding internals** → `architecture.md`, then `faq_internal.md`
- **Domain vocabulary** → `glossary.md`
