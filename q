#!/usr/bin/env perl
# $Id: q,v 1.5 2006/08/09 02:38:06 tans Exp $

# Copyright (c) 2002, 2003 Shufeng Tan.  All rights reserved.
# 
# This program is free software and is provided "as is" without express
# or implied warranty.  It may be used, redistributed and/or modified
# under the terms of the Perl Artistic License (see
# http://www.perl.com/perl/misc/Artistic.html)

use strict;
use Getopt::Long;
use Net::OICQ::TextConsole;

my $usage = <<EOF;
Usage:
If you use Borne shell, bash or ksh, type:
OICQ_PW='xxxxxxx' $0 [-hi] [-d#] [-p<plugin>] id

If you use csh or tcsh, type:
setenv OICQ_PW 'xxxxxxx'
$0 [-hi] [-d#] [-p<plugin>] id

Options:
    -h  print this help message
    -i  invisible mode
    -d  debug mode
    -p<plugin>  specify plugin
EOF

my $invisible= 0;
my $debug    = 0;
my $plugin   = "";
my $help     = 0;

GetOptions("debug=i"   => \$debug,
	   "invisible" => \$invisible,
           "plugin=s"  => \$plugin,
	   "help"      => \$help);

die $usage if $help;

my $mode   = $invisible ? 'Invisible' : 'Normal';

my $uid = shift;

$| = 1;
my $ui = new Net::OICQ::TextConsole;

unless ($uid) {
	$uid = $ENV{OICQ_ID};
	die "Login Id not given\n" unless $uid;
	$ui->info("QQ id: $uid\n");
}

my $pw  = $ENV{OICQ_PW};
if ($pw) {
	print "OICQ_PW found in env.\n";
} else {
	$pw = $ui->ask_passwd("Enter password for $uid: ");
	$pw or die "Password not entered.\n";
}

our $oicq = $ui->{OICQ};
$oicq->{EventQueueSize} = 100;
$oicq->{FontSize}  = 'random';
$oicq->{FontColor} = 'random';
$oicq->{Debug} = $debug;

$oicq->login($uid, $pw, $mode) or die "Failed to login.\n";
$ui->{LastKbInput} = time;
#$oicq->request_file_key();
#$ui->set_mode($mode);
$oicq->get_friends_list;
$oicq->get_online_friends;
$oicq->get_user_info($uid);
if ($plugin) {
    if (-f $plugin) {
        $ui->load_plugin($plugin);
    } else {
        $ui->warn("Plugin $plugin does not exist\n");
    }
}
$ui->loop;

END { defined $oicq && defined $oicq->{Socket} && $oicq->logout }
