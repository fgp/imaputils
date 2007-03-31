require "digest/md5"

module Net
  class Net::IMAPAuth
    # Adds an authenticator for Net::IMAP#authenticate.  +auth_type+
    # is the type of authentication this authenticator supports
    # (for instance, "LOGIN").  The +authenticator+ is an object
    # which defines a process() method to handle authentication with
    # the server.  See Net::IMAP::LoginAuthenticator and 
    # Net::IMAP::CramMD5Authenticator for examples.
    #
    # If +auth_type+ refers to an existing authenticator, it will be
    # replaced by the new one.
    def self.add_authenticator(auth_type, authenticator)
      @@authenticators ||= Hash::new
      @@authenticators[auth_type] = authenticator
    end

    # Returns the authenticator for +auth_type+
    def self.get_authenticator(auth_type)
      auth_type = auth_type.upcase
      unless @@authenticators.has_key?(auth_type)
        raise ArgumentError,
          format('unknown auth type - "%s"', auth_type)
      end
      @@authenticators[auth_type]
    end
  end

  # Authenticator for the "CRAM-MD5" authentication type.  See
  # #authenticate().
  class CramMD5Authenticator
    def process(challenge)
      digest = hmac_md5(challenge, @password)
      return @user + " " + digest
    end

    def initialize(user, password)
      @user = user
      @password = password
    end

    private

    def hmac_md5(text, key)
      if key.length > 64
        key = Digest::MD5.digest(key)
      end

      k_ipad = key + "\0" * (64 - key.length)
      k_opad = key + "\0" * (64 - key.length)
      for i in 0..63
        k_ipad[i] ^= 0x36
        k_opad[i] ^= 0x5c
      end

      digest = Digest::MD5.digest(k_ipad + text)

      return Digest::MD5.hexdigest(k_opad + digest)
    end
  end
  IMAPAuth::add_authenticator "CRAM-MD5", CramMD5Authenticator

  #Baseclass for Authenticators that support proxy auth.
  class ProxyAuthenticator
    #Can be called with either "user, password" or
    #"authorization_user", "authentication_user", "password".
    #authorization_user: The user whose role you wanto to assume.
    #authentication_user: The user you authenticate as
    #password: The password of the authentication_user.
    #
    # We set:
    #   @authz_user: authorization user (or nil, if no proxy auth is used)
    #   @auth_user:  authentication user
    #   @password:   password of auth_user
    #   @identity: @authz_user\000@auth_user, or @authuser
    def initialize(authzuser_or_authuser, authuser_or_password, password = nil)
      if (password)
        @authz_user, @auth_user, @password = 
        authzuser_or_authuser, authuser_or_password, password
      else
        @authz_user, @auth_user, @password =
        nil, authzuser_or_authuser, authuser_or_password
      end
      if @authz_user
        @identity = @authz_user + "\000" + @auth_user
      else
        @identity = "\000" + @auth_user
      end
    end
  end

  # Authenticator for the "PLAIN" authentication type. Supports proxy
  # authentication. See #authenticate().
  class PlainAuthenticator < ProxyAuthenticator
    def process(data)
      return "#{@identity}\000#{@password}"
    end
  end
  Net::IMAPAuth.add_authenticator "PLAIN", PlainAuthenticator

  class DigestMD5Authenticator < ProxyAuthenticator
    def process(data)
      STDERR::puts data.inspect
      raise "STOP"
    end
  end    
  Net::IMAPAuth.add_authenticator "DIGEST-MD5", DigestMD5Authenticator
end
