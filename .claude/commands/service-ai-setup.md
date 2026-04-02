Generate or update the complete AI documentation suite for this microservice.

This skill is invoked automatically by `/pr`. It can also be run standalone.

The same quality standard as BugBunny's `docs/ai/` applies here — self-contained chunks, RAG-optimized, no introductory prose.

---

## Step 1 — Discover the current state

Read in order:
1. `docs/_index.md` — if it exists, lists all files and their purpose
2. `docs/ai/_index.md` — if it exists, current profile and file list
3. `CLAUDE.md` — service purpose, architecture, dependencies
4. `config/services.yml` — declared dependencies (other services this one talks to)
5. `config/routes.rb` or `config/initializers/bug_bunny_routes.rb` — what this service exposes

If `docs/ai/` does not exist yet, this is a **first-time generation**. Create from scratch.
If it exists, **update only the sections affected by the changes in this PR**.

---

## Step 2 — Profile

Microservices always use the **full profile** with `contracts.md` instead of `api.md`:

```
docs/ai/
  _index.md
  glossary.md
  architecture.md
  contracts.md      ← what this service exposes (queues, endpoints, events)
  faq_internal.md
  faq_external.md
  antipatterns.md
  errors.md
```

---

## Step 3 — Analyze the codebase

Read:
- `app/` — controllers, models, workers, services
- `config/` — routes, initializers, services.yml
- `lib/` — custom libraries
- `spec/` — usage patterns and edge cases
- `CHANGELOG.md` or git log — what changed in this PR

---

## Step 4 — Generate or update each file

Apply the same RAG optimization rules as `gem-ai-setup`:
1. Each section ≤ 400 tokens, self-contained
2. `faq_*.md` strict Q&A format, H3 question, answer ≤ 150 words
3. `glossary.md` one entry per term, 1-3 lines
4. `errors.md` one entry per error, cause + reproduction + resolution
5. No introductory prose

### `_index.md`

Frontmatter manifest. Use `kind: microservice` and `transports:` listing all transports used (bug_bunny, http, etc.). List every file with its audience.

```yaml
---
type: knowledge_base
kind: microservice
name: service_name
version: main        # microservices don't have semver — use branch or date
profile: full
language: ruby
audiences:
  - internal
  - external
transports:
  - bug_bunny        # list actual transports used
  - http
files:
  - path: glossary.md
    audience: [internal, external]
  - path: architecture.md
    audience: [internal]
  - path: contracts.md
    audience: [external]
  ...
---
```

### `glossary.md`

Domain terms specific to this service's business domain and technical patterns.

### `architecture.md`

Internal-facing. Include:
- Service responsibility (one paragraph)
- Component map
- Data flows for the main operations
- External dependencies and how they're used
- Background jobs and their triggers

### `contracts.md`

External-facing. The complete contract this service exposes. Include:

**BugBunny queues (if applicable):**
- Queue name, exchange, routing key, exchange type
- For each route: method, path, request format, response format, possible errors
- Example request and response payloads

**HTTP endpoints (if applicable):**
- Method, path, parameters, response format
- Authentication requirements

**Events published (if applicable):**
- Exchange, routing key, payload format

### `faq_internal.md`

Q&A for the service developer. Cover:
- How to add a new route or endpoint
- How background jobs work and how to add one
- How to add a new service dependency
- Non-obvious architectural decisions

### `faq_external.md`

Q&A for developers of other services that consume this one. Cover:
- How to make a request to this service
- What errors to expect and how to handle them
- How to handle retries and timeouts
- How to test integrations against this service

### `antipatterns.md`

Common mistakes when interacting with or modifying this service.

### `errors.md`

All error responses this service can return. For each:
- HTTP status / error code
- When it occurs
- What the response body looks like
- How the caller should handle it

---

## Step 5 — Update docs/howto/ and README.md

Read `docs/_index.md` to discover which human docs exist.
Update sections affected by this PR's changes.
Update `README.md` last — after `docs/howto/` is updated.

README structure for a microservice:
1. Service purpose (one paragraph)
2. Transports (BugBunny queue name, HTTP base URL)
3. Quick start — how another service calls this one
4. Links to `docs/ai/contracts.md` for full contract reference

---

## Step 6 — Show diff and wait for approval

Show the complete diff of all generated/updated files.
Wait for developer approval before proceeding to PR creation.
The developer may adjust content before confirming.
Do NOT create the PR until the docs are approved.
