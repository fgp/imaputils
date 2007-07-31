#!/usr/bin/ruby1.8
require 'lib/sxconfig.rb'
require 'lib/imapreplicate.rb'

SXCfg::Default.application = "imap-replicator"

cfgfile, srcuser, dstuser, srcpwd, dstpwd = *ARGV
dstuser ||= srcuser
srcpwd = nil if srcpwd && srcpwd.empty?
dstpwd = nil if dstpwd && dstpwd.empty?

if (
  !cfgfile || cfgfile.empty? || !FileTest::file?(cfgfile) ||
  !srcuser || srcuser.empty? ||
  !dstuser || dstuser.empty?
) then
  STDERR::puts "Usage: imap-replicator <cfgfile> <source user> <destination user>"
  exit 1
end

SXCfg::Default.load(ARGV.first)
STDOUT.sync = true

Net::IMAP::Debug = true
replicator = ImapReplicator::new(srcuser, dstuser, srcpwd, dstpwd)
replicator.replicate_sieve
replicator.replicate_mailbox
