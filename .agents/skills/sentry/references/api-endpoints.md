# Sentry API — Catálogo de Endpoints

Base URL: `$SENTRY_URL/api/0/`
Auth: `Authorization: Bearer $SENTRY_TOKEN`
Siempre usar `-k` en curl (certificado self-hosted).

## Proyectos

### Listar proyectos de la organización
```
GET /organizations/{org}/projects/
```
Respuesta: array de objetos con `slug`, `name`, `id`, `platform`, `dateCreated`.

### Obtener detalle de un proyecto
```
GET /projects/{org}/{project_slug}/
```

## Issues

### Listar issues de un proyecto
```
GET /projects/{org}/{project_slug}/issues/
```
Query params:
- `statsPeriod` — `24h`, `14d` o vacío (default: `24h`)
- `query` — Búsqueda estructurada (default: `is:unresolved`)
- `shortIdLookup` — `true` para buscar por shortId
- `cursor` — Paginación

Respuesta: array de issues con `id`, `title`, `culprit`, `count`, `userCount`, `firstSeen`, `lastSeen`, `level`, `status`, `shortId`, `project`.

### Listar issues de la organización
```
GET /organizations/{org}/issues/
```
Mismos query params. Devuelve issues de todos los proyectos.

### Obtener detalle de un issue
```
GET /organizations/{org}/issues/{issue_id}/
```
Respuesta: issue completo con `activity`, `assignedTo`, `count`, `firstSeen`, `lastSeen`, `firstRelease`, `lastRelease`, `participants`, `userReportCount`, `stats`.

### Actualizar un issue
```
PUT /organizations/{org}/issues/{issue_id}/
```
Body (JSON, todos opcionales):
- `status` — `resolved`, `resolvedInNextRelease`, `unresolved`, `ignored`
- `assignedTo` — username o team
- `hasSeen` — boolean
- `isBookmarked` — boolean
- `isSubscribed` — boolean
- `isPublic` — boolean

### Eliminar un issue
```
DELETE /organizations/{org}/issues/{issue_id}/
```

### Bulk update issues de un proyecto
```
PUT /projects/{org}/{project_slug}/issues/
```
Query params:
- `id` — lista de issue IDs a actualizar

Body: mismos campos que update individual.

## Eventos

### Listar eventos de un issue
```
GET /organizations/{org}/issues/{issue_id}/events/
```
Query params:
- `full` — `true` para incluir body completo con stacktrace
- `statsPeriod` — período de filtro
- `environment` — filtrar por entorno
- `query` — búsqueda dentro de eventos
- `cursor` — paginación

Respuesta: array de eventos con `id`, `eventID`, `groupID`, `title`, `message`, `dateCreated`, `tags`, `user`, `location`, `culprit`.

### Listar eventos de error de un proyecto
```
GET /projects/{org}/{project_slug}/events/
```

### Obtener evento específico de un proyecto
```
GET /projects/{org}/{project_slug}/events/{event_id}/
```
Respuesta completa con stacktrace en `entries[].data.values[].stacktrace.frames[]`.

Cada frame contiene:
- `filename` — archivo
- `lineNo` — línea
- `function` — método
- `context` — líneas de código alrededor
- `inApp` — boolean, si es código de la app o dependencia

## Tags

### Valores de un tag en un issue
```
GET /organizations/{org}/issues/{issue_id}/tags/{tag_key}/values/
```
Tags comunes: `environment`, `server_name`, `browser`, `os`, `release`.

### Detalle de un tag en un issue
```
GET /organizations/{org}/issues/{issue_id}/tags/{tag_key}/
```

## Hashes

### Listar hashes de un issue
```
GET /organizations/{org}/issues/{issue_id}/hashes/
```
Útil para entender qué variantes de stacktrace se agrupan en el mismo issue.

## Paginación

La API usa cursor-based pagination. El header `Link` de la respuesta contiene:

```
Link: <url>; rel="previous"; results="false"; cursor="...",
      <url>; rel="next"; results="true"; cursor="..."
```

Usar el valor de `cursor` del link `next` como query param para la siguiente página. Cuando `results="false"` en `next`, no hay más páginas.

## Queries estructuradas

El parámetro `query` soporta:
- `is:unresolved` / `is:resolved` / `is:ignored`
- `level:error` / `level:warning` / `level:info`
- `assigned:username` / `assigned:me`
- `bookmarks:me`
- `firstSeen:>2024-01-01`
- `lastSeen:<24h`
- `times_seen:>100`
- Texto libre para buscar en título/mensaje
