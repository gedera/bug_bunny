module BugBunny
  module Security
    def self.sign_message(secret, message)
      digest = OpenSSL::Digest.new('SHA512')
      private_key = OpenSSL::PKey::RSA.new(secret)
      Base64.encode64(private_key.sign(digest, message))
    end

    def self.check_sign(key, signature, message)
      pub_key = OpenSSL::PKey::RSA.new(key)
      digest = OpenSSL::Digest.new('SHA512')
      if pub_key.verify(digest, Base64.decode64(signature), message)
        true
      else
        false
      end
    end
  end
end
