#!/usr/bin/perl -w

use strict;
use blib;
use Fuse::DBI;

my $sql_filenames = q{
	select
		concat(templateid,name) as id,
		concat(namespace,'/',name,'.html') as filename,
		length(template) as size,
		iseditable as writable
	from template ;
};

my $sql_read = q{
	select template
		from template
		where concat(templateid,name) = ?;
};

my $sql_update = q{
	update template
		set template = ?	
		where concat(templateid,name) = ?;
};

my $mount = shift || '/mnt2';

my $mnt = Fuse::DBI->mount({
	filenames => $sql_filenames,
	read => $sql_read,
	update => $sql_update,
	dsn => 'DBI:mysql:dbname=webgui_knjiznice_ffzg_hr',
	user => 'webgui',
	password => 'webgui',
	mount => $mount,
});

print "Press enter to exit...";
my $foo = <STDIN>;

$mnt->umount;
