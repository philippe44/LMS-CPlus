package Plugins::CPlus::Plugin;

# Plugin to stream audio from CPlus videos streams
#
# Released under GPLv2

use strict;
use base qw(Slim::Plugin::OPMLBased);
use File::Spec::Functions;

use Encode qw(encode decode);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::CPlus::API;
use Plugins::CPlus::ProtocolHandler;
use Plugins::CPlus::ListProtocolHandler;

# see if HTTP(S)Socks is available
eval "require Slim::Networking::Async::Socket::HTTPSocks";
if ($@) {
	eval "require Plugins::CPlus::Slim::HTTPSocks";
	eval "require Plugins::CPlus::Slim::HTTPSSocks";
	eval "require Plugins::CPlus::Slim::Misc";
}

my $WEBLINK_SUPPORTED_UA_RE = qr/iPeng|SqueezePad|OrangeSqueeze/i;

use constant IMAGE_URL => 'http://refonte.webservices.francetelevisions.fr';

my	$log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.cplus',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_CPLUS',
});

my $prefs = preferences('plugin.cplus');
my $cache = Slim::Utils::Cache->new;

$prefs->init({ 
	prefer_lowbitrate => 0, 
	recent => [], 
	max_items => 200, 
});

tie my %recentlyPlayed, 'Tie::Cache::LRU', 50;

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'cplus',
		menu   => 'radios',
		is_app => 1,
		weight => 10,
	);

	if ( main::WEBUI ) {
		require Plugins::CPlus::Settings;
		Plugins::CPlus::Settings->new;
	}
	
	for my $recent (reverse @{$prefs->get('recent')}) {
		$recentlyPlayed{ $recent->{'url'} } = $recent;
	}
	
#        |requires Client
#        |  |is a Query
#        |  |  |has Tags
#        |  |  |  |Function to call
	Slim::Control::Request::addDispatch(['cplus', 'info'], 
		[1, 1, 1, \&cliInfoQuery]);
		
	
}

sub shutdownPlugin {
	my $class = shift;

	$class->saveRecentlyPlayed('now');
}

sub getDisplayName { 'PLUGIN_CPLUS' }

sub updateRecentlyPlayed {
	my ($class, $info) = @_;

	$recentlyPlayed{ $info->{'url'} } = $info;

	$class->saveRecentlyPlayed;
}

sub saveRecentlyPlayed {
	my $class = shift;
	my $now   = shift;

	unless ($now) {
		Slim::Utils::Timers::killTimers($class, \&saveRecentlyPlayed);
		Slim::Utils::Timers::setTimer($class, time() + 10, \&saveRecentlyPlayed, 'now');
		return;
	}

	my @played;

	for my $key (reverse keys %recentlyPlayed) {
		unshift @played, $recentlyPlayed{ $key };
	}

	$prefs->set('recent', \@played);
}

sub toplevel {
	my ($client, $callback, $args) = @_;
			
	addChannels($client, sub {
			my $items = shift;
			
			unshift @$items, { name => cstring($client, 'PLUGIN_CPLUS_RECENTLYPLAYED'), image => Plugins::CPlus::API::getIcon(), url  => \&recentHandler };
			
			$callback->( $items );
		}, $args
	);
}

sub recentHandler {
	my ($client, $callback, $args) = @_;

	my @menu;

	for my $item(reverse values %recentlyPlayed) {
		unshift  @menu, {
			name => $item->{'name'},
			play => $item->{'url'},
			on_select => 'play',
			image => $item->{'icon'},
			type => 'playlist',
		};
	}

	$callback->({ items => \@menu });
}


sub addChannels {
	my ($client, $cb, $args) = @_;
		
	Plugins::CPlus::API::searchProgram( sub {
		my $items = [];
		my $result = shift;
				
		for my $entry ( @{$result} ) {
																							
			push @$items, {
				name  => $entry->{onClick}->{displayName},
				type  => 'playlist',
				url   => \&addEpisodes,
				image 			=> $entry->{URLImage} || Plugins::CPlus::API::getIcon(),
				passthrough 	=> [ { link => $entry->{onClick}->{URLPage}, 
									   artist => $entry->{subtitle}, album => $entry->{title} } ],
				favorites_url  	=> "cpplaylist://link=$entry->{onClick}->{URLPage}&artist=$entry->{subtitle}&album=$entry->{title}",
				favorites_type 	=> 'audio',
			};
					
		}
					
		$cb->( $items );
	
	} );	
}


sub addEpisodes {
	my ($client, $cb, $args, $params) = @_;
	
	Plugins::CPlus::API::searchEpisode( sub {
		my $result = shift;
		my $items = [];
				
		for my $entry (@$result) {
		
			push @$items, {
				name 		=> "$entry->{title} ($entry->{subtitle})",
				type 		=> 'playlist',
				on_select 	=> 'play',
				play 		=> "cplus://$entry->{onClick}->{URLPage}&artist=$params->{artist}&album=$params->{album}",
				image 		=> $entry->{URLImage},
			};
			
		}
		
		$cb->( $items );
		
	}, $params );
}



1;
