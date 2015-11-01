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

#require 'filetest'

module DSPAM
  class DSPAMError < Exception
  end

  # dspam(input, arg1, arg2, ...): Executes the dspam binary with command line
  #                                arguments <arg1>, <arg2>, ... and feeds it the
  #                                string <input> on it's stdin.
  #                                Raises a DSPAMError if the binary exist with
  #                                a non-zero exit code.
  def self.dspam(input, *args)
    # Create the pipes used as stdin,stdout and stderr of the child process
    in_read, in_write = *IO::pipe
    out_read, out_write = *IO::pipe
 
    # Redudant, but improved the error message for the very common case of a wrong path.
    raise DSPAMError::new("Couldn't find dspam executable: #{SXCfg::Default.dspam.command.string}") unless
      FileTest::executable? SXCfg::Default.dspam.command.string

    # fork() forks the whole interpreted, including *all* running threads. We do *not* want any of them
    # to be scheduled in the child, since they probably won't deal with that gracefully.
    begin
      Thread::critical = true
      if (pid = fork).nil? then
        # Running inside the child process now. Close the parent's ends of
        # the pipes, and redirect all IO to in_write and out_read before
        # executing the DSPAM binary.

        in_write.close; out_read.close

        STDIN.reopen(in_read)
        STDOUT.reopen(out_write); STDERR.reopen(out_write)
        in_read.close
        out_write.close

        Kernel::exec(SXCfg::Default.dspam.command.string, *args)
      
        # If exec is successfull, it does not return. Instead, the process
        # calling exec gets *replaced* with the executed binary. Hence,
        # if we get here, an error occured.
        exit(1)
      end
    ensure
      Thread::critical = false
    end

    # Parent process continues here. Close the child's ends of the pipes,
    # and feed <input> to the child before reading it's output and then
    # waiting for it to exit.
    in_read.close; out_write.close
    in_write.write input if input
    in_write.close
    output = out_read.read
    out_read.close
    dummy, status = *Process::waitpid2(pid)

    # Complain if DSPAM returned a non-zero exit code    
    raise DSPAMError::new("#{SXCfg::Default.dspam.command.string} #{args.join(' ')}\n" + output) unless status == 0
  end
   
  # miss_junk(user, sig): Make DSPAM relearn the message with signature <sig> as junk for user <user>
  def self.miss_junk(user, sig)
    dspam(nil, "--client", "--user", user, "--signature=#{sig}", "--source=error", "--class=spam")
  end

  # miss_junk(user, sig): Make DSPAM relearn the message with signature <sig> as innocent for user <user>
  def self.miss_innocent(user, sig)
    dspam(nil, "--client", "--user", user, "--signature=#{sig}", "--source=error", "--class=innocent")
  end

  # miss_junk(user, sig): Feed the junk message <raw> to DSPAM for training purposes. Note *do* *not*
  #                       use this for messages which DSPAM has incorrectly classified as innocent!
  #                       Use miss_junk for that! This method is for training dspam based on a corpus only!
  def self.corpus_junk(user, raw)
    dspam(raw, "--client", "--user", user, "--source=corpus", "--class=spam")
  end

  # miss_innocent(user, sig): Feed the innocent message <raw> to DSPAM for training purposes. Note *do* *not*
  #                           use this for messages which DSPAM has incorrectly classified as junk!
  #                           Use miss_innocent for that! This method is for training dspam based on a corpus only!
  def self.corpus_innocent(user, raw)
    dspam(raw, "--client", "--user", user, "--source=corpus", "--class=innocent")
  end
end
