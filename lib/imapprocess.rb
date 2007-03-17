require 'lib/sxconfig.rb'
require 'lib/imap'
require 'lib/imapstate'

module ImapClient
  #Connections to the server specified in the config file as
  #the given user.
  #Returns a connection, the user (In case it was defaulted
  #for the config file too), and the delimiter.
  def self.login(user=nil)
    user = user || SXCfg::Default.imap.user.string
    imapcon = Net::IMAP::new(SXCfg::Default.imap.server.string)
    pw = SXCfg::Default.imap.password.string
    if pw[0] == ?< then
      pw = File::read(pw[1..-1])
    end
    imapcon.authenticate(
      "PLAIN",
      user,
      SXCfg::Default.imap.user.string,
      pw
    )
    raise ServerError::new("Couldn't determine mailbox hierachy delimiter.") if
      ((r = imapcon.list("", "")).length < 1)
    [imapcon, user, r.first.delim]
  end
end

class ImapProcessor
  attr_accessor :batchsize
  attr_accessor(
    :handler_miss_innocent,
    :handler_miss_junk,
    :handler_corpus_innocent,
    :handler_corpus_junk
  )

  #Process all users that match the given pattern
  def process_users(pattern='%')
    @imapcon, user, delimiter = ImapClient::login
    users = (@imapcon.list(
      "",
      "#{SXCfg::Default.imap.user_prefix.string}#{delimiter}%"
    ).collect do |mbox|
      next nil if mbox.attr.include? :Noselect
      next nil unless mbox.name =~ /^#{Regexp::escape(SXCfg::Default.imap.user_prefix.string+delimiter)}(.*)$/
      $1
    end).compact
    users.each do |user|
      iup = ImapUserProcessor::new(user)
      iup.batchsize = @batchsize if @batchsize
      iup.handler_miss_innocent = @handler_miss_innocent if @handler_miss_innocent
      iup.handler_miss_junk = @handler_miss_junk if @handler_miss_junk
      iup.handler_corpus_innocent = @handler_corpus_innocent if @handler_corpus_innocent
      iup.handler_corpus_junk = @handler_corpus_junk if @handler_corpus_junk
      iup.process_folders
    end
  end
end

class ImapUserProcessor
  class ServerConfigError < Exception
  end
  class ServerError < Exception
  end

  attr_accessor :batchsize
  attr_accessor(
    :handler_miss_innocent,
    :handler_miss_junk,
    :handler_corpus_innocent,
    :handler_corpus_junk
  )

private

  MessageData = Struct::new(
    :uid,
    :modseq,
    :junk,
    :classifiedinnocent,
    :classifiedjunk,
    :signature,
    :subject
  )

  #This class manages retrieval of message flags, and of updating
  #them on the server.
  class MessageData
    FetchData = {
      "FLAGS" => proc do |e, a|
        a["FLAGS"].each do |f|
          next unless FlagData.has_key? f
          e.send(FlagData[f][1], true)
        end
      end,
      "BODY.PEEK[HEADER.FIELDS (X-DSPAM-Signature)]" => proc do |e, a|
        next unless (v = a["BODY[HEADER.FIELDS (X-DSPAM-Signature)]"])
        next unless v =~ /^X-DSPAM-Signature:\s*([A-Za-z0-9]+)\s*$/i
        e.signature = $1
      end,
      "BODY.PEEK[HEADER.FIELDS (Subject)]" => proc do |e, a|
        next unless (v = a["BODY[HEADER.FIELDS (Subject)]"])
        next unless v =~ /^Subject:\s*([^\r\n]*)[\r\n]*$/i
        e.subject = $1
      end
    }

    FlagData = {
      "Junk" => [:junk, :junk=],
      "$ClassifiedInnocent" => [:classifiedinnocent, :classifiedinnocent=],
      "$ClassifiedJunk" => [:classifiedjunk, :classifiedjunk=]
    }

    def self.diff_flags(e_old, e_new)
      added, removed = Array::new, Array::new
      FlagData.each do |flag, sels|
        added << flag if e_new.send(sels.first) && !e_old.send(sels.first)
        removed << flag if !e_new.send(sels.first) && e_old.send(sels.first)
      end
      [added, removed]
    end

    def self.process_messages(con, ids)
      flags_add = Hash::new
      flags_remove = Hash::new
      con.fetch(
        ids,
        ["UID", "MODSEQ"] + FetchData.keys.collect {|k| Net::IMAP::Atom::new(k)}
      ).each do |r|
        e_orig = self::new(r.attr["UID"], r.attr["MODSEQ"].modseq)
        FetchData.each do |k, h|
          h.call(e_orig, r.attr)
        end
        e_new = e_orig.dup
        yield(e_new)
        add, remove = *diff_flags(e_orig, e_new)
        unless add.empty?
          flags_add[add] ||= Array::new
          flags_add[add] << r.seqno
        end
        unless remove.empty?
          flags_remove[remove] ||= Array::new
          flags_remove[remove] << r.seqno
        end
      end
      flags_remove.each { |fs, ids| con.store(ids, "-FLAGS.SILENT", fs) }
      flags_add.each { |fs, ids| con.store(ids, "+FLAGS.SILENT", fs) }
    end
  end

  module AutoPromoteExamineToSelect
    def select(folder, *args)
      @selected = @examined = nil
      r = super(folder, *args)
      @selected = [folder, *args]
      r
    end

    def examine(folder, *args)
      @selected = @examined = nil
      r = super(folder, *args)
      @examined = [folder, *args]
      r
    end

    def store(*args)
      select(*@examined) if @examined
      super(*args)
    end
  end

public

  def initialize(user=nil, limit=nil)
    @imapcon, @user, @delimiter = *ImapClient::login(user)
    class <<@imapcon
      include AutoPromoteExamineToSelect
    end
    @nr_remaining = limit
    @batchsize = 2048
  end
  
  def process_folders
    folders = (@imapcon.list("", "*").collect do |mbox|
      next nil if mbox.attr.include? :Noselect
      mbox.name
    end).compact
    folders.each do |folder|
      break unless !@nr_remaining || (@nr_remaining > 0)
      if SXCfg::Default.folder.junk.array.include? folder
        process_junk_folder(folder)
      elsif SXCfg::Default.folder.ignore.array.include? folder
        next
      else
        process_standard_folder(folder)
      end
    end
  end

  # We retries all messages matching querystr, sorted by MODSEQ.
  # For each message that we processed successfully, set @highestmodseq
  # to the value of the message.
  def process_messages(querystr)
    ids = @imapcon.sort(["MODSEQ"], querystr, "UTF-8")
    return if ids.empty?
    STDOUT::puts "    Will process #{[ids.length, @nr_remaining].compact.min} messages out of #{ids.length} matching in batches of #{@batchsize}."
    ids = ids[0...@nr_remaining] if @nr_remaining

    while !ids.empty?
      ids_now = ids.slice!(0, [ids.length, @batchsize].min)
      STDOUT::puts "    Processing batch of #{ids_now.size} messages."
      MessageData::process_messages(@imapcon, ids_now) do |md|
        yield(md)
        @highestmodseq = md.modseq
        @nr_remaining -= 1 if @nr_remaining
      end
    end
  end

  def process_standard_folder(folder)
    open_folder(folder)

    condition = if (@handler_corpus_junk || @handler_corpus_innocent) &&
       (SXCfg::Default.folder.corpus.array.empty? ||
        (SXCfg::Default.folder.corpus.array.include? folder))
    then
      #Handle corpus for this folder.
      "OR " +
        "(KEYWORD Junk NOT KEYWORD $ClassifiedJunk) " +
        "(NOT KEYWORD Junk NOT KEYWORD $ClassifiedInnocent)"
    else
      #Don't handle corpus for this folder
      "OR " +
        "(KEYWORD Junk KEYWORD $ClassifiedInnocent) " +
        "(NOT KEYWORD Junk KEYWORD $ClassifiedJunk)"
    end

    process_messages(
      "MODSEQ #{@folder_state.highestmodseq} " +
      "NOT DELETED " +
      condition
    ) do |md|
      if md.junk then
        if md.classifiedinnocent then
          @handler_miss_junk.call(md) if @handler_miss_junk
          md.classifiedjunk = true
          md.classifiedinnocent = false
        elsif !md.classifiedinnocent && !md.classifiedjunk && @handler_corpus_junk
          @handler_corpus_junk.call(md)
          md.classifiedjunk = true
          md.classifiedinnocent = false
        end
      else
        if md.classifiedjunk then
          @handler_miss_innocent.call(md) if @handler_miss_innocent
          md.classifiedjunk = false
          md.classifiedinnocent = true
        elsif !md.classifiedinnocent && !md.classifiedjunk && @handler_corpus_innocent
          @handler_corpus_innocent.call(md)
          md.classifiedjunk = false
          md.classifiedinnocent = true
        end
      end
    end

    close_folder
  end

  def process_junk_folder(folder)
    open_folder(folder)    

    condition = if @handler_corpus_junk &&
       (SXCfg::Default.folder.corpus.array.empty? ||
        (SXCfg::Default.folder.corpus.array.include? folder))
    then
      #Handle corpus for this folder.
      "NOT KEYWORD $ClassifiedJunk"
    else
      #Don't handle corpus for this folder
      "KEYWORD $ClassifiedInnocent"
    end

    process_messages(
      "MODSEQ #{@folder_state.highestmodseq} " +
      "NOT DELETED " +
      condition
    ) do |md|
      if md.classifiedinnocent then
        @handler_miss_junk.call(md) if @handler_miss_junk
        md.classifiedjunk = true
        md.classifiedinnocent = false
      elsif !md.classifiedinnocent && !md.classifiedjunk && @handler_corpus_junk
        @handler_corpus_junk.call(md)
        md.classifiedjunk = true
        md.classifiedinnocent = false
      end
    end
    
    close_folder
  end

  def open_folder(folder)
    STDOUT::puts "  Processing #{folder}"

    @folder = folder  
    @folder_state = ImapState::new(@user + "." + folder)

    @imapcon.examine(folder, "CONDSTORE")
    raise ServerError::new("Server reported no UIDVALIDITY for #{folder}") unless
      @imapcon.responses["UIDVALIDITY"] && @imapcon.responses["UIDVALIDITY"][-1]
      
    #Try to activate CONDSTORE.
    unless @imapcon.responses["HIGHESTMODSEQ"] && @imapcon.responses["HIGHESTMODSEQ"][-1]
      STDOUT::puts "    CONDSTORE not available. Trying to fix."
      @imapcon.setannotation(folder, "/vendor/cmu/cyrus-imapd/condstore", "true")
      @imapcon.examine(folder, "CONDSTORE")
      if @imapcon.responses["HIGHESTMODSEQ"] && @imapcon.responses["HIGHESTMODSEQ"][-1]
        STDOUT::puts "    Enabled CONDSTORE for #{folder}."      
      else
        STDOUT::puts "    Couldn't enable CONDSTORE."
        raise ServerConfigError::new("CONDSTORE/MODSEQ couldn't be enabled for #{folder}")
      end
    end

    @uidvalidity = @imapcon.responses["UIDVALIDITY"][-1]
    @highestmodseq = @imapcon.responses["HIGHESTMODSEQ"][-1]
    
    if (@folder_state.uidvalidity != @uidvalidity)
      STDOUT::puts "    UIDVALIDITY changed for #{folder}."
      @highestmodseq = 0
    end
  rescue
     @folder = @folder_state = @uidvalidity = @highestmodseq = nil
     raise
  end
  
  def close_folder
    @folder_state.uidvalidity = @uidvalidity
    @folder_state.highestmodseq = @highestmodseq+1

    #CLOSE does an implicit expunge. We want to avoid that, but
    #at the same time we want to make sure the folder is not
    #selected anymore. We therefor send a bogus EXAMINE command,
    #which according to the RFC should cause the folder to
    #be unselected.
    begin
      @imapcon.examine("")
    rescue Net::IMAP::NoResponseError
    end

    @folder_state.save
    STDOUT::puts "  Finished processing #{@folder}"
  rescue
     @folder = @folder_state = @uidvalidity = @highestmodseq = nil
     raise
  end    
end
