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

require 'lib/sxconfig.rb'
require 'lib/imap'
require 'lib/imapstate'

# ImapCLient: Creates an IMAP connection and authenticates as the
#             requested user by using proxy authentication plus the
#             admin username and password from the config file. 
#
#             Returns a triple (connection, user, delimiter)
module ImapClient
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

# ImapProcessor: Creates an ImapUserProcessor instance for
#                every valid user, and uses it to process
#                the user's folders.
#
class ImapProcessor
  attr_accessor :batchsize
  attr_accessor(
    :valid_user,
    :handler_miss_innocent,
    :handler_miss_junk,
    :handler_corpus_innocent,
    :handler_corpus_junk
  )

  # process_user: Process all users that match the given pattern
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
      # Skip users for which the valid_user callback returns false
      next unless @valid_user.call(user)
      
      # Create and setup per-user processor instance, and process
      iup = ImapUserProcessor::new(user)
      iup.batchsize = @batchsize if @batchsize
      iup.handler_miss_innocent = ImapProcessor::handler(user, @handler_miss_innocent) if @handler_miss_innocent
      iup.handler_miss_junk = ImapProcessor::handler(user, @handler_miss_junk) if @handler_miss_junk
      iup.handler_corpus_innocent = ImapProcessor::handler(user, @handler_corpus_innocent) if @handler_corpus_innocent
      iup.handler_corpus_junk = ImapProcessor::handler(user, @handler_corpus_junk) if @handler_corpus_junk
      iup.process_folders
    end
  end

  # handler: Assumes that @h is something callable that takes two parameters,
  #          and binds it's first parameter to <user>, returning a callbacke
  #          that takes only one parameter. For ye haskell junkies:
  #          a -> (a -> b -> c) -> (b -> c)
  def self.handler(user, h)
    proc {|md| h.call(user, md)}
  end
end


# ImapProcessor: Process all folders of a given user, either
#                as junk or as innocent folder, depending
#                on the the junk and innocent folder patterns
#                from the config file.
#
#                Remembers a little bit of state for each
#                folder to be able to quickly skip already
#                processed messages. The state is kept on
#                the server too, though (as IMAP flags).
#                Blowing away the local state will thus
#                slow the next processing run (which will
#                rebuild the state), and not cause any
#                malfunction.
#
#                #batchsize defines the number of messages
#                fetched at once. Large values mean higher
#                memory usage while lower values mean more
#                overhead.
#
#                #handler_{miss,corpus}_{innocent,junk} can
#                be set a a callable to handle the respective
#                case.
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

  # MessageData: Fetches and stores per-message data.
  MessageData = Struct::new(
    :uid,
    :modseq,
    :classifiedinnocent,
    :classifiedjunk,
    :junk,
    :signature,
    :subject,
    :raw
  )
  class MessageData
    # IMAP properties
    attr_accessor :uid, :modseq, :subject, :raw
    
    # IMAP flags
    attr_accessor :classifiedinnocent, :classifiedjunk, :junk
    
    # Defines which message properties are to be queried. For each attribute
    # to be queries, a callback is given that defines how to normalize this
    # attribute's data and how to store it in MessageData instances.
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
      end,
      "BODY.PEEK[]" => proc do |e, a|
        next unless (v = a["BODY[]"])
        e.raw = a["BODY[]"]
      end
    }

    # Maps IMAP flag names to getters and setters of MessageData instances.
    FlagData = {
      "$ClassifiedInnocent" => [:classifiedinnocent, :classifiedinnocent=],
      "$ClassifiedJunk" => [:classifiedjunk, :classifiedjunk=],
      "Junk" => [:junk, :junk=]
    }
    
    def initialize(uid, modseq)
      @uid, @modseq = uid, modseq
    end

    # Compute the changes to a message's flags from <e_old> to <e_new>
    def self.diff_flags(e_old, e_new)
      added, removed = Array::new, Array::new
      FlagData.each do |flag, sels|
        added << flag if e_new.send(sels.first) && !e_old.send(sels.first)
        removed << flag if !e_new.send(sels.first) && e_old.send(sels.first)
      end
      [added, removed]
    end

    # Retrieves the message data for the messages with the given <ids>, and
    # calls the given block once for each message (passing the MessageData
    # instance).
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

  # Mixim for IMAP connections that automatically does a SELECT if
  # a folder was only EXAMINED not SELECTed but a STORE is attempted.
  # The store would otherwise fail, since folders openend with
  # EXAMINE are read-only
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

  # Initialize per-user message processor.
  def initialize(user=nil, limit=nil)
    @imapcon, @user, @delimiter = *ImapClient::login(user)
    class <<@imapcon
      include AutoPromoteExamineToSelect
    end
    @nr_remaining = limit || SXCfg::Default.limits.msgs_per_run.int
    @batchsize = SXCfg::Default.limits.batchsize.int || 8
    
    @ignore_regexps = SXCfg::Default.folder.ignore.array.collect {|p| compile_pattern(p) }
    @junk_regexps = SXCfg::Default.folder.junk.array.collect {|p| compile_pattern(p) }
    @corpus_regexps = SXCfg::Default.folder.corpus.array.collect {|p| compile_pattern(p) }
  end
  
  def compile_pattern(pattern)
    #First, remove any backslash encoding, and add a \0, because
    #otherwise the loop below will miss the last character
    pattern = (pattern.gsub(/\\(.)/) { $1 }) + "\000"
    
    #Anchor regex
    regexp = "\\A"

    #Scan the pattern, in a LL(1) kind of way.
    s = Array::new
    pattern.each_byte do |c|
      s.push c

      next if s.length < 2

      regexp +=
        if (s == [?., ?.]) || (s == [?/, ?/]) || (s == [?*, ?*])
          # ".." means a literal dot, same for "//" and "**"
          s.shift
          Regexp::escape(s.shift.chr)
        elsif (s[0] == ?.) || (s[0] == ?/) #/ - just to fix joe syntax highlighting
          # "." and "/" get converted to the delimiter
          s.shift
          Regexp::escape(@delimiter)
        elsif (s[0] == ?*)
          # "*" means ".*" in regexp-speak
          s.shift
          ".*"
        else
          # Anything else matches itself
          Regexp::escape(s.shift.chr)
        end
    end
    
    #Anchor regex
    regexp += "\\Z"
    
    Regexp::new(regexp)
  end
  
  def match_regexps(regexps, s)
    regexps.each {|r| return true if r =~ s}
    false
  end
  
  # Process all folders, either as junk or as innocent folders depending
  # on the junk regex. Skip folders matching the ignore regex, and enable
  # corpus training for folders matching the corpus regex
  def process_folders
    STDOUT::puts "Processing user #{@user} (Max msgs: #{@nr_remaining}, Batchsize:#{@batchsize})"
    folders = (@imapcon.list("", "*").collect do |mbox|
      next nil if mbox.attr.include? :Noselect
      mbox.name
    end).compact
    folders.each do |folder|
      break unless !@nr_remaining || (@nr_remaining > 0)

      if match_regexps(@ignore_regexps, folder)
        next
      elsif match_regexps(@junk_regexps, folder)
        process_junk_folder(folder, match_regexps(@corpus_regexps, folder))
      else
        process_innocent_folder(folder, match_regexps(@corpus_regexps, folder))
      end
    end
  end

  # We retries all messages matching querystr, sorted by MODSEQ,
  # which were modified after we last changed the folder.
  # For each message that we processed successfully, set @highestmodseq
  # to the value of the message.
  def process_messages(querystr)
    ids_pending = @imapcon.sort(
      ["MODSEQ"],
      "MODSEQ #{@folder_state.highestmodseq+1} " +
      querystr,
      "UTF-8"
    )

    # Do not exceed the message processing budget by clamping
    # the number of to-be-processed messages to the remaining
    # message "credit".
    # NOTE: It's absolutely essential that messages with
    # lower modseqs are processed first! Otherwise, the
    # per-folder highestmodseq tracking logic is all wrong!
    if @nr_remaining
      ids = ids_pending[0...@nr_remaining]
    else
      ids = ids_pending
    end

    if !ids_pending.empty?
      STDOUT::puts "    Will process #{ids.length} messages out of #{ids_pending.length} matching in batches of #{@batchsize}."
      
      # Process the messages in batches to avoid memory exhaustion
      while !ids.empty?
        # Get first @batchsize messages (or all if fewer), and
        # process.
        # NOTE: It's again absolutely essential to process the
        # message in the order of their modseqs!
        ids_now = ids.slice!(0, [ids.length, @batchsize].min)
        STDOUT::puts "    Processing batch of #{ids_now.size} messages."
        MessageData::process_messages(@imapcon, ids_now) do |md|
          # Invoke per-message callback
          yield(md)
          
          # Update folder state
          # NOTE: We process the messages in the order defined
          # by their modseq.
          @folder_state.highestmodseq = md.modseq
          @nr_remaining -= 1 if @nr_remaining
        end
      end
    end

    # We want the folder state's and the IMAP servers idea
    # of the current value of highestmodseq to match, since
    # that allows to quickly skip unchanged folders during
    # folder scanning. Increasing the folder state's
    # highestmodseq per message is insufficient for that
    # purpose, since the message with the highest modseq is
    # not necessary part of our SEARCH result.
    # Hence, *if* we're sure that we process *all* pending
    # messages, we force the folder state's highestmodseq to
    # match the value reported by the IMAP server.
    #
    # This is also the right time to update uidnext at.
    if ids_pending.length == ids.length then
      @folder_state.highestmodseq = @highestmodseq
      @folder_state.uidnext = @uidnext
    end
  end

  def process_innocent_folder(folder, corpus)
    return unless open_folder(folder, corpus ? "NonJunk,Corpus" : "NonJunk")

    condition = if (@handler_corpus_junk || @handler_corpus_innocent) && corpus
      #Handle corpus for this folder.
      "NOT KEYWORD $ClassifiedInnocent NOT KEYWORD $ClassifiedJunk"
    else
      #Don't handle corpus for this folder
      "KEYWORD $ClassifiedJunk"
    end

    process_messages(
      "NOT DELETED " +
      condition
    ) do |md|
      if md.classifiedjunk && @handler_miss_innocent
        @handler_miss_innocent.call(md)
        md.classifiedjunk = false
        md.classifiedinnocent = true
        #For conveniance, remove the "Junk" flag if it's set. This should suppress
        #the "Junk" icon Thunderbird displays if you move a message from the Junk-Folder
        #to any other folder.
        md.junk = false
      elsif !md.classifiedinnocent && !md.classifiedjunk && @handler_corpus_innocent
        @handler_corpus_innocent.call(md)
        md.classifiedjunk = false
        md.classifiedinnocent = true
      end
    end
    
    close_folder
  rescue Exception => e
    close_folder(e)
  end

  def process_junk_folder(folder, corpus)
    return unless open_folder(folder, corpus ? "Junk,Corpus" : "Junk")    

    condition = if @handler_corpus_junk && corpus
      #Handle corpus for this folder.
      "NOT KEYWORD $ClassifiedJunk"
    else
      #Don't handle corpus for this folder
      "KEYWORD $ClassifiedInnocent"
    end

    process_messages(
      "NOT DELETED " +
      condition
    ) do |md|
      if md.classifiedinnocent && @handler_miss_junk
        @handler_miss_junk.call(md)
        md.classifiedjunk = true
        md.classifiedinnocent = false
      elsif !md.classifiedinnocent && !md.classifiedjunk && @handler_corpus_junk
        @handler_corpus_junk.call(md)
        md.classifiedjunk = true
        md.classifiedinnocent = false
      end
    end
    
    close_folder
  rescue Exception => e
    close_folder(e)
  end
 
  # Opens a folder.
  # If nothing seems to have changed, the folder is _not_ selected,
  # and false is returned. Otherwise the folder is selected read-only
  # and true is returned.
  def open_folder(folder, type)
    STDOUT::puts "  Checking #{folder} (#{type})"

    @folder = folder  
    @folder_state = ImapState::new(@user + "." + folder)

    resp = @imapcon.status(folder, ["UIDVALIDITY", "UIDNEXT", "HIGHESTMODSEQ"])
      
    # Try to activate CONDSTORE.
    unless resp["HIGHESTMODSEQ"] && (resp["HIGHESTMODSEQ"] > 0)
      STDOUT::puts "    CONDSTORE not available. Trying to fix."
      @imapcon.setannotation(folder, "/vendor/cmu/cyrus-imapd/condstore", "true")
      resp = @imapcon.status(folder, ["UIDVALIDITY", "UIDNEXT", "HIGHESTMODSEQ"])
      if resp["HIGHESTMODSEQ"] && (resp["HIGHESTMODSEQ"] > 0)
      then
        STDOUT::puts "    Enabled CONDSTORE for #{folder}."      
      else
        STDOUT::puts "    Couldn't enable CONDSTORE."
        raise ServerConfigError::new("CONDSTORE/MODSEQ couldn't be enabled for #{folder}")
      end
    end

    # If no new messages were stored (UIDNEXT check), and none
    # if the existing onces where modified (HIGHESTMODSWQ)
    # changed, skip the folder.
    if
      (@folder_state.uidvalidity == resp["UIDVALIDITY"]) &&
      (@folder_state.uidnext == resp["UIDNEXT"]) &&
      (@folder_state.highestmodseq == resp["HIGHESTMODSEQ"])
    then
      @folder = @folder_state = nil
      return false
    end

    # Something changed. Open folder in read-only mode.
    STDOUT::puts "  Processing #{folder}"
    @imapcon.examine(folder, "CONDSTORE")
    @uidvalidity = @imapcon.responses["UIDVALIDITY"][-1]
    @uidnext = @imapcon.responses["UIDNEXT"][-1]
    @highestmodseq = @imapcon.responses["HIGHESTMODSEQ"][-1]
    
    # Deal with uidvalidity changes. Simply forget all local
    # state in that case.
    if (@folder_state.uidvalidity != @uidvalidity)
      STDOUT::puts "    UIDVALIDITY changed for #{folder}."
      @folder_state.uidvalidity = @uidvalidity
      @folder_state.uidnext = @folder_state.highestmodseq = 0
    end

    return true
  rescue
     @folder = @folder_state = @uidvalidity = @uidnext = @highestmodseq = nil
     raise
  end
  
  def close_folder(error = nil)
    # If @folder is nil, we just write an error message if error is set.
    error_message = error.message.gsub(/\n/, "\n    ") if error
    unless @folder
      STDOUT::puts "  Error processing folder #{@folder}\n    #{error_message}\n" if error
      return
    end
      
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
    if error == nil
      STDOUT::puts "  Finished processing #{@folder}"
    else
      msg = error.message.gsub(/\n/, "\n    ")
      STDOUT::puts "  Error processing folder #{@folder}\n    #{msg}\n"
    end
  ensure
     @folder = @folder_state = @uidvalidity = @uidnext = @highestmodseq = nil
  end    
end
