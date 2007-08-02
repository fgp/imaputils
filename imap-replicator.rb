#!/usr/bin/ruby1.8
require 'lib/sxconfig.rb'
require 'lib/imapreplicate.rb'

SXCfg::Default.application = "imap-replicator"

cfgfile, *usrmap = *ARGV

if (
  !cfgfile || cfgfile.empty? || !FileTest::file?(cfgfile) ||
  usrmap.empty?
) then
  STDERR::puts "Usage: imap-replicator <cfgfile> <src usr>:<dst usr> <src usr>:<dst usr> ..."
  exit 1
end

SXCfg::Default.load(ARGV.first)
STDOUT.sync = true

r = 0
usrmap.each do |m|
	unless m =~ /^(.*):(.*)$/ then
		STDERR::puts "Invalid username pair: #{m}"
		r = 1
		next
	end
	srcusr, dstusr = $1, $2
	begin
		STDOUT::puts "Migrating #{srcusr} -> #{dstusr}"
		replicator = ImapReplicator::new(srcusr, dstusr)
		replicator.replicate_mailbox
		replicator.replicate_sieve
		STDOUT::puts "Done migrating #{srcusr} -> #{dstusr}"
	rescue Exception => e
		STDERR::puts "Failed to process #{srcusr} -> #{dstusr}: #{e.message} (#{e.class.name})"
		r = 1
	end		
end
exit r
