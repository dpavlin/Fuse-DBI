#!/usr/bin/perl

package Fuse::DBI;

use 5.008;
use strict;
use warnings;

use POSIX qw(ENOENT EISDIR EINVAL ENOSYS O_RDWR);
use Fuse;
use DBI;
use Carp;
use Proc::Simple;
use Data::Dumper;


our $VERSION = '0.01';

=head1 NAME

Fuse::DBI - mount your database as filesystem and use it

=head1 SYNOPSIS

  use Fuse::DBI;
  Fuse::DBI->mount( ... );

See L<run> below for examples how to set parametars.

=head1 DESCRIPTION

This module will use L<Fuse> module, part of C<FUSE (Filesystem in USErspace)>
available at L<http://sourceforge.net/projects/avf> to mount
your database as file system.

That will give you posibility to use normal file-system tools (cat, grep, vi)
to manipulate data in database.

It's actually opposite of Oracle's intention to put everything into database.


=head1 METHODS

=cut

=head2 mount

Mount your database as filesystem.

  my $mnt = Fuse::DBI->mount({
	filenames => 'select name from filenamefilenames,
	read => 'sql read',
	update => 'sql update',
	dsn => 'DBI:Pg:dbname=webgui',
	user => 'database_user',
	password => 'database_password'
  });

=cut

my $dbh;
my $sth;
my $ctime_start;

sub read_filenames;

sub mount {
	my $class = shift;
	my $self = {};
	bless($self, $class);

	my $arg = shift;

	print Dumper($arg);

	carp "mount needs 'dsn' to connect to (e.g. dsn => 'DBI:Pg:dbname=test')" unless ($arg->{'dsn'});
	carp "mount needs 'mount' as mountpoint" unless ($arg->{'mount'});

	# save (some) arguments in self
	$self->{$_} = $arg->{$_} foreach (qw(mount));

	foreach (qw(filenames read update)) {
		carp "mount needs '$_' SQL" unless ($arg->{$_});
	}

	$dbh = DBI->connect($arg->{'dsn'},$arg->{'user'},$arg->{'password'}, { AutoCommit => 0 }) || die $DBI::errstr;

	print "start transaction\n";
	#$dbh->begin_work || die $dbh->errstr;

	$sth->{filenames} = $dbh->prepare($arg->{'filenames'}) || die $dbh->errstr();

	$sth->{'read'} = $dbh->prepare($arg->{'read'}) || die $dbh->errstr();
	$sth->{'update'} = $dbh->prepare($arg->{'update'}) || die $dbh->errstr();

	$ctime_start = time();

	read_filenames;

	$self->{'proc'} = Proc::Simple->new();
	$self->{'proc'}->kill_on_destroy(1);

	$self->{'proc'}->start( sub {
		Fuse::main(
			mountpoint=>$arg->{'mount'},
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
	} );

	confess "Fuse::main failed" if (! $self->{'proc'}->poll);

	$self ? return $self : return undef;
};

=head2 umount

Unmount your database as filesystem.

  $mnt->umount;

This will also kill background process which is translating
database to filesystem.

=cut

sub umount {
	my $self = shift;

	confess "no process running?" unless ($self->{'proc'});

	system "fusermount -u ".$self->{'mount'} || croak "umount error: $!";

	if ($self->{'proc'}->poll) {
		$self->{'proc'}->kill;
		return 1 if (! $self->{'proc'}->poll);
	} else {
		return 1;
	}
}


my %files;
my %dirs;

sub read_filenames {
	my $self = shift;

	# create empty filesystem
	(%files) = (
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

	# fetch new filename list from database
	$sth->{'filenames'}->execute() || die $sth->{'filenames'}->errstr();

	# read them in with sesible defaults
	while (my $row = $sth->{'filenames'}->fetchrow_hashref() ) {
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
}


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
	foreach my $f (sort keys %files) {
		if ($dirname) {
			if ($f =~ s/^\E$dirname\Q\///) {
				$out{$f}++ if ($f =~ /^[^\/]+$/);
			}
		} else {
			$out{$f}++ if ($f =~ /^[^\/]+$/);
		}
	}
	if (! %out) {
		$out{'no files? bug?'}++;
	}
	print scalar keys %out," files in dir '$dirname'\n";
	print "## ",join(" ",keys %out),"\n";
	return (keys %out),0;
}

sub e_open {
	# VFS sanity check; it keeps all the necessary state, not much to do here.
	my $file = filename_fixup(shift);
	my $flags = shift;

	return -ENOENT() unless exists($files{$file});
	return -EISDIR() unless exists($files{$file}{id});

	if (!exists($files{$file}{cont})) {
		$sth->{'read'}->execute($files{$file}{id}) || die $sth->{'read'}->errstr;
		$files{$file}{cont} = $sth->{'read'}->fetchrow_array;
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
	my ($buf_len,$off) = @_;

	return -ENOENT() unless exists($files{$file});

	my $len = length($files{$file}{cont});

	print "read '$file' [$len bytes] offset $off length $buf_len\n";

	return -EINVAL() if ($off > $len);
	return 0 if ($off == $len);

	$buf_len = $buf_len-$off if ($off+$buf_len > $len);

	return substr($files{$file}{cont},$off,$buf_len);
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

	$files{$file}{ctime} = time();

	if (!$sth->{'update'}->execute($files{$file}{cont},$files{$file}{id})) {
		print "update problem: ",$sth->{'update'}->errstr;
		clear_cont;
		return 0;
	} else {
		if (! $dbh->commit) {
			print "ERROR: commit problem: ",$sth->{'update'}->errstr;
			clear_cont;
			return 0;
		}
		print "updated '$file' [",$files{$file}{id},"]\n";
	}
	return 1;
}

sub e_write {
	my $file = filename_fixup(shift);
	my ($buf_len,$off) = @_;

	return -ENOENT() unless exists($files{$file});

	my $len = length($files{$file}{cont});

	print "write '$file' [$len bytes] offset $off length\n";

	$files{$file}{cont} =
		substr($files{$file}{cont},0,$off) .
		$buf_len .
		substr($files{$file}{cont},$off+length($buf_len));

	if (! update_db($file)) {
		return -ENOSYS();
	} else {
		return length($buf_len);
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

	print "utime '$file' $atime $mtime\n";

	$files{$file}{time} = $mtime;
	return 0;
}

sub e_statfs { return 255, 1, 1, 1, 1, 2 }

1;
__END__

=head1 EXPORT

Nothing.

=head1 SEE ALSO

C<FUSE (Filesystem in USErspace)> website
L<http://sourceforge.net/projects/avf>

=head1 AUTHOR

Dobrica Pavlinusic, E<lt>dpavlin@rot13.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2004 by Dobrica Pavlinusic

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.4 or,
at your option, any later version of Perl 5 you may have available.


=cut

