# frozen_string_literal: true

require 'concurrent'

module BugBunny
  # Lleva la cuenta de un drenaje de {Consumer#drain}: cuántos mensajes se procesaron,
  # cuántos están en proceso y cuándo fue la última actividad.
  #
  # Es thread-safe: las entregas corren en el work pool de Bunny y la espera en el hilo
  # que llamó a `drain`.
  #
  # @api private
  class DrainTracker
    # @param clock [#call] Reloj monotónico en segundos (inyectable para tests).
    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @clock = clock
      @processed = Concurrent::AtomicFixnum.new(0)
      @in_flight = Concurrent::AtomicFixnum.new(0)
      @last_activity = Concurrent::AtomicReference.new(clock.call)
    end

    # Envuelve el procesamiento de una entrega. Cuenta la entrega como procesada aunque
    # el bloque levante: {Consumer#handle_delivery} rechaza la que falla antes del ack, así
    # que en todos los caminos el mensaje ya salió de la cola (ack o reject).
    #
    # @yield El procesamiento de la entrega.
    # @return [void]
    def track
      @in_flight.increment
      yield
    ensure
      @processed.increment
      @last_activity.set(@clock.call)
      @in_flight.decrement
    end

    # @return [Boolean] `true` si hay alguna entrega en proceso.
    def busy?
      @in_flight.value.positive?
    end

    # @param idle_timeout [Numeric] Segundos sin actividad.
    # @return [Boolean] `true` si no hay nada en proceso y pasaron `idle_timeout` segundos
    #   desde la última actividad.
    def idle?(idle_timeout)
      !busy? && @clock.call - @last_activity.get >= idle_timeout
    end

    # @return [Integer] Entregas procesadas hasta ahora.
    def processed
      @processed.value
    end
  end
end
