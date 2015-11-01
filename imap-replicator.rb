#!/usr/bin/ruby1.8
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

# Net::IMAP.debug = true

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
		replicator.replicate_sieve if SXCfg::Default.sieve.replicate.bool
		STDOUT::puts "Done migrating #{srcusr} -> #{dstusr}"
	rescue Exception => e
		STDERR::puts "Failed to process #{srcusr} -> #{dstusr}: #{e.message} (#{e.class.name})"
		STDERR::puts e.backtrace.join("\n")
		r = 1
	end		
end
exit r
