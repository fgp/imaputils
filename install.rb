require 'lib/installer'

installer = Installer::new("imaputils")
installer.add_program "imap-replicator.rb", "imap-replicator"
installer.add_program "imap-train.rb", "imap-train"
installer.add_lib "lib/sxconfig.rb"
installer.add_lib "lib/imap.rb"
installer.add_lib "lib/imapstate.rb"
installer.add_lib "lib/imapprocess.rb"
installer.add_lib "lib/imapreplicate.rb"
installer.add_lib "lib/dspam.rb"
installer.add_cfg "imap-train.cfg"
installer.add_cfg "imap-replicator.cfg.template"
installer.add_cfg "rivendell.cfg"
installer.install
