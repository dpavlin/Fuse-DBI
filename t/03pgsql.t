#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;
use blib;

eval "use DBD::Pg";
plan skip_all => "DBD::Pg required for testing" if $@;
plan tests => 12;

use_ok('DBI');
use_ok('Fuse::DBI');

my $test_db = 'test';
my $dsn = "DBI:Pg:dbname=$test_db";
my $mount = '/tmp/fuse_dbi_mnt';

ok((! -e $mount || rmdir $mount), "mount point $mount");

mkdir $mount || die "mkdir $mount: $!";
ok(-d $mount, "mkdir $mount");

ok(my $dbh = DBI->connect($dsn, , '', '', { RaiseError => 1 }),
	"connect fusedbi test database");

my $drop = eval { $dbh->do(qq{ drop table files }) };
diag "drop table files" if ($drop);

ok($dbh->do(qq{
	create table files (
		name text primary key,
		data text
	)
}), "create table files");

ok(my $sth = $dbh->prepare(qq{
	insert into files (name,data) values (?,?)
}), "prepare");

foreach my $file (qw(file dir/file dir/subdir/file)) {
	my $data = "this is test data\n" x length($file);
	ok($sth->execute($file,$data), "insert $file");
}

my $sql_filenames = qq{
	select
		name as id,
		name as filename,
		length(data) as size,
		1 as writable
	from files
};

my $sql_read = qq{
	select data
		from files
		where name = ?;
};

my $sql_update = qq{
	update files
		set data = ?	
		where name = ?;
};

system "fusermount -q -u $mount" || diag "nothing mounted at $mount, ok";

my $mnt = Fuse::DBI->mount({
	filenames => $sql_filenames,
	read => $sql_read,
	update => $sql_update,
	dsn => $dsn,
	mount => $mount,
});

ok($mnt, "mount");

diag "press enter to continue";
my $foo = <STDIN>;

ok($mnt->umount,"umount");

