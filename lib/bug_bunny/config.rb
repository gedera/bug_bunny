module BugBunny
  class Config
    # getter y setter para cada propiedad.
    attr_accessor :user, :pass, :host, :virtual_host, :logger, :log_level

    # Método para generar la URL de conexión
    def url
      "amqp://#{user}:#{pass}@#{host}/#{virtual_host}"
    end
  end
end
