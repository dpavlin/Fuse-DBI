#!/usr/bin/perl -w

use strict;
use blib;
use Fuse::DBI;

my $sql_filenames = q{
	select
		oid as id,
		namespace||'/'||name||' ['||oid||']' as filename,
		length(template) as size,
		iseditable as writable
	from template ;
};

my $sql_read = q{
	select template
		from template
		where oid = ?;
};

my $sql_update = q{
	update template
		set template = ?	
		where oid = ?;
};

Fuse::DBI->run({
	filenames => $sql_filenames,
	read => $sql_read,
	update => $sql_update,
	dsn => 'DBI:Pg:dbname=webgui',
});
