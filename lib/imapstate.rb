  require 'fcntl'
require 'lib/sxconfig.rb'

class ImapState
  class StateLocked < Exception
  end
  class StateInvalid < Exception
  end

  attr_accessor :uidvalidity, :uidnext, :highestmodseq
  
  def initialize(tag)
    @file = File::open(
      SXCfg::Default.statefolder.string + "/" + tag,
      "a+"
    )
    read_state
  end
  
  def save
    write_state
  end
  
  private
  
  def read_state
    raise FileLocked::new("File #{@file.path} is locked.") unless
      @file.flock(File::LOCK_EX | File::LOCK_NB)
    @uidvalidity = @uidnext = @highestmodseq = nil
    @file.each_line do |line|
      line.chomp!
      raise StateInvalid::new(line) unless
        line =~ /^(uidvalidity|uidnext|highestmodseq):\s*(\d+)$/
      key, val = $1, $2.to_i
      case key
        when "uidvalidity" then
          raise StateInvalid::new(line) if @uidvalidity
          @uidvalidity = val.to_i
        when "uidnext" then
          raise StateInvalid::new(line) if @uidnext
          @uidnext = val.to_i
        when "highestmodseq" then
          raise StateInvalid::new(line) if @highestmodseq
          @highestmodseq = val.to_i
      end
    end
    raise StateInvalid::new("Missing attributes") unless
      @uidvalidity && @uidnext && @highestmodseq
  rescue StateInvalid => e
    @uidvalidity = nil
    @uidnext = @highestmodseq = 0
  end
  
  def write_state
    @file.truncate(0)
    @file.rewind
    @file.puts "uidvalidity: #{@uidvalidity}"
    @file.puts "uidnext: #{@uidnext}"
    @file.puts "highestmodseq: #{@highestmodseq}"
    @file.close
  end
end
