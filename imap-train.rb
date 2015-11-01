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

require 'lib/sxconfig'

SXCfg.use("imap-train")

require 'lib/imapprocess'
require 'lib/dspam'

#Net::IMAP.debug = true
STDOUT.sync = true

imapproc = ImapProcessor::new
imapproc.valid_user = proc do |user|
  return (File::exist? "#{SXCfg::Default.dspam.opt_in.string}/#{user}.dspam")
end
imapproc.handler_miss_innocent = proc do |user, md|
  next if md.signature.nil? || md.signature.empty?
  puts "    MISS INNOCENT: #{md.signature} (#{md.uid}: #{md.subject})"
  DSPAM::miss_innocent(user, md.signature)
end
imapproc.handler_miss_junk = proc do |user, md|
  next if md.signature.nil? || md.signature.empty?
  puts "    MISS JUNK: #{md.signature} (#{md.uid}: #{md.subject})"
  DSPAM::miss_junk(user, md.signature)
end
imapproc.handler_corpus_innocent = proc do |user, md|
  next if md.raw.nil? || md.raw.empty?
  puts "    CORPUS INNOCENT: #{md.uid}: #{md.subject}"
  DSPAM::corpus_innocent(user, md.raw)
end
imapproc.handler_corpus_junk = proc do |user, md|
  next if md.raw.nil? || md.raw.empty?
  puts "    CORPUS JUNK: #{md.uid}: #{md.subject}"
  DSPAM::corpus_junk(user, md.raw)
end
imapproc.process_users
