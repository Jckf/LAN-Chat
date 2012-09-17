#!/usr/bin/perl
use strictures;
use threads;
use AnyEvent;
use IO::Select;
use IO::Socket::INET;

my (%clients,%coms,$ccc,$rcc);

# Client socket select.
my $css = IO::Select->new();

# TX socket.
my $txs = IO::Socket::INET->new(
	'PeerPort'	=> 9128,
	'PeerAddr'	=> '255.255.255.255',
	'Proto'		=> 'UDP',
	'Broadcast'	=> 1
) or die($!);

# RX socket.
my $rxs = IO::Socket::INET->new(
	'LocalPort'	=> 9128,
	'Proto'		=> 'UDP'
) or die($!);

# Client input socket.
my $cis = IO::Socket::INET->new(
	'LocalPort'	=> 9128,
	'Proto'		=> 'TCP',
	'Listen'	=> 5,
	'ReuseAddr'	=> 1
) or die($!);

# Non-blocking STDIN hack.
my $stdin = IO::Socket::INET->new(
	'LocalAddr'	=> '127.0.0.1',
	'LocalPort'	=> 9129,
	'Proto'		=> 'UDP'
);
async {
	my $_stdin = IO::Socket::INET->new(
		'PeerAddr'	=> '127.0.0.1',
		'PeerPort'	=> 9129,
		'Proto'		=> 'UDP'
	);

	$_stdin->send($_) while <STDIN>;
}->detach();

# TX event.
my $txe = AnyEvent->timer(
	'interval'	=> 10,
	'cb'		=> sub {
		# Send an empty string. The interesting information is the source of the packet.
		$txs->send('');
	}
);

# RX event.
my $rxe = AnyEvent->io(
	'fh'	=> $rxs,
	'poll'	=> 'r',
	'cb'	=> sub {
		# Get whatever is in there to clear the event and update the source's timestamp.
		$rxs->recv(my $data,128);

		my $client = join('.',unpack('C4',$rxs->peeraddr));

		$clients{$client}{'timestamp'} = time();

		# Show us if there is something in there.
		print $client . ': ' . $data . "\n" if length $data;
	}
);

# Client connect event.
my $cce = AnyEvent->io(
	'fh'	=> $cis,
	'poll'	=> 'r',
	'cb'	=> sub {
		my $socket = $cis->accept();
		my $client = join('.',unpack('C4',$socket->peeraddr));

		$clients{$client}{'timestamp'} = time();
		$clients{$client}{'socket'} = $socket;

		$css->add($socket);
	}
);

# Idle event.
my $idl = AnyEvent->idle(
	'cb'	=> sub {
		foreach my $socket ($css->can_read(0)) {
			$socket->recv(my $data,128);

			# Did we get any data?
			unless (length $data) {
				$css->remove($socket);
				return;
			}

			my $client = join('.',unpack('C4',$socket->peeraddr));

			print $client . ': ' . $data . "\n";

			$clients{$client}{'timestamp'} = time();

			# Store it so we know who talked to us last.
			$rcc = $client;
		}
	}
);

# User input event.
my $uie = AnyEvent->io(
	'fh'	=> $stdin,
	'poll'	=> 'r',
	'cb'	=> sub {
		# Get and sanitize the input a little.
		$stdin->recv(my $in,128);
		$in =~ s/[\r\n]//g;

		# Is this a command?
		if (substr($in,0,1) eq '/') {
			my ($com,@args) = split(' ',substr($in,1));
			$com = substr($in,1) unless defined $com;

			&{$coms{$com}}(@args);

			return;
		}

		# No target.
		last unless defined $ccc;

		# Connect if we don't have a socket.
		&{$coms{'c'}}($ccc) unless defined $clients{$ccc} && defined $clients{$ccc}{'socket'};

		$clients{$ccc}{'socket'}->send($in);
	}
);

# Client list command.
$coms{'l'} = sub {
	print "\n" . 'CLIENT LIST' . "\n";

	foreach my $client (keys %clients) {
		# Remove dead clients.
		if ($clients{$client}{'timestamp'} <= time() - 60) {
			delete $clients{$client};
			$css->remove($clients{$client}{'socket'}) if defined $clients{$client}{'socket'};
		} else {
			print $client . "\n";
		}
	}

	print "\n";
};

# Broadcast command.
$coms{'b'} = sub {
	$txs->send(join(' ',@_));
};

# Connect command.
$coms{'c'} = sub {
	my ($client) = @_;

	# Is there a socket in place already?
	unless ($clients{$client}{'socket'}) {
		my $socket = IO::Socket::INET->new(
			'PeerAddr'	=> $client,
			'PeerPort'	=> 9128
		) or warn($!);

		$clients{$client}{'timestamp'} = time();
		$clients{$client}{'socket'} = $socket;

		$css->add($socket);
	}

	# Set as current chat client.
	$ccc = $client;
};

# Reply command.
$coms{'r'} = sub {
	# Set the current client to whoever talked to us last (if any).
	$ccc = $rcc if defined $rcc;
};

# Start the event loop.
AE::cv->recv();
