package Net::OICQ::TextConsole;

# $Id: TextConsole.pm,v 1.28 2006/08/09 05:35:00 tans Exp $

# Copyright (c) 2003, 2004, 2005, 2006 Shufeng Tan.  All rights reserved.
# 
# This package is free software and is provided "as is" without express
# or implied warranty.  It may be used, redistributed and/or modified
# under the terms of the Perl Artistic License (see
# http://www.perl.com/perl/misc/Artistic.html)

use strict;
use warnings;
use Carp;
use IO::Select;
use Term::ANSIColor;

use Net::OICQ;
use Net::OICQ::ServerEvent;
use Net::OICQ::ClientEvent;

our $AUTOLOAD;

# Variables

my $HELP = <<EOF ;
All lines that begin with / (slash) are treated as keyboard commands.

  /help, /?    - print this help message
  /52482796    - set destination id num to 52482796
  /away        - toggle auto-reply
  /ls [id]     - list id numbers saved in user directory
  /rm [id]     - remove locally saved user info
  /buf         - show message buffer
  /rmbuf       - clear message buffer
  /hist        - show history
  /obj         - show object
  /set         - set object attribute
  /clear       - clear screen

  /plugin /path/to/plugin [id] - load plugin for auto-reply

  /eval perl_one_liner - do whatever you want.  \$oicq and \$ui are pre-defined.

  /xxxxx mesg  - send mesg to xxxx without changing destination id
  /get [id]    - get user info of the specified id (default to yourself)
  /f           - list all friends stored on the server
  /who         - get a list of online friends
  /s [n]       - list n x 25 online users if n < 100, or chekc if [n] is online
  /mode [n|i|a]- change mode to Normal, Invisible or Away
  /update      - update information
  /accept [id] - accept contact from id
  /reject [id] - reject contact from id
  /add [id]    - add a user to friend list
  /del [id]    - delete a user from friend list
  /ban [id]    - forbid a user from contacting you
  /passwd xxxx - change passwd to xxxx
  /g xxxx mesg - send group message
  /ginfo xxxx  - get group info
  /gs xxxx     - search group
  /gwho xxxx   - list online group members

Lines that do not begin with / will be stored in the message buffer
and will be sent to destination id when an empty line is entered.
This allows you to send a message of multiple lines.
EOF

# Keyboard commands

my %KbCmd = (  # Code ref          # Min num of arguments
	help	=> [\&help,	0],
	'?'	=> [\&help,	0],

	get	=> [\&get_user_info,	0],
	f	=> [\&get_friends_list,	0],
	who	=> [\&get_online_friends, 0],
	s	=> [\&search_users,	0],
	mode	=> [\&set_mode,		0],
	update	=> [\&update_info,	0],
	accept	=> [\&accept_contact,	1],
	reject	=> [\&reject_contact,	1],
	add	=> [\&add_contact,	1],
	del	=> [\&del_contact,	1],
	ban	=> [\&forbid_contact,	1],
	passwd	=> [\&set_passwd,	1],
	g	=> [\&send_group_msg,	2],
	ginfo	=> [\&get_group_info,	1],
	gs	=> [\&search_group,	1],
	gwho	=> [\&group_online_members, 1],

	away	=> [\&toggle_autoreply,	0],
	ls	=> [\&list_saved_ids,	0],
	strangers => [\&show_strangers,	0],
	rm	=> [\&remove_saved_ids,	1],
	buf	=> [\&show_msg_buffer,	0],
	rmbuf	=> [\&clear_msg_buffer,	0],
	hist	=> [sub {shift->{OICQ}->dump_event_queue}, 0],
	obj	=> [\&show_object,	0],
	set	=> [\&set_attribute,	0],
	plugin	=> [\&load_plugin,	1],
	clear	=> [sub {system "clear"}, 0],
);

my $MaxMsgSize = 0x400;  # 1024 bytes

my %AttrFilter = (
	LogChat      => sub { return $_[0] if $_[0] =~ /^\w*$/; undef },
	Debug        => sub { return $_[0] if $_[0] =~ /^\d$/; undef },
	AutoAwayTime => sub { return $_[0] if $_[0] =~ /^\d+$/; undef },
	Away         => sub { return $_[0] if $_[0] =~ /^\d+$/; undef },
);

my %Color = (
	message => 'blue',
	service => 'yellow',
	info    => 'green',
	warn    => 'yellow bold',
	error   => 'red bold',
	timestamp => 'green',
);

my $InfoHeader  = \@Net::OICQ::InfoHeader;
my $ConnectMode = \%Net::OICQ::ConnectMode;

# Constructor

sub new {
	my ($class, $oicq) = @_;

	defined $oicq or $oicq = new Net::OICQ;
	my $self = {
		OICQ      => $oicq,
		MsgBuffer => "",
		DstId     => "",
		Select    => new IO::Select(\*STDIN)
	};
	return bless($self, $class);
}

sub info {
	my ($self, @text) = @_;
	print color('green'), @text, color('reset');
}

sub warn {
	my ($self, @text) = @_;
	print color('yellow'), @text, color('reset');
}

sub error {
	my ($self, @text) = @_;
	print color('red'), @text, color('reset');
}

sub ask {
	my ($self, $prompt, $timeout) = @_;
	defined $timeout or $timeout = 120;
	print color('yellow'), $prompt, color('reset');
	$self->beep;
	my $input;
	eval {
		local $SIG{ALRM} = sub { die };
		alarm $timeout;
		$input = <STDIN>;
		$self->{LastKbInput} = time;
		alarm 0;
	};
	return $input;
}

sub beep {
	print "\007";
}

# Main loop to process both input from $oicq->{Socket} and STDIN

sub loop {
	my ($self) = @_;
	my $oicq = $self->{OICQ};
	my $select = $self->{Select};
	my $socket = $oicq->{Socket};
	$select->add($socket);
	$self->prompt;
  LOOP: while(1) {
		$oicq->keepalive if time - $oicq->{LastKeepaliveTime} >= 60;
	HANDLE: foreach my $handle ($select->can_read(0.1)) {
			if ($handle eq $socket) {
				my $packet;
				$socket->recv($packet, 0x4000);
			        foreach my $data ($oicq->get_data($packet)) {
					my $event = new Net::OICQ::ServerEvent($data, $oicq);
					next unless defined($event) && defined($event->{Data});
					$event->parse;
					# Each command needs a ui_command method
					my $cmd = "ui_".$event->cmd;
					eval {$self->$cmd($event)};
					print "$@" if $@;
				}
				next HANDLE;
			}
			my $input = <STDIN>;
			next unless defined $input;
			last LOOP if $input =~ /^\/(exit|quit)/;
			$self->process_kbinput($input);
		}
	}
}

sub ui_set_mode {
	my ($self, $event) = @_;
	if ($event->{Data} eq '0') {
		$self->info("Connection mode changed.\n");
	} else {
		$self->info("Server response to mode change: $event->{Data}\n");
	}
}

sub ui_keep_alive { # do nothing
}

sub ui_send_msg {
	my ($self, $event) = @_;
	my $code = $event->{ReturnCode};
	if ($code eq '00') {
		$self->info("Message accepted by server.\n");
	} else {
		$self->info("Server return code: $code\n");
	}
}

# Display message

sub ui_recv_msg {
	my ($self, $event) = @_;
	my $srcid = $event->{SrcId};
	my $dstid = $event->{DstId};
	my $text  = $event->{Mesg};
	$text =~ s|\x14(.)|'/'.unpack("H*", $1)|eg;
	if (!$event->{MsgTime}) {
		print substr(localtime, 11, 9), "$srcid:\n", $text, "\n" if $srcid != 10000;
		return;
	}
	if (defined($event->{Subtype}) and $event->{Subtype} == 129 and !defined($event->{FileName})) {
		# dont know what to do with this
		return;
	}
	my $time  = $event->{MsgTime};
	print color($Color{'timestamp'}), substr(localtime($time), 11, 9);
	my $oicq = $self->{OICQ};
	$self->set_dstid($srcid);
	if (defined $event->{GrpId}) {
		$srcid = $event->{SrcId2};
		print defined($event->{GrpId}) ? "Group $event->{GrpId} " : "";
	}
	my $nick = $oicq->get_nickname($srcid);
	my $id_color = $self->id_color($srcid);
	my $srcinfo = $oicq->{Info}->{$srcid};
	my $addr = $srcinfo->{Addr} || 'unknown';
	my $ver  = defined $srcinfo->{Client} ? "0x$srcinfo->{Client}" : 'unknown';
	print color($id_color), "$nick($srcid, IP $addr, version $ver) ";

	my $subtype = $event->{Subtype};
	if (defined $subtype) {
		if ($subtype == 0x81 and $event->{FileName}) {
			print "would like to send you a file:\n",
				"$event->{FileName} $event->{FileSize} bytes $event->{FileIP}";
		} elsif ($subtype == 0x85) {
			print "has cancelled file transfer.";
		} else {
			$text =~ s/[\x00-\x08]/_/g;
			print color($id_color), "\n$text";
		}
	} else {
		$text =~ s/[\x00-\x08]/_/g;
		print color($id_color), "\n$text";
	}
	print color('reset'), "\n";
        if ($event->{FontName}) {
		print color('white'),"($event->{FontName} $event->{FontSize} #$event->{FontColor})", color('reset'), "\n";
	}
	$self->beep;
}

sub ui_get_user_info {
	my ($self, $event) = @_;
	my $field = $event->{Info};
	my $oicq = $self->{OICQ};
	if ($field->[0] eq $oicq->{Id} && @{$oicq->{EventQueue}} < 10) {
		# Dont display user info requested immediately after login
		$self->info("Retrieved info about self $field->[0].\n");
		return;
	}
	$self->info('-'x34, ' User Info ', '-'x34, "\n");
	foreach my $i (0..24) { 
		$field->[$i] =~ s/([\x00-\x1f])/'\x'.unpack("H*", $1)/ge;
		$self->info(sprintf("%-15s: %-25s", $InfoHeader->[$i], $field->[$i]));
		if (defined $field->[$i+25]) {
			$self->info(sprintf(" %-15s: %s\n",
		        		$InfoHeader->[$i+25], $field->[$i+25]));
		} else {
			$self->info("\n");
		}
	}
	$self->info('='x79, "\n");
}

sub ui_get_online_friends {
	my ($self, $event) = @_;
	my $aref = $event->{OnlineFriends};
	my $oicq = $self->{OICQ};
	if (@$aref == 0) {
		$self->info("No friend online.\n");
		return;
	}
	$self->info(sprintf "%-9s %-12s %-20s %s\n", 'Id', 'Nickname', 'Address', 'Mode');
	$self->info(sprintf "%9s %-12s %-20s %s\n", '-'x9, '-'x12, '-'x20, '----');
	foreach my $fid (@$aref) {
		my $info = $oicq->{Info}->{$fid};
		my $addr = $info->{Addr} || "";
		my $mode = $info->{Mode};
		#next if $fid >= 72000001 and $fid <= 72000012;
		my $nick = $oicq->get_nickname($fid);
		$self->info(sprintf "%9d %-12s %-20s %d\n", $fid, $nick, $addr, $mode);
	}
	$self->info('='x48,"\n");
}

sub ui_search_users {
	my ($self, $event) = @_;
	my $aref = $event->{UserList};
	unless (@$aref) {
		$self->info("No result for user search\n");
		return;
	}
	$self->info('-'x32, ' Search Result ', '-'x32, "\n");
	foreach my $ref (@$aref) {
		$self->info(sprintf("%-10s %-40s %+20s %4s\n",
				map {s/([\x00-\x1f])/'\x'.unpack("H*", $1)/ge; $_} @$ref));
	}       
	$self->info('='x79, "\n");  
}       

sub ui_get_friends_list {
	my ($self) = @_;
	$self->info('-'x25, " Friends List ", '-'x25, "\n");
	my $info = $self->{OICQ}->{Info};
	my $idx = 1;
	foreach my $id (sort {$a <=> $b} keys %$info) {
		my $hashref = $info->{$id};
		next unless defined $hashref->{Friend};
		$self->info(sprintf "%2d.  %9d  %3s  %3s  %4s : %-16s %s\n",
			$idx++, $id,
			defined($hashref->{Sex}) ? $hashref->{Sex} : '',
			defined($hashref->{Age}) ? $hashref->{Age} : '',
			defined($hashref->{Face}) ? $hashref->{Face} : '',
			defined($hashref->{Nickname}) ? $hashref->{Nickname} : '',
			defined($hashref->{Unknown}) ? $hashref->{Unknown} : '');
	}
	$self->info('='x65, "\n");
}

sub ui_recv_friend_status {
	my ($self, $event) = @_;
	my $id = $event->{SrcId};
	my $mode = $event->{Mode};
	my $addr = $event->{Addr};
	$addr = "" unless defined $addr;
	$self->info(substr(localtime, 11, 9), $id, " ",
		        $self->{OICQ}->get_nickname($id), " $addr ");
	if ($mode == 10) {
		$self->info("is online.\n");
	} elsif ($mode == 20) {
		$self->info("is offline or wishes to be invisable :-)\n");
	} elsif ($mode == 30) {
		$self->info("is away.\n");
	} else {
		$self->info("changed mode to $mode\n");
	}
}

sub ui_recv_service_msg {
	my ($self, $event) = @_;
	$self->info("Received service message from $event->{SrcId}:\n$event->{Comment}:",
			defined($event->{Mesg}) ? $event->{Mesg} : "", "\n");
}

sub ui_do_group {
	my ($self, $event) = @_;
	if ($event->{SubCmd} =~ /^[01]a/) {  # group message
		if ($event->{Reply} eq '00') {
			$self->info("Group message sent\n");
		} else {
			$self->info("Server return code: $event->{Reply}\n");
		}
	} else {
		$event->dump;
	}
}

sub ui_add_contact_1 {
	my ($self, $event) = @_;
	$self->info("$event->{Comment}\n");
}

sub ui_add_contact_2 {
	my ($self, $event) = @_;
	$self->info("Server reponse to add_contact_2: $event->{Data}\n");
}

sub ui_del_contact {
	my ($self, $event) = @_;
	$event->dump;
}

# This method is used by ui_recv_msg
sub id_color {
	my ($self, $id) = @_;
	my $color;
	my $info = $self->{OICQ}->{Info}->{$id};
	if (defined $info && defined $info->{Sex} && $info->{Sex} !~/\D/) {
		return 'cyan' if $info->{Sex} == 0;
		return 'magenta'if $info->{Sex} == 1;
	}
	return 'yellow';
}

sub ask_passwd {
	my ($self, $prompt) = @_;
	print $prompt;
	system(qw(stty -echo));
	if ($? != 0) {
		print "warning: password will be visible. ";
	}
	my $pw = <STDIN>;
	system(qw(stty echo));
	print "\n";
	chomp $pw;
	return $pw;
}

sub get_new_passwd {
	my ($self) = @_;
	my $pw  = $self->ask_passwd("Enter new passwd: ");
	my $pw2 = $self->ask_passwd("Retype new passwd to confirm: ");
	$self->{LastKbInput} = time;
	return $pw if $pw eq $pw2;
	$self->error("Passwords don't match.\n");
	return;
}

sub process_kbinput {
	my ($self, $kbinp) = @_;

	$self->{LastKbInput} = time;
	my $oicq = $self->{OICQ};
	if ($kbinp =~ s|^/||) {
		$kbinp =~ s/^\s+//;
		$kbinp =~ s/\s+$//;
		my ($cmd, @args) = split(/\s+/, $kbinp);
		unless (defined $cmd) {
			$oicq->get_online_friends;
			return;
		}
		if ($cmd =~ /^\d+$/) {
			if (@args) {
				my $dstid = ($cmd <= 1000) ? $self->find_friend_id($cmd) : $cmd;
				$oicq->send_msg($dstid, "@args") if defined $dstid;
			} else {
				$self->set_dstid($cmd);
			}
		} elsif ($cmd eq 'eval') {
			my $ui = $self;
			eval "@args";
			$@ && $self->error("$@");
			print "\n";
			$self->prompt;
			return;
		} elsif (exists $KbCmd{$cmd}) {
			if (@args < $KbCmd{$cmd}->[1]) {
				$self->error("Not enought argument for command $cmd\n");
			} else {
				eval { $KbCmd{$cmd}->[0]->($self, @args) };
				$@ && $self->error("$@");
				return;  # don't return prompt
			}
		} else {
			$self->error("Unknown command: $cmd\n");
		}
		$self->prompt;
		return;
	}

	if ($kbinp =~ /^$/) {
		if ($self->{MsgBuffer} =~ /\S/) {
			if (exists($self->{DstId}) && $self->{DstId} =~ /^\d+$/) {
				my $dstid = $self->{DstId};
				chomp $self->{MsgBuffer};
				if ($oicq->send_msg($dstid, $self->{MsgBuffer})) {
					$self->{MsgBuffer} = "";
				} else {
					$self->error("Message not sent.\n");
				}
			} else {
				$self->error("Destination Id not given.\n");
				$self->prompt;
			}
		} else {
			$self->prompt;
		}
	} else {
		$self->{MsgBuffer} .= $kbinp;
	}
	if (length($self->{MsgBuffer}) > $MaxMsgSize) {
		$self->warn("Msg buffer size > $MaxMsgSize bytes\n");
	}
}

# Keyboard command help message
	
sub help {
	pop->info('-'x32, ' Help Message ', '-'x32, "\n", $HELP);
}

sub set_attribute {
	my ($self, $attr, $val) = @_;
	my $oicq = $self->{OICQ};
	if (defined($attr)) {
		if (exists $AttrFilter{$attr}) {
		    if (defined $val) {
		        my $newval = $AttrFilter{$attr}->($val);
		        if (defined $newval) {
		            $oicq->{$attr} = $newval;
		        } else {
		            $self->error("Invalid value for $attr: $val\n");
		        }
		    } else {
		        $self->warn("$attr = $oicq->{$attr}\n");
		    }
		} else {
		   $self->error("Cannot change $attr\n");
		}
	} else {
		$self->warn("These attributes can be changed:\n",
		           join(', ', keys(%AttrFilter)), "\n");
	}
	$self->prompt;
	return;
}

sub prompt {
	my ($self) = @_;
	my $oicq = $self->{OICQ};
	my $bufsize = length($self->{MsgBuffer});
	my $myid = $oicq->{Id};
	my $mynick = $oicq->get_nickname($myid);
	my $dstid = $self->{DstId};
	my $dstnick = $dstid ? $oicq->get_nickname($dstid) : "";
	my $time = time - $oicq->{LastSvrAck};
	my $c = $time > 60 ? '?' : '%';
	$self->info(sprintf("%s %-8s %8s => %-8s %8s  %12d bytes in buffer %2d\"\n",
		               $c, $mynick, $myid, $dstnick, $dstid, $bufsize, $time));
}

sub find_friend_id {
	my ($self, $index) = @_;
	my $info = $self->{OICQ}->{Info};
	my $count = 0;
	foreach my $id (sort {$a <=> $b} keys %$info) {
		next unless defined $info->{$id}->{Friend};
		$count++;
		if ($count == $index) {
		    return $id;
		}
	}
	$self->error("Invalid friend index $index ignored.\n");
	return undef;
}

sub set_dstid {
	my ($self, $dstid) = @_;
	if ($dstid =~ /^\d+$/) {
		if ($dstid <= 1000) {   # Assume user gives index, ranther than qq id
		    my $real_dstid = $self->find_friend_id($dstid);
		    defined $real_dstid and $self->{DstId} = $real_dstid;
		} else {
		    $self->{DstId} = $dstid;
		}
	} else {
		$self->error("Invalid destination id '$dstid' ignored.\n");
	}
}

sub toggle_autoreply {
	my ($self) = @_;
	my $oicq = $self->{OICQ};
	$self->warn("Auto-reply ", $oicq->toggle_autoreply, "\n");
	$self->prompt;
}

sub remove_saved_ids {
	my $self = shift;
	my $oicq = $self->{OICQ};
	foreach my $id (@_) {
		unless ($id =~ /^\d+$/) {
		    $self->error("Invalid ID $id ignored\n");
		    next;
		}
		$oicq->remove_saved_id($id) or $self->error("Failed to remove $id\n");
	}
	$self->prompt;
}

sub list_saved_ids {
	my $self = shift;
	my $oicq = $self->{OICQ};
	my $dir = "$oicq->{Dir}/$oicq->{Id}";
	if (@_) {
		foreach my $id (@_) {
		    system('cat', "$dir/$id.dat");
		}
	} else {
		$self->info('-'x30, ' Stored User Info ', '-'x30,"\n");
		foreach my $id ($oicq->get_saved_ids) {
			my $nick = $oicq->get_nickname($id);
			my $mtime = substr(localtime((stat("$dir/$id.dat"))[9]), 4, 16);
			$self->info(sprintf("$mtime %9s ", $id), $nick, "\n");
		}
		$self->info('='x78, "\n");
	}
	$self->prompt;
}

sub show_msg_buffer {
	my $self = shift;
	print "\n$self->{MsgBuffer}\n";
}

sub clear_msg_buffer {
	my $self = shift;
	$self->{MsgBuffer} = "";
	$self->info("Message buffer deleted\n");
	$self->prompt;
}

sub show_oicq {
	my ($self, $oicq) = @_;
	$self->info("{\n");
	my $pre = "    ";
	foreach my $attr (sort keys(%$oicq)) {
	   next if $attr =~ /Passw/;
	   my $val = $oicq->{$attr};
	   $val = unpack("H*", $val) if $val =~ /[\0-\x1f]/;
	   $self->info($pre, "$attr = $val\n"); 
	}
	$self->info("}\n");
}

sub show_object {
	my ($self) = @_;
	$self->info('-'x35, ' Object ', '-'x35,"\n");
	foreach my $key (keys %$self) {
		$self->info("$key = ");
		my $val = $self->{$key};
		if (ref($val) eq 'Net::OICQ') {
		    $self->show_oicq($val);
		} elsif (ref($val) =~ /ARRAY/) {
		    $self->info("[ ", join(', ', @$val), " ]\n");
		} else {
		    $self->info($val, "\n");
		}
	}
	$self->prompt;
}

sub load_plugin {
	my ($self, $file, $id) = @_;
	my $oicq = $self->{OICQ};
	if (defined $id) {
		if ($id =~ /^\d+$/) {
		    defined $oicq->{Info}->{$id} or $oicq->{Info}->{$id} = {};
		    $oicq->{Info}->{$id}->{ChatBot} = $file;
		    $self->info("Plugin $file will be used on $id\n");
		} else {
		    $self->error("Bad id $id\n");
		}
	} else {
		$oicq->{ChatBot} = $file;
		$self->info("Plugin $file will be used on all ids\n");
	}
}

sub AUTOLOAD {
	my $self = shift;
	my $type = ref($self) or croak "$self is not an object";
	my $name = $AUTOLOAD;
	$name =~ s/.*://;
	return if $name eq 'DESTROY';
	if ($name =~ s/^ui_//) {
		$self->warn("Don't know how to handle QQ command $name.\n");
		my $event = shift;
		if (defined($event) && ref($event) =~ /Event/) {
			$event->dump;
		}
		return;
	}
	my $oicq = $self->{OICQ};
	unless (defined $oicq) {
		$self->warn("Command $name ignored.\n");
		return;
	}
	unless (Net::OICQ->can($name)) {
		$self->warn("$name is not a Net::OICQ method.\n");
		return;
	}
	if (defined $_[0]) {
		$self->valid_id($_[0]) or return;
	}
	$oicq->$name(@_);
}

sub show_strangers {
	my ($self) = @_;
	$self->info('-'x22, " Strangers ", '-'x22, "\n");
	my $info = $self->{OICQ}->{Info};
	my $idx = 1;
	foreach my $id (sort {$a <=> $b} keys %$info) {
		my $hashref = $info->{$id};
		next if defined $hashref->{Friend};
		$self->info(sprintf "%2d.  %9d  %3s  %3s  %4s : %-16s \n",
		    $idx++, $id,
		    defined($hashref->{Sex}) ? $hashref->{Sex} : '',
		    defined($hashref->{Age}) ? $hashref->{Age} : '',
		    defined($hashref->{Face}) ? $hashref->{Face} : '',
		    defined($hashref->{Nickname}) ? $hashref->{Nickname} : '');
  }
  $self->info('='x55, "\n");
}

sub set_mode {
	my ($self, $mode) = @_;
	unless (defined $mode) {
		$self->info("Please use i for invisible, a for away, n for normal.\n");
		return;
	}
	my $oicq = $self->{OICQ};
	my $code;
	use bytes;
	if    ($mode =~ /^i/i) { $oicq->{ConnectMode} = 'Invisible'; $code = chr(40) }
	elsif ($mode =~ /^a/i) { $oicq->{ConnectMode} = 'Away';      $code = chr(30) }
	elsif ($mode =~ /^n/i) { $oicq->{ConnectMode} = 'Normal';    $code = chr(10) }
	elsif ($mode =~ /^\d\d?/) { $code = chr($mode) }  # You can enter code directly
	else {
		$self->info("Unknown mode \"$mode\" ignored.\n");
		return;
	}
	$self->{OICQ}->set_mode($code);
}

sub get_user_info {
	my ($self, $id) = @_;
	my $oicq = $self->{OICQ};
	defined $id or $id = $oicq->{Id};
	$self->valid_id($id) or return;
	if ($id < 1000) {
		my $fid = $self->find_friend_id($id);
		defined $fid or return;
		$oicq->get_user_info($fid);
	} else {
		$oicq->get_user_info($id);
	}
	$self->{show_user_info} = 1;
}

sub update_info {
	my $self = shift;
	unless (@_) {
		$self->info("You can change the following attributes of yourself:\n");
		for(my $i = 1; $i < (@$InfoHeader -2); $i++) {
		    $self->info(sprintf " %-19s", $InfoHeader->[$i]);
		    $self->info("\n") if $i%4 == 0;
		}
		$self->info("\n");
		$self->prompt;
		return;
	}
	push @_, "" if @_ % 2;
	my %hash = @_;
	foreach my $attr (keys %hash) {
		# Allow updating unknown attributes
		#if ($attr =~ /^unkn/i) {
		#    print "Invalid attribute $attr ignored\n";
		#    delete $hash{$attr};
		#    next;
		#}
		my $val = $hash{$attr};
		$val =~ s/\\s/ /g;
		$val =~ s/\\n/\n/g;
		$hash{uc($attr)} = $val;
		printf "%-19s : %s\n", $attr, $val;
	}
	$self->{OICQ}->update_info(\%hash);
	return 1;
}

sub set_passwd {
	my ($self) = @_;
	my $newpw = $self->get_new_passwd;
	if ($newpw) {
		$self->{OICQ}->set_passwd($newpw);
		return 1;
	}
	return 0; 
}

sub valid_id {
	my ($self, $id) = @_;
	if ($id =~ /^\d+$/) {
		return 1;
	} else {
		$self->error("Invalid id: $id\n");
		return 0;
	}
}

sub search_users {
	my ($self, $arg) = @_;
	my $oicq = $self->{OICQ};
	unless (defined $arg) {
		$oicq->list_online_users(1);
		return;
	}
	if ($arg =~ /\D/) {
		$oicq->search_user($arg);
	} elsif ($arg == 0) {
		$oicq->{SearchCount} = 0;
	} elsif ($arg > 100) {
		$oicq->search_user($arg);
	} else {
		$oicq->list_online_users($arg);
	}
}

sub add_contact {
	my ($self, $id, @mesg) = @_;
	$self->valid_id($id) or return;
	my $oicq = $self->{OICQ};
	if (@mesg) {
		$oicq->add_contact_2($id, "@mesg");
	} else {
		$oicq->add_contact($id);
	}
}

# sub accept_contact handled by AUTOLOAD

# sub reject_contact handled by AUTOLOAD

# sub add_contact handled by AUTOLOAD

# sub del_contact handled by AUTOLOAD

# sub forbid_contact handled by AUTOLOAD

# sub search_group handled by AUTOLOAD

# sub get_group_info handled by AUTOLOAD

# sub send_group_msg handled by AUTOLOAD

# sub group_online_members handled by AUTOLOAD

1;
