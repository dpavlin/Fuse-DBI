use 5.008;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'Fuse::DBI',
    VERSION_FROM      => 'DBI.pm', # finds $VERSION
    PREREQ_PM         => {
	'POSIX' => 0,
    	'Fuse' => 0,
	'DBI' => 0,
	'Carp' => 0,
    }, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'DBI.pm', # retrieve abstract from module
       AUTHOR         => 'Dobrica Pavlinusic <dpavlin@rot13.org>') : ()),
);

sub MY::postamble {
	return <<'MAKE_MORE';

mount:
	mkdir -f /tmp/db
	sudo modprobe fuse
	sudo umount /tmp/db || exit 0
	./fuse_dbi.pl /tmp/db
	sudo umount /tmp/db

html: DBI.pm
	pod2html DBI.pm > DBI.html
	pod2html examples/webgui.pl > WebGUI.html
	rm pod2htm?.tmp

MAKE_MORE
}
