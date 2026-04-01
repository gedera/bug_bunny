Validate and generate YARD documentation for BugBunny. Usage: /yard

Verificá y generá la documentación YARD de la gema.

## Comandos

Generar docs:
```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8 && bundle exec yard doc
```

Ver métodos sin documentar:
```bash
source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-3.3.8 && bundle exec yard stats --list-undoc
```

## Estándar YARD de este proyecto

Todo método público nuevo o modificado debe tener:

```ruby
# Descripción breve en una línea.
#
# Descripción extendida opcional si la firma no es autoexplicativa.
#
# @param nombre [Tipo] Descripción del parámetro
# @return [Tipo] Descripción del valor de retorno
# @raise [ClaseError] Condición bajo la cual se lanza
# @example
#   resultado = mi_metodo(arg)
def mi_metodo(nombre)
```

## Tipos comunes en este proyecto

- `[String]`, `[Integer]`, `[Boolean]`, `[Hash]`, `[Array]`, `[Symbol]`
- `[Bunny::Session]`, `[Bunny::Channel]`, `[Bunny::MessageProperties]`
- `[BugBunny::Session]`, `[BugBunny::Request]`, `[BugBunny::Configuration]`
- `[Proc, nil]` para callbacks opcionales
- `[void]` para métodos sin return value relevante

## Después de correr

- Reportá los métodos públicos sin documentar
- No documentar métodos privados (YARD los ignora por defecto con `private`)
- No documentar métodos triviales (`attr_reader`, `attr_accessor`) salvo que necesiten contexto
