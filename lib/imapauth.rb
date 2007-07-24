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
        @proxy_auth, @authz_user, @auth_user, @password = 
        true, authzuser_or_authuser, authuser_or_password, password
      else
        @proxy_auth, @authz_user, @auth_user, @password =
        false, "", authzuser_or_authuser, authuser_or_password
      end
    end
  end

  # Authenticator for the "PLAIN" authentication type. Supports proxy
  # authentication. See #authenticate().
  class PlainAuthenticator < ProxyAuthenticator
    def process(data)
      return "#{@authz_user}\000#{@auth_user}\000#{@password}"
    end
  end
  Net::IMAPAuth.add_authenticator "PLAIN", PlainAuthenticator

  class DigestMD5Authenticator < ProxyAuthenticator
    class InvalidResponse < Exception
    end
  
    def process(data)
      challenge = parse(data)
      return nil if challenge.include? :rspauth

      raise InvalidResponse::new("Invalid DIGEST-MD5 response, no nonce") unless
        challenge.has_key? :nonce
      raise InvalidResponse::new("Invalid DIGEST-MD5 response, no qop") unless
        challenge.has_key? :qop
      raise InvalidResponse::new("Invalid DIGEST-MD5 response, no algorithm") unless
        challenge.has_key? :algorithm
      raise InvalidResponse::new("Invalid DIGEST-MD5 response, server requests encryption") unless
        challenge[:qop].include? :auth
      raise InvalidResponse::new("Invalid DIGEST-MD5 response, algorithm invalid") unless
        challenge[:algorithm] == "md5-sess"
 
      response = {
        :realm => challenge[:realm] || "none",
        :nonce => challenge[:nonce],
        :cnonce => Digest::MD5.hexdigest(Time.new.to_f.to_s),
        :nc => "00000001",
        :qop => "auth",
	:"digest-uri" => "imap/#{@host}/#{@host}",
        :username => @auth_user
      }
      response[:authzid] = @authz_user if @proxy_auth
      response[:response] = calculate_response(response)
      
      synthesize(response)
    end

    #See RFC2831 if you want to understand this
    def calculate_response(response)
      a1_1 = h("#{@auth_user}:#{response[:realm]}:#{@password}")
      a1 = if @proxy_auth then
        "#{a1_1}:#{response[:nonce]}:#{response[:cnonce]}:#{@authz_user}"
      else
        "#{a1_1}:#{response[:nonce]}:#{response[:cnonce]}"
      end
      
      a2 = "AUTHENTICATE:#{response[:'digest-uri']}"

      hexh("#{hexh(a1)}:#{response[:nonce]}:#{response[:nc]}:#{response[:cnonce]}:#{response[:qop]}:#{hexh(a2)}")
    end
    
    #See RFC2831, it defines those functions
    def h(s); Digest::MD5.digest(s); end
    def hexh(s); Digest::MD5.hexdigest(s); end
    
    def synthesize(response)
      s = []
      response.each do |k,v|
        v = case k
          when :nc then v.to_s
          else "\"#{v.to_s}\""
        end
        s << "#{k.to_s}=#{v}"
      end
      s.join(",")
    end
                                          
    def parse(str)
       r = Hash::new
       while !(str =~ /^\s*$/)
         case str
           when /^(\s*([^\s=]+)\s*=([^",\s]*)\s*(,|$))/
             p, k, v = $1, $2.intern, $3
           when /^(\s*([^\s=]+)\s*=\s*"(([^"]|(\\"))*)"\s*(,|$))/
             p, k, v = $1, $2.intern, $3
             v = v.gsub(/\\(.)/) {$1}
           else
             raise "Couldn't parse response: #{str}"
         end
         v = case k
            when :qop, :cipher then v.split(/,/).collect {|s| s.intern}
            when :maxbuf then v.to_i
            when :stale then (v == "true" ? true : false)
            else v
         end
         case k
           when :realm then r[k] = (r[k] || []) || [v]
           else r[k] = v
         end
         r[k] = v
         str = str[(p.length)..-1]
       end
       return r
    end
  end    
  Net::IMAPAuth.add_authenticator "DIGEST-MD5", DigestMD5Authenticator
end
