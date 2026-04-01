Run RuboCop for BugBunny. Usage: /rubocop [--fix]

Ejecutá RuboCop con rubocop-rails-omakase sobre el código modificado.

## Comandos

Sin argumentos — solo reporte:
```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8 && bundle exec rubocop
```

Con `--fix` — autocorrect seguro:
```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8 && bundle exec rubocop -a
```

## Reglas importantes

- **Solo corregir código nuevo o modificado en el PR actual** — nunca tocar código existente no relacionado
- Si hay offenses que requieren intervención manual (no autocorregibles), reportalos con línea y descripción
- rubocop-rails-omakase tiene opiniones fuertes sobre estilo — seguirlas sin discutir
- Si hay un offense legítimo que debe ignorarse, usar `# rubocop:disable Cop/Name` en la línea específica con un comentario explicativo
