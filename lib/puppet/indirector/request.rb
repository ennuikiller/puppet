require 'cgi'
require 'uri'
require 'puppet/indirector'
require 'puppet/util/pson'

# This class encapsulates all of the information you need to make an
# Indirection call, and as a a result also handles REST calls.  It's somewhat
# analogous to an HTTP Request object, except tuned for our Indirector.
class Puppet::Indirector::Request
  attr_accessor :key, :method, :options, :instance, :node, :ip, :authenticated, :ignore_cache, :ignore_terminus

  attr_accessor :server, :port, :uri, :protocol

  attr_reader :indirection_name

  OPTION_ATTRIBUTES = [:ip, :node, :authenticated, :ignore_terminus, :ignore_cache, :instance, :environment]

  # Load json before trying to register.
  Puppet.features.pson? and ::PSON.register_document_type('IndirectorRequest',self)

  def self.from_pson(json)
    raise ArgumentError, "No indirection name provided in json data" unless indirection_name = json['type']
    raise ArgumentError, "No method name provided in json data" unless method = json['method']
    raise ArgumentError, "No key provided in json data" unless key = json['key']

    request = new(indirection_name, method, key, json['attributes'])

    if instance = json['instance']
      klass = Puppet::Indirector::Indirection.instance(request.indirection_name).model
      if instance.is_a?(klass)
        request.instance = instance
      else
        request.instance = klass.from_pson(instance)
      end
    end

    request
  end

  def to_pson(*args)
    result = {
      'document_type' => 'IndirectorRequest',
      'data' => {
        'type' => indirection_name,
        'method' => method,
        'key' => key
      }
    }
    data = result['data']
    attributes = {}
    OPTION_ATTRIBUTES.each do |key|
      next unless value = send(key)
      attributes[key] = value
    end

    options.each do |opt, value|
      attributes[opt] = value
    end

    data['attributes'] = attributes unless attributes.empty?
    data['instance'] = instance if instance

    result.to_pson(*args)
  end

  # Is this an authenticated request?
  def authenticated?
    # Double negative, so we just get true or false
    ! ! authenticated
  end

  def environment
    @environment ||= Puppet::Node::Environment.new
  end

  def environment=(env)
    @environment = if env.is_a?(Puppet::Node::Environment)
      env
    else
      Puppet::Node::Environment.new(env)
    end
  end

  def escaped_key
    URI.escape(key)
  end

  # LAK:NOTE This is a messy interface to the cache, and it's only
  # used by the Configurer class.  I decided it was better to implement
  # it now and refactor later, when we have a better design, than
  # to spend another month coming up with a design now that might
  # not be any better.
  def ignore_cache?
    ignore_cache
  end

  def ignore_terminus?
    ignore_terminus
  end

  def initialize(indirection_name, method, key_or_instance, options_or_instance = {})
    if options_or_instance.is_a? Hash
      options = options_or_instance
      @instance = nil
    else
      options  = {}
      @instance = options_or_instance
    end

    self.indirection_name = indirection_name
    self.method = method

    options = options.inject({}) { |hash, ary| hash[ary[0].to_sym] = ary[1]; hash }

    set_attributes(options)

    @options = options

    if key_or_instance.is_a?(String) || key_or_instance.is_a?(Symbol)
      key = key_or_instance
    else
      @instance ||= key_or_instance
    end

    if key
      # If the request key is a URI, then we need to treat it specially,
      # because it rewrites the key.  We could otherwise strip server/port/etc
      # info out in the REST class, but it seemed bad design for the REST
      # class to rewrite the key.

      if key.to_s =~ /^\w+:\// and not Puppet::Util.absolute_path?(key.to_s) # it's a URI
        set_uri_key(key)
      else
        @key = key
      end
    end

    @key = @instance.name if ! @key and @instance
  end

  # Look up the indirection based on the name provided.
  def indirection
    Puppet::Indirector::Indirection.instance(indirection_name)
  end

  def indirection_name=(name)
    @indirection_name = name.to_sym
  end


  def model
    raise ArgumentError, "Could not find indirection '#{indirection_name}'" unless i = indirection
    i.model
  end

  # Should we allow use of the cached object?
  def use_cache?
    if defined?(@use_cache)
      ! ! use_cache
    else
      true
    end
  end

  # Are we trying to interact with multiple resources, or just one?
  def plural?
    method == :search
  end

  # Create the query string, if options are present.
  def query_string
    return "" unless options and ! options.empty?
    "?" + options.collect do |key, value|
      case value
      when nil; next
      when true, false; value = value.to_s
      when Fixnum, Bignum, Float; value = value # nothing
      when String; value = CGI.escape(value)
      when Symbol; value = CGI.escape(value.to_s)
      when Array; value = CGI.escape(YAML.dump(value))
      else
        raise ArgumentError, "HTTP REST queries cannot handle values of type '#{value.class}'"
      end

      "#{key}=#{value}"
    end.join("&")
  end

  def to_hash
    result = options.dup

    OPTION_ATTRIBUTES.each do |attribute|
      if value = send(attribute)
        result[attribute] = value
      end
    end
    result
  end

  def to_s
    return(uri ? uri : "/#{indirection_name}/#{key}")
  end

  private

  def set_attributes(options)
    OPTION_ATTRIBUTES.each do |attribute|
      if options.include?(attribute.to_sym)
        send(attribute.to_s + "=", options[attribute])
        options.delete(attribute)
      end
    end
  end

  # Parse the key as a URI, setting attributes appropriately.
  def set_uri_key(key)
    @uri = key
    begin
      uri = URI.parse(URI.escape(key))
    rescue => detail
      raise ArgumentError, "Could not understand URL #{key}: #{detail}"
    end

    # Just short-circuit these to full paths
    if uri.scheme == "file"
      @key = Puppet::Util.uri_to_path(uri)
      return
    end

    @server = uri.host if uri.host

    # If the URI class can look up the scheme, it will provide a port,
    # otherwise it will default to '0'.
    if uri.port.to_i == 0 and uri.scheme == "puppet"
      @port = Puppet.settings[:masterport].to_i
    else
      @port = uri.port.to_i
    end

    @protocol = uri.scheme

    if uri.scheme == 'puppet'
      @key = URI.unescape(uri.path.sub(/^\//, ''))
      return
    end

    env, indirector, @key = URI.unescape(uri.path.sub(/^\//, '')).split('/',3)
    @key ||= ''
    self.environment = env unless env == ''
  end
end
