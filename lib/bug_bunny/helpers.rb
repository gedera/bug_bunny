module BugBunny
  module Helpers
    extend self

    def datetime_values_to_utc(data)
      case data
      when Hash
        data.inject({}) {|memo, (k, v)| memo.merge!({k => datetime_values_to_utc(v)}) }
      when Array
        data.map {|e| datetime_values_to_utc(e) }
      when DateTime, Time
        data.to_time.utc.iso8601
      else
        data
      end
    end

    def utc_values_to_local(data)
      case data
      when Hash
        data.inject({}) {|memo, (k, v)| memo.merge!({k => utc_values_to_local(v)}) }
      when Array
        data.map {|e| utc_values_to_local(e) }
      when DateTime, Time
        data.to_time.localtime # ensure we always use Time instances
      when /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:.*Z$/
        t = Time.respond_to?(:zone) ? Time.zone.parse(data) : Time.parse(data)
        t.to_time.localtime
      when /^\d{4}-\d{2}-\d{2}$/
        Date.parse(data)
      else
        data
      end
    end
  end
end
