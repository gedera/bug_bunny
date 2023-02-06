module BugBunny
  class Queue
    attr_accessor :name, :auto_delete, :durable, :exclusive, :rabbit_queue

    def initialize(attrs={})
      # "Real" queue  opts
      @name        = attrs.fetch(:name, 'undefined')
      @auto_delete = attrs.fetch(:auto_delete, true)
      @durable     = attrs.fetch(:durable, false)
      @exclusive   = attrs.fetch(:exclusive, false)
    end

    def options
      { durable: durable, exclusive: exclusive, auto_delete: auto_delete }
    end

    def check_consumers
      rabbit_queue.consumer_count
    rescue StandardError
      0
    end
  end
end
