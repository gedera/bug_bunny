# BugBunny

## Publish

## Consumer

## Exceptions
- Error General:
 - `BugBunny::Error` hereda de `::StandardError` (Captura cualquier error de la gema.)
- Error de Publicadores:
 - `BugBunny::PublishError` hereda de `BugBunny::Error` (Para fallos de envío o conexión.)
- Error de Respuestas:
 - `BugBunny::ResponseError::Base` hereda de `BugBunny::Error` (Captura todos los errores de respuesta).
- Errores Específicos de Respuesta:
 - `BugBunny::ResponseError::BadRequest`
 - `BugBunny::ResponseError::NotFound`
 - `BugBunny::ResponseError::NotAcceptable`
 - `BugBunny::ResponseError::RequestTimeout`
 - `BugBunny::ResponseError::UnprocessableEntity`
 - `BugBunny::ResponseError::InternalServerError`
