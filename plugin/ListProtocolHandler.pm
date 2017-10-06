package Plugins::CPlus::ListProtocolHandler;

use strict;

use Slim::Utils::Log;

use Plugins::CPlus::API;
use Plugins::CPlus::Plugin;
use Data::Dumper;

Slim::Player::ProtocolHandlers->registerHandler('cpplaylist', __PACKAGE__);

my $log = logger('plugin.cplus');

sub overridePlayback {
	my ( $class, $client, $url ) = @_;
	my $params;
		
	return undef if $url !~ m|link=(.+)&artist=([^&]+)&album=(.+)|i; 
	($params->{link}, $params->{artist}, $params->{album}) = ($1, $2, $3);
	
	$log->error("playlist override $params->{link}, $params->{artist}, $params->{album}");
	
	Plugins::CPlus::Plugin->addEpisodes( sub {
			my $result = shift;
			
			createPlaylist($client, $result); 
			
		}, undef, $params );
			
	return 1;
}

sub createPlaylist {
	my ( $client, $items ) = @_;
	my @tracks;
		
	for my $item (@{$items}) {
		push @tracks, Slim::Schema->updateOrCreate( {
				'url'        => $item->{play} });
	}	
	
	$client->execute([ 'playlist', 'clear' ]);
	$client->execute([ 'playlist', 'addtracks', 'listRef', \@tracks ]);
	$client->execute([ 'play' ]);
}

sub canDirectStream {
	return 1;
}

sub contentType {
	return 'cplus';
}

sub isRemote { 1 }


1;
