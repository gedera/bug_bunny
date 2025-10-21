module BugBunny
  # Clase base para TODOS los errores de la gema BugBunny.
  # Ayuda a atrapar cualquier error de la gema con un solo 'rescue BugBunny::Error'.
  class Error < ::StandardError; end
  class PublishError < Error; end
  class Connection < Error; end

  module ResponseError
    class Base < Error; end

    class BadRequest < Base; end           # HTTP 400
    class NotFound < Base; end             # HTTP 404
    class NotAcceptable < Base; end        # HTTP 406
    class RequestTimeout < Base; end       # HTTP 408
    class UnprocessableEntity < Base; end  # HTTP 422
    class InternalServerError < Base; end  # HTTP 500
  end
end
