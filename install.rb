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

require 'lib/installer'

installer = Installer::new("imaputils")
installer.add_program "imap-replicator.rb", "imap-replicator"
installer.add_program "imap-train.rb", "imap-train"
installer.add_lib "lib/sxconfig.rb"
installer.add_lib "lib/imap.rb"
installer.add_lib "lib/imapauth.rb"
installer.add_lib "lib/managesieve.rb"
installer.add_lib "lib/imapstate.rb"
installer.add_lib "lib/imapprocess.rb"
installer.add_lib "lib/imapreplicate.rb"
installer.add_lib "lib/dspam.rb"
installer.add_cfg "imap-train.cfg"
installer.add_cfg "imap-replicator.cfg.template"
installer.add_cfg "rivendell.cfg"
installer.add_cfg "mail.brumma.com.cfg"
installer.install
