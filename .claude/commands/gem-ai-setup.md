Generate or update the complete AI documentation suite for this gem.

This skill is invoked automatically by `/release`. It can also be run standalone to update docs without a full release.

BugBunny's `docs/ai/` is the **golden example** of the expected output quality. When in doubt, read it.

---

## Step 1 — Discover the current state

Read in order:
1. `lib/bug_bunny/version.rb` (or equivalent) — current version
2. `docs/_index.md` — if it exists, it lists all files to update and their purpose
3. `docs/ai/_index.md` — if it exists, it has the current profile (minimal/full) and file list
4. `gemspec` — gem name, summary, description, dependencies
5. `CLAUDE.md` — architecture, components, patterns, extension hooks

If `docs/ai/` does not exist yet, this is a **first-time generation**. Create from scratch.
If it exists, **update only the sections affected by the changes in this release**.

---

## Step 2 — Determine the profile

**Full profile** when any of these apply:
- Gem is public (has a homepage or published to RubyGems)
- Gem has multiple audiences (internal maintainers + external integrators)
- Gem has a non-trivial public API (multiple classes, errors, configuration)

**Minimal profile** when all of these apply:
- Gem is internal-only
- Single audience
- Simple API (one entry point, few methods)

Full profile files: `_index.md`, `glossary.md`, `architecture.md`, `api.md`, `faq_internal.md`, `faq_external.md`, `antipatterns.md`, `errors.md`
Minimal profile files: `_index.md`, `api.md`, `errors.md`

---

## Step 3 — Analyze the codebase

Read the following to generate accurate content:
- All files under `lib/` — public API, class responsibilities, method signatures
- `spec/` or `test/` — usage patterns, edge cases, what errors are expected
- `CHANGELOG.md` — what changed in this version (for updating existing docs)
- `docs/howto/` — existing human docs to stay consistent with

---

## Step 4 — Generate or update each file

Apply these rules to every file:

**RAG optimization rules (mandatory):**
1. Each section ≤ 400 tokens — chunks must be self-contained
2. Each section self-contained — do not assume context from previous sections
3. `faq_*.md` always in strict Q&A format — H3 with the question, answer ≤ 150 words
4. `glossary.md` one entry per term — term in bold, definition in 1-3 lines
5. `errors.md` one entry per error — name, cause, how to reproduce, how to resolve
6. No introductory prose — go straight to content

### `_index.md`

Frontmatter manifest. Update `version:` to the new version. Keep `profile:`, `kind:`, `audiences:` stable unless the gem changed fundamentally. List every file under `files:` with its audience.

Reference: `docs/ai/_index.md` in BugBunny.

### `glossary.md`

Domain terms specific to this gem. Include:
- Core abstractions introduced by the gem
- Terms a developer needs to understand to use the gem correctly
- Terms that have a non-obvious meaning in this context

Do NOT include generic Ruby or framework terms unless the gem redefines them.

Reference: `docs/ai/glossary.md` in BugBunny.

### `architecture.md`

Internal-facing. Include:
- Component map (ASCII diagram if useful)
- How the components interact at runtime
- Key design decisions and why (not just what)
- Thread safety considerations if relevant
- Caching or lifecycle patterns

Reference: `docs/ai/architecture.md` in BugBunny.

### `api.md`

External-facing. Include:
- Configuration block with all options, types, defaults, and constraints
- Every public class with its public methods: signature, parameters, return type, description
- Code examples for each major operation
- Class-level configuration options (`.with`, class attributes, etc.)

Reference: `docs/ai/api.md` in BugBunny.

### `faq_internal.md`

Q&A for the gem maintainer. Cover:
- Non-obvious implementation decisions ("why X instead of Y?")
- Thread safety and concurrency considerations
- How to extend or hook into the gem
- Common mistakes when modifying the gem internals

Each Q&A: H3 for the question, answer ≤ 150 words, no preamble.

Reference: `docs/ai/faq_internal.md` in BugBunny.

### `faq_external.md`

Q&A for the developer integrating the gem. Cover:
- Setup and configuration questions
- How to perform the most common operations
- Error handling patterns
- Testing patterns
- Performance and tuning questions

Each Q&A: H3 for the question, answer ≤ 150 words, no preamble.

Reference: `docs/ai/faq_external.md` in BugBunny.

### `antipatterns.md`

What NOT to do. For each antipattern:
1. Name it clearly
2. Show the wrong code
3. Explain why it's wrong (not just "it's bad")
4. Show the correct alternative

Reference: `docs/ai/antipatterns.md` in BugBunny.

### `errors.md`

All exceptions the gem raises. For each:
- Class name and inheritance
- Cause (what triggers it)
- How to reproduce it (minimal example)
- How to resolve it

Reference: `docs/ai/errors.md` in BugBunny.

---

## Step 5 — Update docs/howto/ and docs/concepts.md

Read `docs/_index.md` (human documentation section) to know which files exist.
Update only the sections affected by the changes in this release.
Do not rewrite files that were not affected by the changes.

---

## Step 6 — Update README.md

Generate or update README.md after `docs/howto/` is already updated.
README structure:
1. One-line description
2. Installation (`gem 'gem_name'` in Gemfile)
3. Quick start — two minimal code examples (publisher side + consumer/server side if applicable)
4. Features list for the current version
5. Links to `docs/` for deeper guides

Keep it under 150 lines. README is the entry point — `docs/` is the depth.

---

## Step 7 — Show diff and wait for approval

Show the complete diff of all generated/updated files.
Wait for developer approval before proceeding.
The developer may adjust content before confirming.
Do NOT proceed to version bump or CHANGELOG until approved.
