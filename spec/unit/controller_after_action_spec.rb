# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BugBunny::Controller, 'after_action' do
  # Construye un controlador mínimo funcional y lo ejecuta directamente.
  def call_controller(klass, action: :index, body: {})
    klass.call(headers: { action: action.to_s }, body: body)
  end

  describe '.after_action' do
    it 'registra el callback y retorna void' do
      klass = Class.new(BugBunny::Controller)
      klass.after_action :log_after
      expect(klass.after_actions[:_all_actions]).to include(:log_after)
    end

    it 'soporta la opción only: para restringir la acción' do
      klass = Class.new(BugBunny::Controller)
      klass.after_action :log_after, only: [:show]
      expect(klass.after_actions[:show]).to include(:log_after)
      expect(klass.after_actions[:_all_actions]).to be_nil
    end

    it 'no muta la clase padre al registrar en la subclase' do
      parent = Class.new(BugBunny::Controller)
      child  = Class.new(parent)
      child.after_action :child_callback

      expect(parent.after_actions[:_all_actions]).to be_nil
      expect(child.after_actions[:_all_actions]).to include(:child_callback)
    end
  end

  describe 'ejecución' do
    it 'ejecuta el callback después de la acción' do
      log = []
      klass = Class.new(BugBunny::Controller) do
        after_action :record_after
        define_method(:index) { log << :action; render status: 200, json: {} }
        define_method(:record_after) { log << :after }
      end

      call_controller(klass)
      expect(log).to eq(%i[action after])
    end

    it 'ejecuta múltiples after_actions en orden FIFO' do
      log = []
      klass = Class.new(BugBunny::Controller) do
        after_action :first_after
        after_action :second_after
        define_method(:index) { log << :action; render status: 200, json: {} }
        define_method(:first_after)  { log << :first }
        define_method(:second_after) { log << :second }
      end

      call_controller(klass)
      expect(log).to eq(%i[action first second])
    end

    it 'ejecuta after_action después de before_action y de la acción' do
      log = []
      klass = Class.new(BugBunny::Controller) do
        before_action :record_before
        after_action  :record_after
        define_method(:index) { log << :action; render status: 200, json: {} }
        define_method(:record_before) { log << :before }
        define_method(:record_after)  { log << :after }
      end

      call_controller(klass)
      expect(log).to eq(%i[before action after])
    end

    it 'ejecuta after_action dentro del yield de around_action' do
      log = []
      klass = Class.new(BugBunny::Controller) do
        around_action :wrap
        after_action  :record_after
        define_method(:index) { log << :action; render status: 200, json: {} }
        define_method(:record_after) { log << :after }
        define_method(:wrap) { |&blk| log << :around_pre; blk.call; log << :around_post }
      end

      call_controller(klass)
      # after_action corre dentro del yield del around, antes de :around_post
      expect(log).to eq(%i[around_pre action after around_post])
    end

    it 'NO ejecuta after_action si before_action interrumpió con render' do
      log = []
      klass = Class.new(BugBunny::Controller) do
        before_action :halt_early
        after_action  :record_after
        define_method(:index) { log << :action; render status: 200, json: {} }
        define_method(:halt_early)   { render status: 403, json: { error: 'forbidden' } }
        define_method(:record_after) { log << :after }
      end

      call_controller(klass)
      expect(log).to be_empty
    end

    it 'NO ejecuta after_action si la acción lanzó una excepción' do
      log = []
      klass = Class.new(BugBunny::Controller) do
        after_action :record_after
        define_method(:index) { raise 'boom' }
        define_method(:record_after) { log << :after }
      end

      call_controller(klass) # rescue_from genérico devuelve 500
      expect(log).to be_empty
    end

    it 'respeta only: y no ejecuta el callback en otras acciones' do
      log = []
      klass = Class.new(BugBunny::Controller) do
        after_action :record_after, only: [:show]
        define_method(:index) { log << :index_ran; render status: 200, json: {} }
        define_method(:show)  { log << :show_ran;  render status: 200, json: {} }
        define_method(:record_after) { log << :after }
      end

      call_controller(klass, action: :index)
      expect(log).to eq(%i[index_ran])

      log.clear
      call_controller(klass, action: :show)
      expect(log).to eq(%i[show_ran after])
    end

    it 'hereda after_actions del padre y agrega los propios sin mutarlo' do
      log = []
      parent = Class.new(BugBunny::Controller) do
        after_action :parent_after
        define_method(:index) { log << :action; render status: 200, json: {} }
        define_method(:parent_after) { log << :parent }
      end

      child = Class.new(parent) do
        after_action :child_after
        define_method(:child_after) { log << :child }
      end

      call_controller(child)
      expect(log).to eq(%i[action parent child])

      log.clear
      call_controller(parent)
      expect(log).to eq(%i[action parent])
    end
  end
end
