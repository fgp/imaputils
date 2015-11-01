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
        pw_src = File::read(pw_src[1..-1])
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
      case mech
        when "LOGIN" 
          con.login(authz_user, password)
        else
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
       end
    rescue Net::IMAP::NoResponseError
      if auth_user
        STDOUT::puts "    Failed to authorize as #{authz_user} by authenticating as #{auth_user} via #{mech}"
        raise
      else
        STDOUT::puts "    Failed to authenticate as #{authz_user} via #{mech}"
        raise
      end
    end
  end

  def connect_mailboxes
    @src = Net::IMAP::new(SXCfg::Default.imap.src.server.string, SXCfg::Default.imap.src.port.int || 143, SXCfg::Default.imap.src.ssl.bool || false)
    @dst = Net::IMAP::new(SXCfg::Default.imap.dst.server.string, SXCfg::Default.imap.dst.port.int || 143, SXCfg::Default.imap.dst.ssl.bool || false)
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
    
    @prefix_src = SXCfg::Default.imap.src.prefix.string || ""
    @prefix_dst = SXCfg::Default.imap.dst.prefix.string || ""
    
    #Start one thread for each connection, the periodically calls noop
    #This prevents the server from closing the connection because of
    #inactivity.
    @keepalive = true
    
    @src_keepalive = Thread::new do
      i = 0
      while @keepalive
        @src.noop() if i % 10 == 0
        i = (i + 1) % 10
        Kernel::sleep(1)
      end
    end

    @dst_keepalive = Thread::new do
      i = 0
      while @keepalive
        @dst.noop() if i % 10 == 0
        i = (i + 1) % 10
        Kernel::sleep(1)
      end
    end
  end
  
  def disconnect_mailboxes
    @keepalive = false
    @src_keepalive.join if @src_keepalive
    @dst_keepalive.join if @dst_keepalive
    STDOUT::puts "  Disconnect source"
    @src.disconnect if @src
    STDOUT::puts "  Disconnect destination"
    @dst.disconnect if @dst
    STDOUT::puts "  Disconnected"
  end

  def connect_sieves
    return if @src_sieve && @dst_sieve

    @src_sieve = begin
      ManageSieve::new(
        :host => SXCfg::Default.imap.src.server.string,
        :user => SXCfg::Default.imap.src.proxyusr.string,
        :euser => @user_src,
        :password => @pw_src,
        :auth_mech => SXCfg::Default.imap.src.mech.string
      )
    rescue SieveAuthError, SieveCommandError
      if SXCfg::Default.imap.src.proxyusr.string
        STDOUT::puts "    Failed to authorize as #{@user_src} by authenticating as #{SXCfg::Default.imap.src.proxyusr.string} via #{SXCfg::Default.imap.src.mech.string}"
        raise
      else
        STDOUT::puts "    Failed to authenticate as #{@user_src} via #{SXCfg::Default.imap.src.mech.string}"
        raise
      end
    rescue Exception => e
      STDOUT::puts "    Failed to connect to #{SXCfg::Default.imap.src.server.string}: #{e.message} (#{e.class.name})"
      raise
    end
    
    @dst_sieve = begin
      ManageSieve::new(
        :host => SXCfg::Default.imap.dst.server.string,
        :user => SXCfg::Default.imap.dst.proxyusr.string,
        :euser => @user_dst,
        :password => @pw_dst,
        :auth_mech => SXCfg::Default.imap.dst.mech.string
      )
    rescue SieveAuthError, SieveCommandError
      if SXCfg::Default.imap.dst.proxyusr.string
        STDOUT::puts "    Failed to authorize as #{@user_dst} by authenticating as #{SXCfg::Default.imap.dst.proxyusr.string} via #{SXCfg::Default.imap.dst.mech.string}"
        raise
      else
        STDOUT::puts "    Failed to authenticate as #{@user_dst} via #{SXCfg::Default.imap.dst.mech.string}"
        raise
      end
    rescue Exception => e
      STDOUT::puts "    Failed to connect to #{SXCfg::Default.imap.dst.server.string}: #{e.message} (#{e.class.name})"
      raise
    end
  end
  
  def disconnect_sieves
    @src_sieve.logout
    @dst_sieve.logout
  end
    
  def replicate_mailbox
    STDOUT::puts "  Processing mailbox"
    connect_mailboxes

    @mailbox_map = Hash::new
    folders_src = @src.list("", "*").collect do |mbox|
      mbox.name  
    end
    
    folders_src.each do |folder_src|
      skip = false
      SXCfg::Default.folders.ignore.array.each do |ign|
        skip = true if Regexp::new(ign) =~ folder_src
      end
      
      folder_dst = if /\AINBOX\z/i =~ folder_src
        folder_dst = "INBOX"
      else
        f = if (!@prefix_src.empty?) && (folder_src =~ /^#{Regexp::escape(@prefix_src + @delimiter_src)}([^#{Regexp::escape(@delimiter_src)}].*)$/) then
          $1
        else
          folder_src
        end
        
        f = f.split(@delimiter_src).join(@delimiter_dst)
        
        if !@prefix_dst.empty?
          @prefix_dst + @delimiter_dst + f
        else
          f
        end
      end
    
      @mailbox_map[folder_src] = folder_dst
      
      next if skip
      
      repl = ImapFolderReplicator::new(self, folder_src, folder_dst, @dst_dont_delete)
      STDOUT::puts "    Processing folder #{folder_src} -> #{folder_dst}"
      repl.replicate
      STDOUT::puts "    Finished processing #{folder_src} -> #{folder_dst}"
    end
    STDOUT::puts "  Finished processing mailbox"

    disconnect_mailboxes
  rescue Exception => e
    begin
      disconnect_mailboxes
    rescue Exception
    end
    raise e
  end

  def replicate_sieve
    STDOUT::puts "  Processing sieve scripts"
    connect_sieves
    SieveReplicator::new(self, @dst_dont_delete).replicate
    STDOUT::puts "  Finished processing sieve scripts"
  ensure
    disconnect_sieves
  end
end

class SieveReplicator
  def initialize(repl, dst_dont_delete = false)
    @replicator, @dont_delete = repl, dst_dont_delete
  end

  def replicate
    src_scripts = Array::new
    @replicator.src_sieve.scripts do |name, status|
      STDOUT::puts "    Copying script #{name} (#{status == "ACTIVE" ? "Active" : "Inactive"})"
      src_scripts << name
      @replicator.dst_sieve.put_script(name, @replicator.src_sieve.get_script(name))
      @replicator.dst_sieve.set_active(name) if status == "ACTIVE"
    end
    @replicator.dst_sieve.scripts do |name, status|
      if src_scripts.include? name then
        src_scripts.delete(name)
      elsif !@dont_delete
        STDOUT::puts "    Removing script #{name} from destination"
        @replicator.dst_sieve.delete_script(name)
      end
    end
  end
end

class ImapFolderReplicator
  Msg = Struct::new(:uid, :msgid, :flags)

  class MsgId
    include Comparable

    attr_reader :id_str, :id_hash, :descr

    def initialize(envelope)
      @descr = addrlist(envelope.from) + ":" + (envelope.subject || "")
      if envelope.message_id && !envelope.message_id.empty?
        @id_str =
          (envelope.date ? DateTime.parse(envelope.date).to_s : "") + 0.chr +
          (envelope.message_id || "").strip
      else
        @id_str =
          (envelope.date ? DateTime.parse(envelope.date).to_s : "") + 0.chr +
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
    
    def to_s
      @id_str + "(" + @descr + ")"
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
      STDOUT::puts "      Creating folder on destination"
      @replicator.dst.create(@folder_dst)
    end
    
    sub_src_state = @replicator.src.lsub("", @folder_src) 
    sub_src = !(sub_src_state.nil? || sub_src_state.empty?)
    sub_dst_state = @replicator.dst.lsub("", @folder_dst) 
    sub_dst = !(sub_dst_state.nil? || sub_dst_state.empty?)
    if sub_src && !sub_dst
      STDOUT::puts "      Subscription state differs, updating destination state to <subscribed>"
      @replicator.dst.subscribe(@folder_dst)
    elsif !sub_src && sub_dst
      STDOUT::puts "      Subscription state differs, updating destination state to <unsubscribed>"
      @replicator.dst.unsubscribe(@folder_dst)
    end
      
    @replicator.dst.select(@folder_dst)

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
  
  def append_msgs(msgs_data)
    ok = 0
  
    begin
      @replicator.dst.multiappend(@folder_dst, msgs_data)
      ok = msgs_data.length
    rescue Net::IMAP::ResponseError => e
      msgs_data.each do |msg_data|
        begin
          @replicator.dst.append(@folder_dst, *msg_data)
          ok = ok + 1
        rescue Net::IMAP::ResponseError => e
          #Ignore
        end
      end
    end
    
    ok
  rescue Exception => e
    STDERR::puts "ERROR: #{e.inspect}"
    raise
  end
  
  def add_msgs(msgs)
    return if msgs.empty?

    STDOUT::puts "      Destination: Will add #{msgs.length} messages in batches of #{ImapReplicator::AddBatchSize}."
    STDOUT::write "        |"
    total = msgs.length
    failed = 0
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

      failed = failed + msgs_data.length - append_msgs(msgs_data)
      write_percent(total - msgs.length, total, msgs_now.length)
    end
    STDOUT::puts "|"
    STDOUT::write "        WARNING: #{failed} messages couldn't be added" if failed > 0
  end

  def update_msgs(msgs)
    return if msgs.empty?

    STDOUT::puts "      Destination: Will update #{msgs.values.flatten.length} messages to #{msgs.keys.length} different states."
    msgs.each do |flags, msgs|
      next if msgs.empty?

      msgs = msgs.dup
      STDOUT::puts "        Will update #{msgs.length} messages to state [#{flags.join(', ')}] in batches of #{ImapReplicator::ScanBatchSize}"
      STDOUT::write "          |"
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

    STDOUT::puts "      Destination: Will delete #{msgs.length} messages in batches #{ImapReplicator::ScanBatchSize}."
    STDOUT::write "        |"
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

    STDOUT::puts "      #{tag}: Will query #{ids.length} messages in batches of #{ImapReplicator::ScanBatchSize}."
    STDOUT::write "        |"
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
    STDERR::puts "      WARNING: Ignored #{broken_msgs} messages because no unique id could be generated" if broken_msgs > 0
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
    STDOUT::puts "      Computing differences between source and destination"
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
        STDOUT::puts "        WARNING: Duplicate message id #{msgs_src[i_src].msgid.inspect}"
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
#        STDOUT::puts "        INFO: Will add #{msg_src.msgid.to_s}"
        added_msgs << msg_src
        i_src += 1
      else
        #Message was removed on source
#        STDOUT::puts "        INFO: Will remove #{msg_dst.msgid.to_s}"
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

    STDOUT::puts "      #{added_msgs.length} messages added, #{updated_msgs.values.flatten.length} updated and #{removed_msgs.length} removed."
    return [added_msgs, updated_msgs, removed_msgs]    
  end

  def write_percent(done, total, laststep)
    p1 = (10*(done-laststep)/total).to_i
    p2 = (10*done/total).to_i
    STDOUT::write "(#{p2}0%)" if p1 != p2
  end
end