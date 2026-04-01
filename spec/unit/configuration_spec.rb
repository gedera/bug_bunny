# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BugBunny::Configuration do
  # Construye una configuración con los defaults + overrides dados, llama validate!.
  def configure_with(**overrides)
    BugBunny.configuration = BugBunny::Configuration.new
    BugBunny.configure do |c|
      overrides.each { |attr, val| c.send(:"#{attr}=", val) }
    end
  end

  after { BugBunny.configuration = BugBunny::Configuration.new }

  describe 'defaults' do
    it 'pasan validate! sin ninguna configuración adicional' do
      expect { configure_with }.not_to raise_error
    end
  end

  describe 'host' do
    it 'levanta ConfigurationError si es nil' do
      expect { configure_with(host: nil) }
        .to raise_error(BugBunny::ConfigurationError, /host is required/)
    end

    it 'levanta ConfigurationError si es string vacío' do
      expect { configure_with(host: '') }
        .to raise_error(BugBunny::ConfigurationError, /host is required/)
    end

    it 'levanta ConfigurationError si no es String' do
      expect { configure_with(host: 12_345) }
        .to raise_error(BugBunny::ConfigurationError, /host must be a String/)
    end
  end

  describe 'port' do
    it 'levanta ConfigurationError si es un String' do
      expect { configure_with(port: 'invalid') }
        .to raise_error(BugBunny::ConfigurationError, /port must be a Integer/)
    end

    it 'levanta ConfigurationError si es 0 (fuera de rango)' do
      expect { configure_with(port: 0) }
        .to raise_error(BugBunny::ConfigurationError, /port must be in/)
    end

    it 'levanta ConfigurationError si es 99999 (fuera de rango)' do
      expect { configure_with(port: 99_999) }
        .to raise_error(BugBunny::ConfigurationError, /port must be in/)
    end

    it 'acepta valores en los límites del rango (1 y 65535)' do
      expect { configure_with(port: 1) }.not_to raise_error
      expect { configure_with(port: 65_535) }.not_to raise_error
    end

    it 'acepta 5672 (default de RabbitMQ)' do
      expect { configure_with(port: 5672) }.not_to raise_error
    end
  end

  describe 'username / password' do
    it 'levanta ConfigurationError si username es nil' do
      expect { configure_with(username: nil) }
        .to raise_error(BugBunny::ConfigurationError, /username is required/)
    end

    it 'levanta ConfigurationError si password es nil' do
      expect { configure_with(password: nil) }
        .to raise_error(BugBunny::ConfigurationError, /password is required/)
    end

    it 'levanta ConfigurationError si username no es String' do
      expect { configure_with(username: 123) }
        .to raise_error(BugBunny::ConfigurationError, /username must be a String/)
    end
  end

  describe 'heartbeat' do
    it 'acepta 0 (heartbeat deshabilitado)' do
      expect { configure_with(heartbeat: 0) }.not_to raise_error
    end

    it 'levanta ConfigurationError si es negativo' do
      expect { configure_with(heartbeat: -1) }
        .to raise_error(BugBunny::ConfigurationError, /heartbeat must be in/)
    end

    it 'levanta ConfigurationError si supera 3600' do
      expect { configure_with(heartbeat: 3_601) }
        .to raise_error(BugBunny::ConfigurationError, /heartbeat must be in/)
    end

    it 'levanta ConfigurationError si no es Integer' do
      expect { configure_with(heartbeat: '30') }
        .to raise_error(BugBunny::ConfigurationError, /heartbeat must be a Integer/)
    end
  end

  describe 'rpc_timeout' do
    it 'levanta ConfigurationError si es negativo' do
      expect { configure_with(rpc_timeout: -1) }
        .to raise_error(BugBunny::ConfigurationError, /rpc_timeout must be in/)
    end

    it 'levanta ConfigurationError si es 0' do
      expect { configure_with(rpc_timeout: 0) }
        .to raise_error(BugBunny::ConfigurationError, /rpc_timeout must be in/)
    end
  end

  describe 'channel_prefetch' do
    it 'levanta ConfigurationError si es 0' do
      expect { configure_with(channel_prefetch: 0) }
        .to raise_error(BugBunny::ConfigurationError, /channel_prefetch must be in/)
    end

    it 'levanta ConfigurationError si supera 10000' do
      expect { configure_with(channel_prefetch: 10_001) }
        .to raise_error(BugBunny::ConfigurationError, /channel_prefetch must be in/)
    end
  end

  describe 'configuración válida completa' do
    it 'acepta todos los atributos con valores correctos' do
      expect do
        configure_with(
          host: '10.0.0.1',
          port: 5673,
          username: 'myuser',
          password: 'mypass',
          vhost: '/production',
          heartbeat: 30,
          rpc_timeout: 5,
          channel_prefetch: 10
        )
      end.not_to raise_error
    end
  end

  describe 'atributos opcionales nil' do
    it 'acepta nil en atributos no requeridos (max_reconnect_attempts, health_check_file)' do
      expect do
        configure_with(max_reconnect_attempts: nil, health_check_file: nil)
      end.not_to raise_error
    end
  end

  describe '.validate! directamente' do
    it 'es invocable directamente sobre la instancia' do
      config = BugBunny::Configuration.new
      expect { config.validate! }.not_to raise_error
    end

    it 'levanta ConfigurationError si el estado es inválido' do
      config = BugBunny::Configuration.new
      config.port = 'bad'
      expect { config.validate! }.to raise_error(BugBunny::ConfigurationError)
    end
  end
end
