#
# Copyright (c) 2006 - 2015 Florian G. Pflug
# 
# This file is part of imaputils.
#
# Foobar is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# Foobar is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with Foobar.  If not, see <http://www.gnu.org/licenses/>.

require 'fcntl'
require 'lib/sxconfig.rb'

# ImapState: Persistently stores the uidvalidity, uidnext and highestmodseq
#            of an IMAP folder in the directory <statefolder>
#
#            The persistent store is read during construction, and updated
#            by callind #save.
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
