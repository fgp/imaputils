require 'yaml'

module SXCfg
  CfgPrefix = "/etc/sx"
  EnvPrefix = "SXCONFIG_"

  def self.use(app)
    Default.application = app
    app_envvar = EnvPrefix + app.upcase.tr("-","_")
    app_cfgfile = "#{CfgPrefix}/#{app}.cfg"
    
    if ! ENV[app_envvar].nil? then
      Default.load(ENV[app_envvar])
    elsif File::file? app_cfgfile then
      Default.load(app_cfgfile)
    else
      raise "Set the environment variable '#{app_envvar}', or create '#{app_cfgfile}'"
    end
  end

  class Configurator
    class ConfigurationError < Exception
    end
    class ProgrammingError < Exception
    end

    attr_accessor :application
    
    def initialize(cfg_file = nil)
      load(cfg_file) unless cfg_file.nil?
    end
    
    def load(cfg_file)
      @root = Entry::new(File::open(cfg_file, "r") {|f| YAML::load(f)})
      raise ConfigurationError, "Invalid config file: #{cfg_file}" unless @root
    end
    
    def method_missing(method, *parameters)
      raise ProgrammingError, "No config file loaded - cannot access config" unless @root
      @root.send(method, *parameters)
    end
  end
  Default = Configurator::new

  class Entry
    def initialize(entry)
      @entry = entry
    end
    
    def method_missing(method, *parameters)
      raise Configurator::ProgrammingError, "#{method.to_s} doesn't take parameters" unless
        parameters.empty?
      raise Configurator::ConfigurationError, "#{method.to_s} has to be a map!" unless
        (@entry.kind_of? Hash) || (@entry.nil?)
      return self if @entry.nil?

      Entry::new(@entry[method.to_s])
    end
    
    def [](key)
      raise Configurator::ProgrammingError, "Index has to be Integer or String, not #{key.inspect}" unless
        (key.kind_of? Integer) || (key.kind_of? String)
      raise Configurator::ConfigurationError, "#{method.to_s} has to be a map!" if
        (key.kind_of? String) && !((@entry.kind_of? Hash) || (@entry.nil?))
      raise Configurator::ConfigurationError, "#{method.to_s} has to be a list!" if
        (key.kind_of? Integer) && !((@entry.kind_of? Array) || (@entry.nil?))
      return self if @entry.nil?
      
      Entry::new(@entry[key])
    end
    
    def string
      raise Configurator::ConfigurationError, "String expected, #{@entry.inspect} found" unless
        (@entry.kind_of? Integer) || (@entry.kind_of? String) || (@entry.nil?)
      return nil if @entry.nil?
      @entry.to_s
    end
    
    def int
      raise Configurator::ConfigurationError, "Integer expected, #{@entry.inspect} found" unless
        (@entry.kind_of? Integer) || (@entry.kind_of? String) || (@entry.nil?)
      return nil if @entry.nil?
      @entry.to_i
    end

    def bool
      raise Configurator::ConfigurationError, "Bool expected, #{@entry.inspect} found" unless
        (@entry.kind_of? Integer) || (@entry.kind_of? String) || (@entry.kind_of? TrueClass) || (@entry.kind_of? FalseClass) || (@entry.nil?)
      return nil if @entry.nil?
      return true if @entry.kind_of? TrueClass
      return false if @entry.kind_of? FalseClass
      return true if
        (@entry == true) || (["true", "ja", "yes", "1"].include? @entry) || (@entry.to_s.to_i != 0)
      return false
    end

    def hash
      raise Configurator::ConfigurationError, "Hash expected, #{@entry.inspect} found" unless
        (@entry.nil?) || (@entry.kind_of? Hash)
      return Hash::new if @entry.nil?
      @entry.dup
    end

    def array
      raise Configurator::ConfigurationError, "Array expected, #{@entry.inspect} found" unless
        (@entry.nil?) || (@entry.kind_of? Array)
      return Array::new if @entry.nil?
      @entry.dup
    end
  end
end
