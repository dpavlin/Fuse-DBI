#!/usr/bin/perl -w

use strict;
use blib;
use Fuse::DBI;

my $template_dir = '/data/WebGUI/cms.rot13.org/uploads/temp/templates';

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
	invalidate => sub {
		print STDERR "invalidating content in $template_dir\n";
		opendir(DIR, $template_dir) || die "can't opendir $template_dir: $!";
		map { unlink "$template_dir/$_" || warn "can't remove $template_dir/$_: $!" } grep { !/^\./ && -f "$template_dir/$_" } readdir(DIR);
		closedir DIR;
	}

});

print "Press enter to exit...";
my $foo = <STDIN>;

$mnt->umount;
