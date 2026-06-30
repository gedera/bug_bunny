# Release — bug_bunny

> meta: artefacto release · RFC-014 (`accepted`) · generado por `arch-structure`
> + `arch-enrich` (híbrido RFC-014 §2; nació como piloto manual #51, re-anclado
> a la RFC vigente) · anclado a `.github/workflows/release.yml`, `*.gemspec`,
> `lib/bug_bunny/version.rb`, `CHANGELOG.md`, git · fecha 2026-06-30 · cobertura:
> completa (régimen gema: build→publish, §e/f/g n/a).

## 1. Resumen

Cómo se libera esta gema. **Patrón 1 (gema-tag):** push de tag `vX.X.X` → un
**GitHub Actions workflow que vive en el repo** (`.github/workflows/release.yml`)
→ `gem build` + `gem push` a **RubyGems público**. A diferencia de un servicio,
el pipeline **no es opaco**: vive en `.github/`, es auditable y versionado con el
código (`dueño: per-repo-visible`). Una gema **no despliega — publica**: §e
(deploy), §f (ambientes), §g (rollback) son **n/a** (rollback = `gem yank`,
out-of-repo).

## 2. Cuerpo

### a. Hecho verificable

- **Convención de versión:** SemVer `vX.X.X`. Actual: **4.19.0**.
- **Source of truth:** tag remoto (`v4.19.0`) + **triple mirror**
  `lib/bug_bunny/version.rb` (`VERSION = '4.19.0'`) ← `bug_bunny.gemspec:7`
  (`spec.version = BugBunny::VERSION`).
- **Changelog canónico:** `CHANGELOG.md` único.
- **Patrón de trigger:** `gema-tag` (patrón 1).
- **Salida:** gema publicada en **RubyGems público**.
- **Deploy / ambientes / rollback:** **n/a** (gema publica, no despliega).

### b. Versionado

- **Convención:** SemVer `vX.X.X` (**con `v`** — distinto al servicio).
- **Source of truth:** tag remoto canónico (`git tag --sort=-v:refname` →
  `v4.19.0`).
- **Mirror:** `lib/bug_bunny/version.rb` (`VERSION`), leído por
  `bug_bunny.gemspec:7` (`spec.version = BugBunny::VERSION`).
  `required_ruby_version >= 2.6.0` (`bug_bunny.gemspec:17`).
- **Política de divergencia:** `gem-release` lee el tag remoto; si `version.rb`
  difiere → warn (posible release sin taguear). El bump se calcula sobre el tag.

### c. Changelog

- **Canónico único:** `CHANGELOG.md` ✓.
- **Formato:** `## [X.X.X] - YYYY-MM-DD` + nota de behavior-change si aplica +
  categorías (`### Correcciones`), atribución `— @autor`, **link al issue**
  (ej. `(#49)`). Cruza RFC-013 §h: el changelog ya referencia el incidente que
  motivó el fix.

### d. Trigger → pipeline → salida

| Patrón | Trigger (señal per-repo) | Pipeline | Salida | Dueño |
|---|---|---|---|---|
| `gema-tag` | push tag `vX.X.X` | GH Actions `.github/workflows/release.yml` | gema en **RubyGems público** | **`per-repo-visible`** |

- **Pipeline NO opaco:** `.github/workflows/release.yml` —
  `on: push: tags: ['v*']` → `ruby/setup-ruby@v1` → `gem build *.gemspec` +
  `gem push *.gem` (auth `secrets.RUBYGEMS_API_KEY`). Auditable y versionado con
  el código; se ancla a `file:line`, no se referencia como caja negra.
- **Consumo:** los servicios la pinnean por versión (`gem "bug_bunny", "~> 4.19.0"`)
  desde RubyGems — **no** git-source.

### e. Deploy / publish

**n/a (deploy)** — una gema no despliega. El "release" es **publish** a RubyGems,
cubierto en §d. No hay ambiente de runtime propio.

### f. Ambientes

**n/a** — no hay `dev`/`staging`/`prod`. La única salida es la gema publicada.

### g. Rollback

**n/a en el repo** — el rollback de una gema es **`gem yank <version>`** en
RubyGems (admin out-of-repo), no un cambio de código. No se documenta como
procedimiento per-repo porque no vive acá. Una versión yankeada se anotaría en
`CHANGELOG.md` (con su razón) si pasara.

### h. Dependencias de deploy inter-servicio

- **Consumidores** (cruza RFC-018): servicios del fleet la pinnean
  `~> 4.19.0` (semántica minor-compatible). Un cambio de contrato del gem
  (ej. el behavior-change de `4.18.0` — `Bunny::Exception` → `CommunicationError`)
  obliga a los consumidores a migrar; el `CHANGELOG.md` lo documenta como
  breaking note. **Orden de deploy:** los consumidores adoptan al hacer `bundle
  update bug_bunny` — no hay deploy coordinado (cada servicio elige cuándo).

### i. Contrato con la skill productora

- **Skill:** `gem-release` (tag-based, **aplica** — patrón 1 emite tag).
- **Qué espera del repo:** `lib/bug_bunny/version.rb` como source, `*.gemspec`
  que lo lee, `CHANGELOG.md` canónico, tag `vX.X.X`, gate `quality-code` verde,
  y el `.github/workflows/release.yml` que publica en el tag.
- **Estado:** conforma — layout estándar de gema, workflow per-repo presente.

## 3. Inferencias

- Ninguna relevante: el pipeline de gema es **visible** (`.github/`), así que el
  artefacto se ancla a archivos reales, no a inferencia sobre cajas negras.

## 4. Cobertura y fronteras

- Cobertura **completa** del régimen gema (build→publish). §e/f/g `n/a` honesto.
- Contraste validado con el piloto servicio (`box_radius_manager`): allá el
  pipeline es **opaco** (`fleet-link` Codefresh); acá es **per-repo-visible**
  (GH Actions en el repo). Misma RFC, dos loci de dueño — el valor de la columna
  `dueño` de §d.
