Run RSpec tests for BugBunny. Usage: /test [path]

Ejecutá la suite de tests de BugBunny con Ruby 3.3.8.

## Comando base

```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8 && bundle exec rspec
```

Si se pasa un path como argumento, corré solo ese archivo o directorio:

```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8 && bundle exec rspec $ARGUMENTS
```

## Después de correr los tests

- Si hay failures: analizá el error, identificá la causa raíz, proponé el fix al usuario antes de tocar código
- Si hay warnings de deprecación: reportalos al usuario
- Si todos pasan: confirmá con el conteo de ejemplos y tiempo de ejecución

## Convenciones de RSpec en este proyecto

- Tests en `spec/`
- Sin mocks de RabbitMQ real — usar doubles de Bunny
- Describir comportamiento, no implementación
- Un `context` por escenario, `it` con descripción en español o inglés consistente con el archivo
