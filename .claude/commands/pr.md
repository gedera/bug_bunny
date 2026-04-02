Create a Pull Request for BugBunny via GitHub CLI. Usage: /pr

Creá un PR desde la rama actual hacia `main` usando `gh`.

## Pasos

1. **Correr tests** — si fallan, detener todo:
   ```bash
   source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8
   bundle exec rspec
   ```
2. **autocorregir rubocop** - si fallan, detener todo
   ```bash
   bundle exec rubocop -a
   ```
3. **Ejecutar `/gem-ai-setup`** — genera/actualiza `docs/howto/`, `docs/ai/` y `README.md`.
   Esperar aprobación del developer antes de continuar.
4. Verificá que hay commits en la rama que no están en main: `git log main..HEAD --oneline`
5. Revisá todos los cambios del PR: `git diff main...HEAD`
6. Determiná el tipo de cambio (feature, bugfix, refactor, docs, chore)
7. Creá el PR con `gh pr create`:

```bash
gh pr create --title "tipo: descripción breve" --body "$(cat <<'EOF'
## Summary
- Bullet points de los cambios principales

## Test plan
- [ ] Tests existentes pasan (`/test`)
- [ ] RuboCop sin offenses (`/rubocop`)
- [ ] YARD documentado en métodos nuevos/modificados

## Notes
Contexto adicional si es necesario.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

## Convenciones de título

- `feat: descripción` — feature nueva
- `fix: descripción` — bugfix
- `chore: descripción` — mantenimiento, deps, config
- `docs: descripción` — solo documentación
- `refactor: descripción` — refactor sin cambio de comportamiento

## Importante

- El remote SSH está roto — si el PR requiere push previo, usar HTTPS temporalmente
- Mostrar la URL del PR creado al usuario
- No crear el PR sin confirmación del usuario
