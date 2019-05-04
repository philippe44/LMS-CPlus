package Slim::Networking::Async::Socket::HTTPSSocks;

use strict;
use IO::Socket::Socks;

use base qw(IO::Socket::SSL IO::Socket::Socks Net::HTTP::Methods Slim::Networking::Async::Socket);

sub new {
	my ($class) = shift;
	
	# create a SOCKS object and connect
	my $sock = IO::Socket::Socks->new(@_);
		
	# now create the SOCKS object and it will call connect below 
	IO::Socket::SSL->start_SSL($sock, @_);
	
	# as we inherit from IO::Socket::SSL, we can bless to our base class
	bless $sock;
}


sub close {
	my $self = shift;

	# remove self from select loop
	Slim::Networking::Select::removeError($self);
	Slim::Networking::Select::removeRead($self);
	Slim::Networking::Select::removeWrite($self);
	Slim::Networking::Select::removeWriteNoBlockQ($self);

	$self->SUPER::close();
}

1;