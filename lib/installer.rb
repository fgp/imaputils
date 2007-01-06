require 'fileutils'

class Installer
  attr_accessor :interpreter

  def initialize(app_name)
    @app_name = app_name
    @programs = Hash::new
    @libs = Hash::new
    @cfgs = Hash::new
    @interpreter = "/usr/bin/ruby1.8"
    @bin_path = "/usr/local/bin"
    @lib_path = "/usr/local/lib/#{app_name}"
    @cfg_path = "/etc/#{app_name}"
  end
  
  def add_program(prog_src, prog_inst = nil)
    prog_inst ||= File::basename(prog_src)
    raise "Invalid program: #{prog_src}" unless File::file? prog_src
    raise "Program with name: #{prog_inst} already exists" if
      @programs.has_key? prog_inst
    @programs[prog_inst] = prog_src
  end
  
  def add_lib(lib_src, lib_inst = nil)
    lib_inst ||= lib_src
    raise "Invalid library: #{lib_src}" unless File::file? lib_src
    raise "Library with name: #{lib_inst} already exists" if
      @libs.has_key? lib_inst
    @libs[lib_inst] = lib_src
  end

  def add_cfg(cfg_src, cfg_inst = nil, permissions = 0600)
    cfg_inst ||= File::basename(cfg_src)
    raise "Invalid cfgrary: #{cfg_src}" unless File::file? cfg_src
    raise "Library with name: #{cfg_inst} already exists" if
      @cfgs.has_key? cfg_inst
    @cfgs[cfg_inst] = [cfg_src, permissions]
  end
  
  def install
    FileUtils::mkdir_p(@bin_path)
    FileUtils::mkdir_p(@lib_path)
    FileUtils::mkdir_p(@cfg_path)
    @programs.each_pair do |dst, src|
      STDERR.puts "Program: #{src} -> #{@bin_path}/#{dst}"
      File::open(src, "r") do |src|
        dst_path = @bin_path + "/" + dst
        FileUtils::mkdir_p(File::dirname(dst_path))
        File::open(dst_path, "w+") do |dst|
          dst.puts "#!#{@interpreter} -I#{@lib_path}"
          fline = src.readline.chomp
          dst.puts fline unless fline =~ /^#!/
          src.each_line {|l| dst.puts l}
        end
        File::chmod(0755, dst.path)
      end
    end
    @libs.each_pair do |dst, src|
      STDERR.puts "Lib: #{src} -> #{@lib_path}/#{dst}"
      File::open(src, "r") do |src|
        dst_path = @lib_path + "/" + dst
        FileUtils::mkdir_p(File::dirname(dst_path))
        File::open(dst_path, "w+") do |dst|
          src.each_line {|l| dst.puts l}
        end 
      end
    end
    @cfgs.each_pair do |dst, cfg|
      callcc do |skip|
        src, perms = *cfg
        dst_real = @cfg_path + "/" + dst
        while File::exists? dst_real do
          skip.call if File::read(dst_real) == File::read(src)
          dst_real += ".new"
        end
        FileUtils::mkdir_p(File::dirname(dst_real))
        STDERR.puts "Cfg: #{src} -> #{dst_real}"
        File::open(src, "r") do |src|
          File::open(dst_real, "w+") do |dst|
            dst.chmod(perms)
            src.each_line {|l| dst.puts l}
          end 
        end
      end
    end
  end
end
