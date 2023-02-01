module BugBunny
  module ParserMessage
    def self.humanize_error(errors = {}, scope = nil)
      result = []
      (errors || []).each do |kind, codes|
        result += codes.map do |cod|
          I18n.t(cod,
                 scope: [scope, kind],
                 default: cod.to_s)
        end
      end
      result.flatten.uniq
    end

    def self.humanize_body(response = {}, scope = nil)
      result = {}
      messages = nil
      (response || []).each do |model_id, value|
        next unless value.is_a?(Hash)

        if value.key?(:errors)
          aux = []
          value[:errors].each do |attribute, key_messages|
            key_messages.each do |key_msg|
              error_key = if key_msg.instance_of?(Hash)
                            key_msg[:error]
                          else
                            key_msg
                          end

              if scope.nil?
                aux << error_key
              else
                aux << I18n.t(error_key, scope: ([scope, attribute].join('.')))
              end
            end
          end
          messages = aux.flatten
        end
        result[model_id] = messages if messages.present?
      end
      result
    end

    def self.find_body_errors(msg, scope)
      msg.body.present? ? humanize_body(msg.body, scope) : {}
    end
  end
end
