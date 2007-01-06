#!/usr/bin/ruby1.8
require 'lib/sxconfig'
require 'lib/imapprocess'

SXCfg.use("cyrus-dspam")

#Net::IMAP.debug = true
imap = ImapClient::new("fgp")
imap.handler_miss_innocent = proc do |md|
  puts "MISS INNOCENT: #{md.signature} (#{md.uid},#{md.modseq}: #{md.subject})"
end
imap.handler_miss_junk = proc do |md|
  puts "MISS JUNK: #{md.signature} (#{md.uid},#{md.modseq}: #{md.subject})"
end
imap.handler_corpus_innocent = proc do |md|
  puts "CORPUS INNOCENT: #{md.signature} (#{md.uid},#{md.modseq}: #{md.subject})"
end
imap.handler_corpus_junk = proc do |md|
  puts "CORPUS JUNK: #{md.signature} (#{md.uid},#{md.modseq}: #{md.subject})"
end

imap.process_folders
