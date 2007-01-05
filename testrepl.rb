#!/usr/bin/ruby1.8
require 'lib/sxconfig.rb'
require 'lib/imapreplicate.rb'

SXCfg.use("imap-replicator")

STDOUT.sync = true
#Net::IMAP.debug = true
repl = ImapReplicator::new("fgp", "fgp", "a")
repl.replicate
#fr = ImapFolderReplicator::new(repl, "Mailinglisten.pgsql-general", "Mailinglisten.pgsql-general")
#fr.replicate
