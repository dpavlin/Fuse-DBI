#!/usr/bin/perl

use POSIX qw(ENOENT EISDIR EINVAL);
use Fuse;

use DBI;
use strict;

my $sql_filenames = q{
	select
		oid as id,
		namespace||'/'||name||' ['||oid||']' as filename,
		length(template) as size,
		iseditable as writable
	from template ;
};

my $sql_content = q{
	select template
	from template
	where oid = ?;
};


my $connect = "DBI:Pg:dbname=webgui";

my $dbh = DBI->connect($connect,"","") || die $DBI::errstr;

print STDERR "$sql_filenames\n";

my $sth_filenames = $dbh->prepare($sql_filenames) || die $dbh->errstr();
$sth_filenames->execute() || die $sth_filenames->errstr();

my $sth_content = $dbh->prepare($sql_content) || die $dbh->errstr();

print "#",join(",",@{ $sth_filenames->{NAME} }),"\n";

my $ctime_start = time();

my (%files) = (
	'.' => {
		type => 0040,
		mode => 0755,
	},
#	a => {
#		cont => "File 'a'.\n",
#		type => 0100,
#		ctime => time()-2000
#	},
);

my %dirs;

while (my $row = $sth_filenames->fetchrow_hashref() ) {
	$files{$row->{'filename'}} = {
		size => $row->{'size'},
		mode => $row->{'writable'} ? 0644 : 0444,
		id => $row->{'id'} || 99,
	};

	my $d;
	foreach (split(m!/!, $row->{'filename'})) {
		# first, entry is assumed to be file
		if ($d) {
			$files{$d} = {
					size => $dirs{$d}++,
					mode => 0755,
					type => 0040
			};
			$files{$d.'/.'} = {
					mode => 0755,
					type => 0040
			};
			$files{$d.'/..'} = {
					mode => 0755,
					type => 0040
			};
		}
		$d .= "/" if ($d);
		$d .= "$_";
	}
}

print scalar (keys %dirs), " dirs:",join(" ",keys %dirs),"\n";

sub filename_fixup {
	my ($file) = shift;
	$file =~ s,^/,,;
	$file = '.' unless length($file);
	return $file;
}

sub e_getattr {
	my ($file) = filename_fixup(shift);
	$file =~ s,^/,,;
	$file = '.' unless length($file);
	return -ENOENT() unless exists($files{$file});
	my ($size) = $files{$file}{size} || 1;
	my ($dev, $ino, $rdev, $blocks, $gid, $uid, $nlink, $blksize) = (0,0,0,1,0,0,1,1024);
	my ($atime, $ctime, $mtime);
	$atime = $ctime = $mtime = $files{$file}{ctime} || $ctime_start;

	my ($modes) = (($files{$file}{type} || 0100)<<9) + $files{$file}{mode};

	# 2 possible types of return values:
	#return -ENOENT(); # or any other error you care to
	#print(join(",",($dev,$ino,$modes,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks)),"\n");
	return ($dev,$ino,$modes,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks);
}

sub e_getdir {
	my ($dirname) = shift;
	$dirname =~ s!^/!!;
	# return as many text filenames as you like, followed by the retval.
	print((scalar keys %files)." files total\n");
	my %out;
	foreach (keys %files) {
		my $f = $_;
		$f =~ s/^\E$dirname\Q//;
		$f =~ s/^\///;
		if ($dirname) {
			$out{$f}++ if (/^\E$dirname\Q/ && $f =~ /^[^\/]+$/);
		} else {
			$out{$f}++ if ($f =~ /^[^\/]+$/);
		}
		print "f: $_ -> $f\n";
	}
	if (! %out) {
		$out{'no files? bug?'}++;
	}
	print scalar keys %out," files found for '$dirname': ",keys %out,"\n";
	return (keys %out),0;
}

sub e_open {
	# VFS sanity check; it keeps all the necessary state, not much to do here.
	my ($file) = filename_fixup(shift);
	return -ENOENT() unless exists($files{$file});
	return -EISDIR() unless exists($files{$file}{id});
	if (!exists($files{$file}{cont})) {
		$sth_content->execute($files{$file}{id});
		$files{$file}{cont} = $sth_content->fetchrow_array;
	}
	print "open '$file' ",length($files{$file}{cont})," bytes\n";
	return 0;
}

sub e_read {
	# return an error numeric, or binary/text string.
	# (note: 0 means EOF, "0" will give a byte (ascii "0")
	# to the reading program)
	my ($file) = filename_fixup(shift);
	my ($buf,$off) = @_;

	return -ENOENT() unless exists($files{$file});

	my $len = length($files{$file}{cont});

	print "read '$file' [$len bytes] offset $off length $buf\n";

	return -EINVAL() if ($off > $len);
	return 0 if ($off == $len);

	$buf = $len-$off if ($off+$buf > $len);

	return substr($files{$file}{cont},$off,$buf);
}

sub e_statfs { return 255, 1, 1, 1, 1, 2 }

# If you run the script directly, it will run fusermount, which will in turn
# re-run this script.  Hence the funky semantics.
my ($mountpoint) = "";
$mountpoint = shift(@ARGV) if @ARGV;
Fuse::main(
	mountpoint=>$mountpoint,
	getattr=>\&e_getattr,
	getdir=>\&e_getdir,
	open=>\&e_open,
	statfs=>\&e_statfs,
	read=>\&e_read,
	debug=>1,
);
