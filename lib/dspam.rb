#require 'filetest'

module DSPAM
  class DSPAMError < Exception
  end

  def self.dspam(input, *args)
    in_read, in_write = *IO::pipe
    out_read, out_write = *IO::pipe
 
    raise DSPAMError::new("Couldn't find dspam executable: #{SXCfg::Default.dspam.string}") unless
      FileTest::executable? SXCfg::Default.dspam.string

    Thread::critical = true
    if (pid = fork).nil? then
      in_write.close; out_read.close

      STDIN.reopen(in_read)
      STDOUT.reopen(out_write); STDERR.reopen(out_write)
      in_read.close
      out_write.close

      Kernel::exec(SXCfg::Default.dspam.string, *args)
    end

    in_read.close; out_write.close
    in_write.write input if input
    in_write.close
    output = out_read.read
    out_read.close
    dummy, status = *Process::waitpid2(pid)

    raise DSPAMError::new("#{SXCfg::Default.dspam.string} #{args.join(' ')}\n" + output) unless status == 0
  ensure
    Thread::critical = false
  end
   
  def self.miss_junk(user, sig)
    dspam(nil, "--client", "--user", user, "--signature=#{sig}", "--source=error", "--class=spam")
  end

  def self.miss_innocent(user, sig)
    dspam(nil, "--client", "--user", user, "--signature=#{sig}", "--source=error", "--class=innocent")
  end

  def self.corpus_junk(user, raw)
    dspam(raw, "--client", "--user", user, "--source=corpus", "--class=spam")
  end

  def self.corpus_innocent(user, raw)
    dspam(raw, "--client", "--user", user, "--source=corpus", "--class=innocent")
  end
end
