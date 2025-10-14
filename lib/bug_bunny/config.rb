module BugBunny
  class Config
    # getter y setter para cada propiedad.
    attr_accessor :host, :username, :password, :vhost, :logger, :automatically_recover, :network_recovery_interval, :connection_timeout, :read_timeout, :write_timeout, :heartbeat, :continuation_timeout

    # Método para generar la URL de conexión
    def url
      "amqp://#{username}:#{password}@#{host}/#{vhost}"
    end
  end
end
