#!/usr/bin/ruby1.8
require 'lib/sxconfig'

SXCfg.use("imap-train")

require 'lib/imapprocess'
require 'lib/dspam'

#Net::IMAP.debug = true
STDOUT.sync = true

imapproc = ImapProcessor::new
imapproc.handler_miss_innocent = proc do |user, md|
  puts "    MISS INNOCENT: #{md.signature} (#{md.uid}: #{md.subject})"
  DSPAM::miss_innocent(user, md.signature)
end
imapproc.handler_miss_junk = proc do |user, md|
  puts "    MISS JUNK: #{md.signature} (#{md.uid}: #{md.subject})"
  DSPAM::miss_junk(user, md.signature)
end
imapproc.handler_corpus_innocent = proc do |user, md|
  puts "    CORPUS INNOCENT: #{md.uid}: #{md.subject}"
  DSPAM::corpus_innocent(user, md.raw)
end
imapproc.handler_corpus_junk = proc do |user, md|
  puts "    CORPUS JUNK: #{md.uid}: #{md.subject}"
  DSPAM::corpus_junk(user, md.raw)
end
imapproc.process_users
