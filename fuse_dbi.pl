#!/usr/bin/perl

use POSIX qw(ENOENT EISDIR EINVAL ENOSYS O_RDWR);
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


my $connect = "DBI:Pg:dbname=webgui";

my $dbh = DBI->connect($connect,"","", { AutoCommit => 0 }) || die $DBI::errstr;

print "start transaction\n";
#$dbh->begin_work || die $dbh->errstr;

my $sth_filenames = $dbh->prepare($sql_filenames) || die $dbh->errstr();
$sth_filenames->execute() || die $sth_filenames->errstr();

my $sth_read = $dbh->prepare($sql_read) || die $dbh->errstr();
my $sth_update = $dbh->prepare($sql_update) || die $dbh->errstr();

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

print "found ",scalar(keys %files)-scalar(keys %dirs)," files, ",scalar(keys %dirs), " dirs\n";

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
	}
	if (! %out) {
		$out{'no files? bug?'}++;
	}
	print scalar keys %out," files found for '$dirname': ",keys %out,"\n";
	return (keys %out),0;
}

sub e_open {
	# VFS sanity check; it keeps all the necessary state, not much to do here.
	my $file = filename_fixup(shift);
	my $flags = shift;

	return -ENOENT() unless exists($files{$file});
	return -EISDIR() unless exists($files{$file}{id});

	if (!exists($files{$file}{cont})) {
		$sth_read->execute($files{$file}{id}) || die $sth_read->errstr;
		$files{$file}{cont} = $sth_read->fetchrow_array;
		print "file '$file' content read in cache\n";
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

sub clear_cont {
	print "transaction rollback\n";
	$dbh->rollback || die $dbh->errstr;
	print "invalidate all cached content\n";
	foreach my $f (keys %files) {
		delete $files{$f}{cont};
	}
	print "begin new transaction\n";
	$dbh->begin_work || die $dbh->errstr;
}


sub update_db {
	my $file = shift || die;

	if (!$sth_update->execute($files{$file}{cont},$files{$file}{id})) {
		print "update problem: ",$sth_update->errstr;
		clear_cont;
		return 0;
	} else {
		if (! $dbh->commit) {
			print "ERROR: commit problem: ",$sth_update->errstr;
			clear_cont;
			return 0;
		}
		print "updated '$file' [",$files{$file}{id},"]\n";
	}
	return 1;
}

sub e_write {
	my $file = filename_fixup(shift);
	my ($buf,$off) = @_;

	return -ENOENT() unless exists($files{$file});

	my $len = length($files{$file}{cont});

	print "write '$file' [$len bytes] offset $off length $buf\n";

	$files{$file}{cont} =
		substr($files{$file}{cont},0,$off) .
		$buf .
		substr($files{$file}{cont},$off+length($buf));

	if (! update_db($file)) {
		return -ENOSYS();
	} else {
		return length($buf);
	}
}

sub e_truncate {
	my $file = filename_fixup(shift);
	my $size = shift;

	$files{$file}{cont} = substr($files{$file}{cont},0,$size);
	return 0
};


sub e_utime {
	my ($atime,$mtime,$file) = @_;
	$file = filename_fixup($file);

	return -ENOENT() unless exists($files{$file});

	$files{$file}{time} = $mtime;
	return 0;
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
	write=>\&e_write,
	utime=>\&e_utime,
	truncate=>\&e_truncate,
	debug=>0,
);
