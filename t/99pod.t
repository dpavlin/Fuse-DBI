#!/usr/bin/perl

use strict;
use warnings;

use Test::Pod tests => 1;

use Fuse::DBI;

pod_file_ok($INC{"Fuse::DBI"});

