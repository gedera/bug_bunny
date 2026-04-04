---
name: sentry
description: Experto en la instancia self-hosted de Sentry de Wispro. Úsala SIEMPRE que necesites buscar errores, listar issues, ver stacktraces, resolver o asignar issues en Sentry. Funciona con cualquier proyecto del ecosistema.
---

# Sentry Expert

Skill de conocimiento completo sobre la instancia de Sentry self-hosted de Wispro. Consultame para buscar errores, analizar stacktraces, gestionar issues o diagnosticar problemas en producción.

## Configuración

```bash
SENTRY_TOKEN=$SENTRY_TOKEN
SENTRY_URL="https://sentry.cloud.wispro.co"
SENTRY_ORG="wispro"
```

**Importante:** Siempre usar `-k` en curl (certificado self-hosted). Nunca exponer el token en las respuestas.

## Glosario

**Issue** — Agrupación de eventos similares. Tiene un ID numérico y un shortId legible (ej: `PROJECT-123`).

**Event** — Ocurrencia individual de un error. Contiene stacktrace, contexto, usuario, breadcrumbs.

**Project slug** — Identificador del proyecto en Sentry. Cada microservicio tiene uno. Si no lo sabés, listá los proyectos primero.

**statsPeriod** — Período de estadísticas: `24h`, `14d` o vacío para todo el historial.

## Flujos de Trabajo

### Buscar errores en un proyecto

1. Si no tenés el project slug, listá los proyectos primero (ver API).
2. Consultá issues del proyecto filtrando por período y query.
3. Para cada issue relevante, consultá los eventos para ver el stacktrace.

### Diagnosticar un error desde el código

1. Tomá el mensaje de error o excepción del código/logs.
2. Buscá en Sentry con `query=<mensaje>` en el proyecto correspondiente.
3. Si hay match, mostrá el stacktrace y la frecuencia.
4. Si no hay match, indicá que el error no está reportado en Sentry.

### Gestionar issues

- **Resolver**: `status=resolved`
- **Ignorar**: `status=ignored`
- **Asignar**: `assignedTo=<username>`
- **Marcar como visto**: `hasSeen=true`

### Análisis de tendencias

1. Consultá issues con `statsPeriod=14d` para ver tendencias.
2. Ordená por `count` o `userCount` para priorizar.
3. Revisá `firstSeen` y `lastSeen` para detectar regresiones.

## API — Endpoints principales

Todos los endpoints usan base URL `$SENTRY_URL/api/0/` y header `Authorization: Bearer $SENTRY_TOKEN`.

Ver catálogo completo en [references/api-endpoints.md](references/api-endpoints.md).

### Listar proyectos
```bash
curl -sk -H "Authorization: Bearer $SENTRY_TOKEN" \
  "$SENTRY_URL/api/0/organizations/$SENTRY_ORG/projects/" | jq '.[] | {slug, name}'
```

### Listar issues de un proyecto
```bash
curl -sk -H "Authorization: Bearer $SENTRY_TOKEN" \
  "$SENTRY_URL/api/0/projects/$SENTRY_ORG/{PROJECT_SLUG}/issues/?statsPeriod=24h&query=is:unresolved"
```

### Ver detalle de un issue
```bash
curl -sk -H "Authorization: Bearer $SENTRY_TOKEN" \
  "$SENTRY_URL/api/0/organizations/$SENTRY_ORG/issues/{ISSUE_ID}/"
```

### Ver eventos de un issue (con stacktrace)
```bash
curl -sk -H "Authorization: Bearer $SENTRY_TOKEN" \
  "$SENTRY_URL/api/0/organizations/$SENTRY_ORG/issues/{ISSUE_ID}/events/?full=true&limit=1"
```

### Buscar por mensaje de error
```bash
curl -sk -H "Authorization: Bearer $SENTRY_TOKEN" \
  "$SENTRY_URL/api/0/projects/$SENTRY_ORG/{PROJECT_SLUG}/issues/?query={MENSAJE}&statsPeriod=24h"
```

### Resolver un issue
```bash
curl -sk -X PUT -H "Authorization: Bearer $SENTRY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status":"resolved"}' \
  "$SENTRY_URL/api/0/organizations/$SENTRY_ORG/issues/{ISSUE_ID}/"
```

## FAQ

### ¿Cómo encuentro el project slug de mi servicio?
Ejecutá el endpoint de listar proyectos. El campo `slug` es lo que necesitás. Generalmente coincide con el nombre del repo en minúsculas.

### ¿Cómo veo el stacktrace completo?
Usá el endpoint de eventos con `full=true`. El stacktrace está en `entries[].data.values[].stacktrace.frames[]`. Cada frame tiene `filename`, `lineNo`, `function` y `context`.

### ¿Cómo filtro por nivel de error?
Agregá `query=level:error` o `query=level:warning` al endpoint de issues.

### ¿Cómo pagino resultados?
La API devuelve un header `Link` con cursores. Usá el parámetro `cursor` del link `next` para la siguiente página.

## Antipatrones

**Buscar sin project slug** — No consultes issues a nivel organización si sabés el proyecto. Es más lento y devuelve ruido de otros servicios.

**Ignorar la paginación** — Por defecto la API devuelve pocos resultados. Si necesitás más, paginá con el cursor.

**Hardcodear issue IDs** — Los IDs cambian. Siempre buscá por query o filtrá por período.

## Errores comunes

**401 Unauthorized** — Token inválido o expirado. Verificá que `$SENTRY_TOKEN` esté en el entorno.

**404 Not Found** — Project slug incorrecto. Listá los proyectos para verificar.

**SSL Certificate Error** — Falta el flag `-k` en curl. Es necesario porque es self-hosted.

## Referencias

- [API Endpoints](references/api-endpoints.md) — Catálogo completo de endpoints con parámetros
- [sentry.rb](scripts/sentry.rb) — Script helper para queries comunes
