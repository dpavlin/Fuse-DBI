#!/usr/bin/perl

package Fuse::DBI;

use 5.008;
use strict;
use warnings;

use POSIX qw(ENOENT EISDIR EINVAL ENOSYS O_RDWR);
use Fuse;
use DBI;
use Carp;
use Data::Dumper;


our $VERSION = '0.03';

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
	filenames => 'select name from files_table as filenames',
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
sub fuse_module_loaded;

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

	$ctime_start = time();

	if ($arg->{'fork'}) {
		my $pid = fork();
		die "fork() failed: $!" unless defined $pid;
		# child will return to caller
		if ($pid) {
			$self ? return $self : return undef;
		}
	}

	$dbh = DBI->connect($arg->{'dsn'},$arg->{'user'},$arg->{'password'}, {AutoCommit => 0, RaiseError => 1}) || die $DBI::errstr;

	$sth->{filenames} = $dbh->prepare($arg->{'filenames'}) || die $dbh->errstr();

	$sth->{'read'} = $dbh->prepare($arg->{'read'}) || die $dbh->errstr();
	$sth->{'update'} = $dbh->prepare($arg->{'update'}) || die $dbh->errstr();

	$self->read_filenames;

	my $mount = Fuse::main(
		mountpoint=>$arg->{'mount'},
		getattr=>\&e_getattr,
		getdir=>\&e_getdir,
		open=>\&e_open,
		statfs=>\&e_statfs,
		read=>\&e_read,
		write=>\&e_write,
		utime=>\&e_utime,
		truncate=>\&e_truncate,
		unlink=>\&e_unlink,
		debug=>0,
	);

	if (! $mount) {
		warn "mount on ",$arg->{'mount'}," failed!\n";
		return undef;
	}
};

=head2 umount

Unmount your database as filesystem.

  $mnt->umount;

This will also kill background process which is translating
database to filesystem.

=cut

sub umount {
	my $self = shift;

	system "fusermount -u ".$self->{'mount'} || croak "umount error: $!";

	return 1;
}

=head2 fuse_module_loaded

Checks if C<fuse> module is loaded in kernel.

  die "no fuse module loaded in kernel"
  	unless (Fuse::DBI::fuse_module_loaded);

This function in called by L<mount>, but might be useful alone also.

=cut

sub fuse_module_loaded {
	my $lsmod = `lsmod`;
	die "can't start lsmod: $!" unless ($lsmod);
	if ($lsmod =~ m/fuse/s) {
		return 1;
	} else {
		return 0;
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

sub read_content {
	my ($file,$id) = @_;

	die "read_content needs file and id" unless ($file && $id);

	$sth->{'read'}->execute($id) || die $sth->{'read'}->errstr;
	$files{$file}{cont} = $sth->{'read'}->fetchrow_array;
	print "file '$file' content [",length($files{$file}{cont})," bytes] read in cache\n";
}


sub e_open {
	# VFS sanity check; it keeps all the necessary state, not much to do here.
	my $file = filename_fixup(shift);
	my $flags = shift;

	return -ENOENT() unless exists($files{$file});
	return -EISDIR() unless exists($files{$file}{id});

	read_content($file,$files{$file}{id}) unless exists($files{$file}{cont});

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

	$buf_len = $len-$off if ($len - $off < $buf_len);

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
	#$dbh->begin_work || die $dbh->errstr;
}


sub update_db {
	my $file = shift || die;

	$files{$file}{ctime} = time();

	my ($cont,$id) = (
		$files{$file}{cont},
		$files{$file}{id}
	);

	if (!$sth->{'update'}->execute($cont,$id)) {
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
	my ($buffer,$off) = @_;

	return -ENOENT() unless exists($files{$file});

	my $cont = $files{$file}{cont};
	my $len = length($cont);

	print "write '$file' [$len bytes] offset $off length ",length($buffer),"\n";

	$files{$file}{cont} = "";

	$files{$file}{cont} .= substr($cont,0,$off) if ($off > 0);
	$files{$file}{cont} .= $buffer;
	$files{$file}{cont} .= substr($cont,$off+length($buffer),$len-$off-length($buffer)) if ($off+length($buffer) < $len);

	$files{$file}{size} = length($files{$file}{cont});

	if (! update_db($file)) {
		return -ENOSYS();
	} else {
		return length($buffer);
	}
}

sub e_truncate {
	my $file = filename_fixup(shift);
	my $size = shift;

	print "truncate to $size\n";

	$files{$file}{cont} = substr($files{$file}{cont},0,$size);
	$files{$file}{size} = $size;
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

sub e_unlink {
	my $file = filename_fixup(shift);

	return -ENOENT() unless exists($files{$file});

	print "unlink '$file' will invalidate cache\n";

	read_content($file,$files{$file}{id});

	return 0;
}
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
