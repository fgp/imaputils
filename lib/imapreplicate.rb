require 'lib/imap'

class ImapReplicator
  class ServerError < Exception
  end

  ScanBatchSize = 1024
  AddBatchSize = 64

  attr_reader :src, :dst, :delimiter_src, :delimiter_dst
  attr_accessor :batchsize
  
  def initialize(user_src, user_dst, pw_src = nil, pw_dst = nil)
    @src = Net::IMAP::new(SXCfg::Default.imap.src.server.string)
    @dst = Net::IMAP::new(SXCfg::Default.imap.dst.server.string)
    if !pw_src
      pw_src = SXCfg::Default.imap.src.password.string
      if pw_src[0] == ?< then
        pw_src = File::read(pw_src[1..-1])
      end
    end
    if !pw_dst
      pw_dst = SXCfg::Default.imap.dst.password.string
      if pw_dst[0] == ?< then
        pw_dst = File::read(pw_dst[1..-1])
      end
    end
    @src.authenticate(
      SXCfg::Default.imap.src.mech.string,
      user_src,
      *(
        if !SXCfg::Default.imap.src.user.string
          [pw_src]
        else
          [SXCfg::Default.imap.src.user.string, pw_src]
        end
      )
    )
    @dst.authenticate(
      SXCfg::Default.imap.dst.mech.string,
      user_dst,
      *(
        if !SXCfg::Default.imap.dst.user.string
          [pw_dst]
        else
          [SXCfg::Default.imap.dst.user.string, pw_dst]
        end
      )
    )
    raise ServerError::new("Couldn't determine source mailbox hierachy delimiter.") if
      ((r = @src.list("", "")).length < 1)
    @delimiter_src = r.first.delim
    raise ServerError::new("Couldn't determine destination mailbox hierachy delimiter.") if
      ((r = @dst.list("", "")).length < 1)
    @delimiter_dst = r.first.delim
  end
  
  def replicate
    folders_src = @src.list("", "*").collect do |mbox|
      mbox.name  
    end
    folders_src.each do |folder_src|
      next if SXCfg::Default.folders.ignore.array.include? folder_src
      folder_dst = if @delimiter_src != @delimiter_dst then
        folder_src.tr(@delimiter_dst, "_").tr(@delimiter_src, @delimiter_dst)
      else
        folder_src
      end
      repl = ImapFolderReplicator::new(self, folder_src, folder_dst)
      STDOUT::puts "Processing folder #{folder_src} -> #{folder_dst}"
      repl.replicate
      STDOUT::puts "Finished processing #{folder_src} -> #{folder_dst}"
    end
  end
end

class ImapFolderReplicator
  Msg = Struct::new(:uid, :msgid, :flags)

  class MsgId
    include Comparable

    attr_reader :id_str, :id_hash

    def initialize(envelope)
      if envelope.message_id && !envelope.message_id.empty? then
        @id_str = envelope.message_id
      else
        @id_str =
          (envelope.date || "") + "\0" +
          (envelope.subject || "") + "\0" +
          addrlist(envelope.from) + "\0" +
          addrlist(envelope.to) + "\0" +
          addrlist(envelope.cc) + "\0" +
          addrlist(envelope.bcc)
      end
      @id_hash = @id_str.hash
    end

    def addrlist(ary)
       return "" unless ary
       (ary.collect do |e|
         e.mailbox + "@" + e.host
       end).sort.join(",")
    end

    def hash
      @id_hash
    end

    def <=>(other)
      c = @id_hash <=> other.id_hash
      return c if c != 0
      return @id_str <=> other.id_str 
    end

    def eql?(other)
      return self == other
    end
  end

  def initialize(repl, folder_src, folder_dst)
    @replicator = repl
    @folder_src, @folder_dst = folder_src, folder_dst
  end
  
  def replicate
    @replicator.src.examine(@folder_src)
    begin
      @replicator.dst.select(@folder_dst)
    rescue Net::IMAP::NoResponseError => e
      @replicator.dst.create(@folder_dst)
      @replicator.dst.subscribe(@folder_dst)
      @replicator.dst.select(@folder_dst)
    end
    msgs_src = query_msgs(@replicator.src, "Source")
    msgs_dst = query_msgs(@replicator.dst, "Destination")
    added_msgs, updated_msgs, removed_msgs = *diff_msgs(msgs_src, msgs_dst)
    delete_msgs(removed_msgs)
    update_msgs(updated_msgs)
    add_msgs(added_msgs)
    @replicator.dst.examine(@folder_dst) #Reopen readonly, instead of close,
                                         #to prevent expunge.
    @replicator.src.close()
  end
  
  private
  
  def add_msgs(msgs)
    return if msgs.empty?

    STDOUT::puts "  Destination: Will add #{msgs.length} messages in batches of #{ImapReplicator::AddBatchSize}."
    STDOUT::write "    |"
    total = msgs.length
    while !msgs.empty?
      STDOUT::write "."
      msgs_now = msgs.slice!(0, [msgs.length, ImapReplicator::AddBatchSize].min)
      msgs_data = @replicator.src.uid_fetch(
        msgs_now.collect {|m| m.uid},
        ["BODY.PEEK[]", "INTERNALDATE", "FLAGS"]
      ).collect! do |res|
        next nil unless (res.attr.has_key? "BODY[]") && (!res.attr["BODY[]"].empty?)
        flags = res.attr["FLAGS"].reject {|f| f == :Recent}
        [res.attr["BODY[]"], flags, res.attr["INTERNALDATE"]]
      end
      msgs_data.compact!
      begin
        @replicator.dst.multiappend(@folder_dst, msgs_data)
      rescue Exception => e
        STDOUT::puts "Caught #{e.message} while appending these messages:"
        msgs_data.each do |msg_data|
          msg, flags, date = *msg_data
          STDOUT::puts "--------------------------------------------------------------------------------"
          STDOUT::puts "FLAGS: #{flags.inspect}"
          STDOUT::puts "INTERNALDATE: #{date}"
          STDOUT::puts "BODY:"
          STDOUT::puts msg
          STDOUT::puts "--------------------------------------------------------------------------------"
        end
        raise
      end
      write_percent(total - msgs.length, total, msgs_now.length)
    end
    STDOUT::puts "|"
  end

  def update_msgs(msgs)
    return if msgs.empty?

    STDOUT::puts "  Destination: Will update #{msgs.values.flatten.length} messages to #{msgs.keys.length} different states."
    msgs.each do |flags, msgs|
      next if msgs.empty?

      msgs = msgs.dup
      STDOUT::puts "    Will update #{msgs.length} messages to state [#{flags.join(', ')}] in batches of #{ImapReplicator::ScanBatchSize}"
      STDOUT::write "      |"
      total = msgs.length
      while !msgs.empty?
        STDOUT::write "."
        msgs_now = msgs.slice!(0, [msgs.length, ImapReplicator::ScanBatchSize].min)
        @replicator.dst.uid_store(
          msgs_now.collect {|m| m.uid},
          "FLAGS.SILENT",
          flags
        )
        write_percent(total - msgs.length, total, msgs_now.length)
      end
      STDOUT::puts "|"
    end
  end

  def delete_msgs(msgs)
    return if msgs.empty?

    STDOUT::puts "  Destination: Will delete #{msgs.length} messages in batches #{ImapReplicator::ScanBatchSize}."
    STDOUT::write "    |"
    total = msgs.length
    while !msgs.empty?
      STDOUT::write "."
      msgs_now = msgs.slice!(0, [msgs.length, ImapReplicator::ScanBatchSize].min)
      @replicator.dst.uid_store(
        msgs_now.collect {|m| m.uid},
        "+FLAGS.SILENT",
        [:Deleted]
      )
      @replicator.dst.uid_expunge(msgs_now.collect {|m| m.uid})
      write_percent(total - msgs.length, total, msgs_now.length)
    end
    STDOUT::puts "|"
  end

  def query_msgs(imapcon, tag)
    msgs = Array::new
    ids = imapcon.search("ALL")
    return msgs if ids.empty?

    STDOUT::puts "  #{tag}: Will query #{ids.length} messages in batches of #{ImapReplicator::ScanBatchSize}."
    STDOUT::write "    |"
    total = ids.length
    while !ids.empty?
      STDOUT::write "."
      ids_now = ids.slice!(0, [ids.length, ImapReplicator::ScanBatchSize].min)
      imapcon.fetch(ids_now, [
        "UID",
        "FLAGS",
        "ENVELOPE"
      ]).each do |res|
        flags = (res.attr["FLAGS"].reject {|f| f == :Recent}).sort {|f1, f2| f1.hash <=> f2.hash}
        msgid = MsgId::new(res.attr["ENVELOPE"])
        msgs << Msg::new(res.attr["UID"], msgid, flags)
      end
      write_percent(total - ids.length, total, ids_now.length)
    end
    STDOUT::puts "|"
    return msgs
  end
  
  #The is pretty much standard mergejoin, with one little twist.
  #For the cases where either the msg from src, or the one from dst
  #could be put into the result array, we always choose the one
  #whose UID we'll need later on. For added message, it's the uid
  #in the src folder, since we have to fetch it from there.
  #For updated or deleted msgs, it's the UID in the dst mailbox, since
  #we use that uid to update the msg. For updates there another little
  #subtility, namely that that flags (the hash key) are of course 
  #taken from the src msg.
  def diff_msgs(msgs_src, msgs_dst)
    STDOUT::puts "  Computing differences between source and destination"
    msgs_src.sort! {|m1, m2| m1.msgid <=> m2.msgid}
    msgs_dst.sort! {|m1, m2| m1.msgid <=> m2.msgid}
    
    added_msgs = Array::new
    updated_msgs = Hash::new #[<flags>] = <msglist>
    removed_msgs = Array::new
    unmodified_nr = 0    
 
    i_src, i_dst = 0,0
    while (i_src < msgs_src.length) && (i_dst < msgs_dst.length)
      if (msgs_src[i_src].msgid == msgs_dst[i_dst].msgid)
        #Message exists on both sides
        if (msgs_src[i_src].flags != msgs_dst[i_dst].flags)
          #Same message, different flags
          updated_msgs[msgs_src[i_src].flags] ||= Array::new
          updated_msgs[msgs_src[i_src].flags] << msgs_dst[i_dst]
        end
        i_src += 1
        i_dst += 1
      elsif (msgs_src[i_src].msgid < msgs_dst[i_dst].msgid)
        #Message is missing on destination
        added_msgs << msgs_src[i_dst]
        i_src += 1
      else
        #Message was removed on source
        removed_msgs << msgs_dst[i_dst]
        i_dst += 1
      end
    end
    if (i_dst < msgs_dst.length)
      #Remaining msgs in dst were removed on source
      removed_msgs.concat(msgs_dst[i_dst..-1])
    elsif (i_src < msgs_src.length)
      #Remaining msgs in src are missing on dst
      added_msgs.concat(msgs_src[i_src..-1])
    end

    STDOUT::puts "  #{added_msgs.length} messages added, #{updated_msgs.values.flatten.length} updated and #{removed_msgs.length} removed."
    return [added_msgs, updated_msgs, removed_msgs]    
  end

  def write_percent(done, total, laststep)
    p1 = (10*(done-laststep)/total).to_i
    p2 = (10*done/total).to_i
    STDOUT::write "(#{p2}0%)" if p1 != p2
  end
end