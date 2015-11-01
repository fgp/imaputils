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

require 'termios'
require 'lib/imap'
require 'lib/imapauth'

def usage
  STDERR::puts "Usage: imap-showflags <server> <user> [<pwfile>] <folder>"
  exit 1
end

$server, $user, $folder_or_pwfile, $folder = *ARGV

if $folder then
  $pwfile = $folder_or_pwfile
else
  $pwfile = nil
  $folder = $folder_or_pwfile
end

usage if !$server || $server.empty? || !$user || $user.empty? || !$folder || $folder.empty?

if STDIN.isatty
  STDOUT.write "Password: " if STDOUT.isatty
  o = Termios::getattr(STDIN)
  begin
    n = o.dup
    n.c_lflag &= ~Termios::ECHO
    Termios::setattr(STDIN, Termios::TCSANOW, n)
    $password = STDIN::readline.chomp
  ensure
    Termios::setattr(STDIN, Termios::TCSANOW, o)
  end
  STDOUT.write "\n"
elsif $pwfile && !$pwfile.empty?
  $password = File::read($pwfile)
else
  usage
end

Server = Net::IMAP::new($server)
Server.authenticate("DIGEST-MD5", $user, $password)
Server.select($folder)

Server.fetch(1..-1, [Net::IMAP::Atom::new("BODY.PEEK[HEADER.FIELDS (SUBJECT)]"), Net::IMAP::Atom::new("FLAGS")]).each do |res|
  STDOUT.write res.attr["BODY[HEADER.FIELDS (SUBJECT)]"].gsub(/\r|\n/, "") + " (" + (res.attr["FLAGS"].collect {|f| f.to_s}).join(", ") + ")\n"
end
