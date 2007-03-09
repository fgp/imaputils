#!/usr/bin/ruby1.8
require 'lib/sxconfig'

SXCfg.use("imap-train")

require 'lib/imapprocess'

imapproc = ImapProcessor::new
imapproc.handler_miss_innocent = proc do |md|
  puts "MISS INNOCENT: #{md.signature} (#{md.uid},#{md.modseq}: #{md.subject})"
end
imapproc.handler_miss_junk = proc do |md|
  puts "MISS JUNK: #{md.signature} (#{md.uid},#{md.modseq}: #{md.subject})"
end
imapproc.handler_corpus_innocent = proc do |md|
  puts "CORPUS INNOCENT: #{md.signature} (#{md.uid},#{md.modseq}: #{md.subject})"
end
imapproc.handler_corpus_junk = proc do |md|
  puts "CORPUS JUNK: #{md.signature} (#{md.uid},#{md.modseq}: #{md.subject})"
end
imapproc.process_users
