require 'lib/imap'
require 'lib/managesieve'

class ImapReplicator
  class ServerError < Exception
  end

  ScanBatchSize = 1024
  AddBatchSize = 64

  attr_reader :src, :dst, :delimiter_src, :delimiter_dst, :src_sieve, :dst_sieve
  attr_accessor :batchsize
  
  def initialize(user_src, user_dst, pw_src = nil, pw_dst = nil)
    @dst_dont_delete = SXCfg::Default.imap.dst.dont_delete.bool
    if !pw_src
      pw_src = SXCfg::Default.imap.src.proxypwd.string
      if pw_src[0] == ?< then
        @pw_src = File::read(pw_src[1..-1])
      end
    end
    if !pw_dst
      pw_dst = SXCfg::Default.imap.dst.proxypwd.string
      if pw_dst[0] == ?< then
        pw_dst = File::read(pw_dst[1..-1])
      end
    end
    @user_src, @user_dst, @pw_src, @pw_dst = user_src, user_dst, pw_src, pw_dst
  end

  def authenticate_mailbox(con, mech, authz_user, auth_user, password)
    begin
      con.authenticate(
        mech,
        authz_user,
        *(
          if !auth_user
            [password]
          else
            [auth_user, password]
          end
        )
      )
    rescue Net::IMAP::NoResponseError
      if auth_user
        STDOUT::puts "Failed to authorize as #{authz_user} by authenticating as #{auth_user} via #{mech}"
        raise
      else
        STDOUT::puts "Failed to authenticate as #{authz_user} via #{mech}"
        raise
      end
    end
  end

  def connect_mailboxes
    @src = Net::IMAP::new(SXCfg::Default.imap.src.server.string)
    @dst = Net::IMAP::new(SXCfg::Default.imap.dst.server.string)
    authenticate_mailbox(
      @src,
      SXCfg::Default.imap.src.mech.string,
      @user_src,
      SXCfg::Default.imap.src.proxyusr.string,
      @pw_src
    )
    authenticate_mailbox(
      @dst,
      SXCfg::Default.imap.dst.mech.string,
      @user_dst,
      SXCfg::Default.imap.dst.proxyusr.string,
      @pw_dst
    )

    raise ServerError::new("Couldn't determine source mailbox hierachy delimiter.") if
      ((r = @src.list("", "")).length < 1)
    @delimiter_src = r.first.delim
    raise ServerError::new("Couldn't determine destination mailbox hierachy delimiter.") if
      ((r = @dst.list("", "")).length < 1)
    @delimiter_dst = r.first.delim
  end

  def connect_sieves
    return if @src_sieve && @dst_sieve

    @src_sieve = ManageSieve::new(
      :host => SXCfg::Default.imap.src.server.string,
      :user => SXCfg::Default.imap.src.proxyusr.string,
      :euser => @user_src,
      :password => @pw_src,
      :auth_mech => SXCfg::Default.imap.src.mech.string
    )
    @dst_sieve = ManageSieve::new(
      :host => SXCfg::Default.imap.dst.server.string,
      :user => SXCfg::Default.imap.dst.proxyusr.string,
      :euser => @user_dst,
      :password => @pw_dst,
      :auth_mech => SXCfg::Default.imap.dst.mech.string
    )
  end
    
  
  def replicate_mailbox
    connect_mailboxes

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
      repl = ImapFolderReplicator::new(self, folder_src, folder_dst, @dst_dont_delete)
      STDOUT::puts "Processing folder #{folder_src} -> #{folder_dst}"
      repl.replicate
      STDOUT::puts "Finished processing #{folder_src} -> #{folder_dst}"
    end
  end

  def replicate_sieve
    connect_sieves

    STDOUT::puts "Processing sieve scripts"
    SieveReplicator::new(self, @dst_dont_delete).replicate
    STDOUT::puts "Finished processing sieve scripts"
  end
end

class SieveReplicator
  def initialize(repl, dst_dont_delete = false)
    @replicator, @dont_delete = repl, dst_dont_delete
  end

  def replicate
    src_scripts = Array::new
    @replicator.src_sieve.scripts do |name, status|
      STDOUT::puts "  Copying script #{name} (#{status == "ACTIVE" ? "Active" : "Inactive"})"
      src_scripts << name
      @replicator.dst_sieve.put_script(name, @replicator.src_sieve.get_script(name))
      @replicator.dst_sieve.set_active(name) if status == "ACTIVE"
    end
    @replicator.dst_sieve.scripts do |name, status|
      if src_scripts.include? name then
        src_scripts.delete(name)
      elsif !@dont_delete
        STDOUT::puts "  Removing script #{name} from destination"
        @replicator.dst_sieve.delete_script(name)
      end
    end
  end
end

class ImapFolderReplicator
  Msg = Struct::new(:uid, :msgid, :flags)

  class MsgId
    include Comparable

    attr_reader :id_str, :id_hash

    def initialize(envelope)
      if envelope.message_id && !envelope.message_id.empty?
        @id_str =
          (envelope.date || "") + 0.chr +
          (envelope.message_id || "")
      else
        @id_str =
          (envelope.date || "") + 0.chr +
          (envelope.subject || "") + 0.chr +
          addrlist(envelope.from) + 0.chr +
          addrlist(envelope.to) + 0.chr +
          addrlist(envelope.cc) + 0.chr +
          addrlist(envelope.bcc)
      end
      @id_hash = @id_str.hash
    end

    def addrlist(ary)
       return "" unless ary
       (ary.collect do |e|
         next nil unless e.mailbox && e.host
         e.mailbox + "@" + e.host
       end).compact.sort.join(",")
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

  def initialize(repl, folder_src, folder_dst, dont_delete = false)
    @replicator = repl
    @folder_src, @folder_dst = folder_src, folder_dst
    @dont_delete = dont_delete
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
    added_msgs, updated_msgs, removed_msgs = *diff_msgs(
      msgs_src,
      msgs_dst,
      folder_flags_add(@folder_dst),
      folder_flags_remove(@folder_dst)
    )
    delete_msgs(removed_msgs) unless @dont_delete
    update_msgs(updated_msgs)
    add_msgs(added_msgs)

    #CLOSE does an implicit expunge. We want to avoid that, but
    #at the same time we want to make sure the folder is not
    #selected anymore. We therefor send a bogus EXAMINE command,
    #which according to the RFC should cause the folder to
    #be unselected.
    begin
      @replicator.src.examine("")
    rescue Net::IMAP::NoResponseError
    end
    begin
      @replicator.dst.examine("")
    rescue Net::IMAP::NoResponseError
    end
  end
  
  private

  def folder_flags_add(folder)
    flags = Array::new
    SXCfg::Default.folders.flags.hash.each do |flag, folders|
      next unless flag =~ /^\+(.*)$/
      flag = $1
      next unless (folders.include? folder) || (folders.include? "*")
      flags << flag
    end
    flags
  end

  def folder_flags_remove(folder)
    flags = Array::new
    SXCfg::Default.folders.flags.hash.each do |flag, folders|
      next unless flag =~ /^\-(.*)$/
      flag = $1
      next unless (folders.include? folder) || (folders.include? "*")
      flags << flag
    end
    flags
  end
  
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
    broken_msgs = 0
    while !ids.empty?
      STDOUT::write "."
      ids_now = ids.slice!(0, [ids.length, ImapReplicator::ScanBatchSize].min)
      imapcon.fetch(ids_now, [
        "UID",
        "FLAGS",
        "ENVELOPE"
      ]).each do |res|
        if (!res.attr.has_key? "ENVELOPE") || (res.attr["ENVELOPE"].nil?)
          broken_msgs += 1
          next
        end
        flags = (res.attr["FLAGS"].reject {|f| f == :Recent}).sort {|f1, f2| f1.hash <=> f2.hash}
        msgid = MsgId::new(res.attr["ENVELOPE"])
        msgs << Msg::new(res.attr["UID"], msgid, flags)
      end
      write_percent(total - ids.length, total, ids_now.length)
    end
    STDOUT::puts "|"
    STDERR::puts "  WARNING: Ignored #{broken_msgs} messages because no unique id could be generated" if broken_msgs > 0
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
  def diff_msgs(msgs_src, msgs_dst, add_flags=[], remove_flags=[])
    STDOUT::puts "  Computing differences between source and destination"
    msgs_src.sort! {|m1, m2| m1.msgid <=> m2.msgid}
    msgs_dst.sort! {|m1, m2| m1.msgid <=> m2.msgid}
    
    added_msgs = Array::new
    updated_msgs = Hash::new #[<flags>] = <msglist>
    removed_msgs = Array::new
    unmodified_nr = 0    
 
    i_src, i_dst = 0,0
    while (i_src < msgs_src.length) && (i_dst < msgs_dst.length)
      #Skip messages with the same id as their predecessor
      if (i_src > 0) && (msgs_src[i_src-1].msgid == msgs_src[i_src].msgid)
        i_src += 1
        next
      end

      #Pretend that the flags in add_flags are set on the src msg,
      #and flags in remove_flags are not
      msg_src = msgs_src[i_src].dup
      msg_src.flags = msg_src.flags.dup
      msg_src.flags.push(*add_flags)
      msg_src.flags.reject! {|f| remove_flags.include? f}
      msg_dst = msgs_dst[i_dst].dup

      if (msg_src.msgid == msg_dst.msgid)
        #Message exists on both sides
        flags_src = msg_src.flags.sort {|a,b| a.to_s <=> b.to_s}
        flags_dst = msg_dst.flags.sort {|a,b| a.to_s <=> b.to_s}
        if (flags_src != flags_dst)
          #Same message, different flags
          updated_msgs[msg_src.flags] ||= Array::new
          updated_msgs[msg_src.flags] << msg_dst
        end
        i_src += 1
        i_dst += 1
      elsif (msg_src.msgid < msg_dst.msgid)
        #Message is missing on destination
        added_msgs << msg_src
        i_src += 1
      else
        #Message was removed on source
        removed_msgs << msg_dst
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