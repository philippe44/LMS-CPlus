package Plugins::CPlus::ListProtocolHandler;

use strict;

use Slim::Utils::Log;

use Plugins::CPlus::API;
use Plugins::CPlus::Plugin;

Slim::Player::ProtocolHandlers->registerHandler('cpplaylist', __PACKAGE__);

my $log = logger('plugin.cplus');

sub overridePlayback {
	my ( $class, $client, $url ) = @_;
	my $params;
		
	return undef if $url !~ m|url=(.+)&album=(.+)|i; 
	($params->{url}, $params->{album}) = ($1, $2);
	
	$log->info("playlist override $params->{url}, $params->{album}");
	
	Plugins::CPlus::Plugin->handleSeasons( sub {
			createPlaylist($client, shift); 
		}, undef, $params );
			
	return 1;
}

sub createPlaylist {
	my ( $client, $items ) = @_;
	my @tracks;
		
	for my $item (@{$items}) {
		push @tracks, Slim::Schema->updateOrCreate( { 'url' => $item->{play} } );
	}	
	
	$client->execute([ 'playlist', 'clear' ]);
	$client->execute([ 'playlist', 'addtracks', 'listRef', \@tracks ]);
	$client->execute([ 'play' ]);
}

sub canDirectStream { 1; } 
sub contentType { 'cplus' }
sub isRemote { 1 }


1;
