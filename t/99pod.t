#!/usr/bin/perl

use strict;
use warnings;

use Test::Pod tests => 1;

use jsFind;

pod_file_ok($INC{"jsFind.pm"});

