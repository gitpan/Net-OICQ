#!/usr/bin/env perl
# $Id: test.pl,v 1.9 2006/08/09 04:04:25 tans Exp $

# Copyright (c) 2002 Shufeng Tan.  All rights reserved.
# 
# This package is free software and is provided "as is" without express
# or implied warranty.  It may be used, redistributed and/or modified
# under the terms of the Perl Artistic License (see
# http://www.perl.com/perl/misc/Artistic.html)

use strict;
use Test;
BEGIN { plan tests => 1 };

use Net::OICQ;
use Net::OICQ::ServerEvent;
use Net::OICQ::ClientEvent;
use Net::OICQ::TextConsole;

my $oicq = new Net::OICQ;

ok(defined($oicq));

__END__
