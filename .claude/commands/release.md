Release BugBunny gem. Usage: /release [patch|minor|major]

Ejecutá el flujo completo de release para BugBunny. El argumento determina el tipo de bump:
- `patch` → bugfix (4.6.1 → 4.6.2)
- `minor` → feature nueva (4.6.1 → 4.7.0)
- `major` → breaking change (4.6.1 → 5.0.0)

## Pasos

1. **Leer versión actual** de `lib/bug_bunny/version.rb`
2. **Calcular nueva versión** según el tipo de bump
3. **Correr tests** — si fallan, detener todo:
   ```bash
   source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8
   bundle exec rspec
   ```
4. **autocorregir rubocop** - si fallan, detener todo
   ```bash
   bundle exec rubocop -a
   ```
5. **Ejecutar `/gem-ai-setup`** — genera/actualiza `docs/howto/`, `docs/ai/` y `README.md`.
   Esperar aprobación del developer antes de continuar.
6. **Actualizar `lib/bug_bunny/version.rb`** con la nueva versión
7. **Agregar entrada al tope de `CHANGELOG.md`** con formato:
   ```
   ## [X.Y.Z] - YYYY-MM-DD
   ### ✨ New Features / 🐛 Bug Fixes / 💥 Breaking Changes
   * Descripción de los cambios
   ```
8. **Mostrar el diff completo** al usuario y pedir confirmación antes de continuar
9. **Commit** con mensaje: `feat|fix|chore: descripción breve vX.Y.Z`
10. **Merge a main** desde `/Users/gabriel/src/gems/bug_bunny`: `git merge --ff-only <branch>`
11. **Push via HTTPS**:
    ```bash
    git remote set-url origin https://github.com/gedera/bug_bunny.git
    git push origin main
    git remote set-url origin git@github.com:gedera/bug_bunny.git
    ```
12. **Tag y push**:
    ```bash
    git tag vX.Y.Z
    git remote set-url origin https://github.com/gedera/bug_bunny.git
    git push origin vX.Y.Z
    git remote set-url origin git@github.com:gedera/bug_bunny.git
    ```

## Importante

- Nunca commitear ni pushear sin confirmación explícita del usuario
- El worktree de main está en `/Users/gabriel/src/gems/bug_bunny`
- SSH está roto — siempre usar HTTPS para push y restaurar SSH después
- Sourcear chruby antes de cualquier comando Ruby: `source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8`
