# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BugBunny::ConsumerMiddleware::Stack do
  subject(:stack) { described_class.new }

  let(:delivery_info) { double('delivery_info') }
  let(:properties)    { double('properties') }
  let(:body)          { 'payload' }

  # Construye un middleware de seguimiento que escribe en `log` (Array capturado por closure).
  def tracking_middleware(log, label)
    Class.new(BugBunny::ConsumerMiddleware::Base) do
      define_method(:call) do |delivery, props, msg|
        log << :"#{label}_before"
        @app.call(delivery, props, msg)
        log << :"#{label}_after"
      end
    end
  end

  describe '#use' do
    it 'registra un middleware y retorna self para encadenamiento' do
      klass  = Class.new(BugBunny::ConsumerMiddleware::Base)
      result = stack.use(klass)

      expect(result).to be(stack)
      expect(stack.instance_variable_get(:@middlewares)).to eq([klass])
    end

    it 'permite encadenar múltiples calls' do
      klass_a = Class.new(BugBunny::ConsumerMiddleware::Base)
      klass_b = Class.new(BugBunny::ConsumerMiddleware::Base)

      stack.use(klass_a).use(klass_b)

      expect(stack.instance_variable_get(:@middlewares)).to eq([klass_a, klass_b])
    end

    it 'es thread-safe bajo registros concurrentes' do
      classes = 20.times.map { Class.new(BugBunny::ConsumerMiddleware::Base) }
      threads = classes.map { |klass| Thread.new { stack.use(klass) } }
      threads.each(&:join)

      expect(stack.instance_variable_get(:@middlewares).size).to eq(20)
    end
  end

  describe '#empty?' do
    it 'retorna true cuando no hay middlewares' do
      expect(stack.empty?).to be(true)
    end

    it 'retorna false después de registrar un middleware' do
      stack.use(Class.new(BugBunny::ConsumerMiddleware::Base))
      expect(stack.empty?).to be(false)
    end
  end

  describe '#call' do
    it 'ejecuta el core directamente si no hay middlewares' do
      core_called = false
      stack.call(delivery_info, properties, body) { core_called = true }
      expect(core_called).to be(true)
    end

    it 'ejecuta los middlewares en orden FIFO — el primero registrado envuelve al segundo' do
      log = []
      stack.use(tracking_middleware(log, :a)).use(tracking_middleware(log, :b))

      stack.call(delivery_info, properties, body) { log << :core }

      expect(log).to eq(%i[a_before b_before core b_after a_after])
    end

    it 'pasa delivery_info, properties y body sin modificar al primer middleware' do
      received = {}
      spy = Class.new(BugBunny::ConsumerMiddleware::Base) do
        define_method(:call) do |delivery, props, msg|
          received[:delivery] = delivery
          received[:props]    = props
          received[:body]     = msg
          @app.call(delivery, props, msg)
        end
      end

      stack.use(spy)
      stack.call(delivery_info, properties, body) {}

      expect(received[:delivery]).to be(delivery_info)
      expect(received[:props]).to be(properties)
      expect(received[:body]).to eq(body)
    end

    it 'usa snapshot del array — un use() concurrente no altera la cadena en ejecución' do
      barrier      = Concurrent::CyclicBarrier.new(2)
      intruder_ran = Concurrent::AtomicBoolean.new(false)

      # Middleware lento que se sincroniza con el thread que registra
      slow = Class.new(BugBunny::ConsumerMiddleware::Base) do
        define_method(:call) do |delivery, props, msg|
          barrier.wait
          @app.call(delivery, props, msg)
        end
      end

      intruder = Class.new(BugBunny::ConsumerMiddleware::Base) do
        define_method(:call) do |delivery, props, msg|
          intruder_ran.make_true
          @app.call(delivery, props, msg)
        end
      end

      stack.use(slow)

      call_thread = Thread.new { stack.call(delivery_info, properties, body) {} }

      # Registrar el intruder mientras call está bloqueado en barrier.wait
      barrier.wait
      stack.use(intruder)

      call_thread.join

      # El intruder se registró DESPUÉS del snapshot — no debe haber ejecutado
      expect(intruder_ran.value).to be(false)
    end
  end
end
