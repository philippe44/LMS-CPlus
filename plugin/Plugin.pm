package Plugins::CPlus::Plugin;

# Plugin to stream audio from CPlus videos streams
#
# Released under GPLv2

use strict;

use base qw(Slim::Plugin::OPMLBased);
use File::Spec::Functions;
use Encode qw(encode decode);
use Data::Dumper;

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::CPlus::API;
use Plugins::CPlus::ProtocolHandler;
use Plugins::CPlus::ListProtocolHandler;

# see if HTTP(S)Socks is available
eval "require Slim::Networking::Async::Socket::HTTPSocks" or die "Please update your LMS version to recent build";

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
			
	addPrograms($client, sub {
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
		my $id = Plugins::CPlus::API::getId($item->{'url'});
		
		if (my $lastpos = $cache->get("cp:lastpos-$id")) {
			my $position = Slim::Utils::DateTime::timeFormat($lastpos);
			$position =~ s/^0+[:\.]//;
				
			unshift  @menu, {
				name => $item->{'name'},
				image => $item->{'icon'},
				type => 'link',
				items => [ {
						title => cstring(undef, 'PLUGIN_CPLUS_PLAY_FROM_BEGINNING'),
						type   => 'audio',
						url    => $item->{'url'},
					}, {
						title => cstring(undef, 'PLUGIN_CPLUS_PLAY_FROM_POSITION_X', $position),
						type   => 'audio',
						url    => $item->{'url'} . "&lastpos=$lastpos",
					} ],
				};
		} else {	
		
			unshift  @menu, {
				name => $item->{'name'},
				play => $item->{'url'},
				on_select => 'play',
				image => $item->{'icon'},
				type => 'playlist',
			};
			
		}	
	}

	$callback->({ items => \@menu });
}

sub addPrograms {
	my ($client, $cb, $args) = @_;
		
	Plugins::CPlus::API::searchProgram( sub {
		my $items = [];
		my $result = shift->{contents};
				
		for my $entry ( @{$result} ) {
																							
			push @$items, {
				name  => $entry->{title},
				type  => 'link',
				url   => \&handleProgram,
				image => $entry->{URLImage} || Plugins::CPlus::API::getIcon(),
				passthrough	=> [ { url => $entry->{onClick}->{URLPage}} ],
			};
					
		}
					
		$cb->( $items );
	
	} );	
}

sub handleProgram {
	my ($client, $cb, $args, $params) = @_;
		
	Plugins::CPlus::API::search( $params->{url}, sub {
		my $items = [];
		my $result = shift;
		
		if ( $result->{contents} ) {		
			# we have a sub-program
			for my $entry ( @{$result->{contents}} ) {
				push @$items, {
					name  => $entry->{title},
					type  => 'playlist',
					url   => \&handleSeasons,
					image 			=> $entry->{URLImage} || Plugins::CPlus::API::getIcon(),
					passthrough 	=> [ { url => $entry->{onClick}->{URLPage}, album => $entry->{title} } ],
					favorites_url  	=> "cpplaylist://url=$entry->{onClick}->{URLPage}&album=$entry->{title}",
					favorites_type 	=> 'audio',
				};
			}					
			$cb->( $items );
		} elsif ( $result->{detail}->{seasons} ) {	
			# we have seasons directly, just show latest one
			handleEpisodes( $client, $cb, $args, { 
									url => $result->{detail}->{seasons}->[0]->{onClick}->{URLPage},
									album => $result->{detail}->{informations}->{title} } );
		} elsif ( $result->{detail}->{informations}->{contentAvailability} ) {
			# only on episode in program	
			my $entry = $result->{detail}->{informations};
			
			$cache->set("cp:meta-" . $entry->{contentID}, 
				{ title    => $entry->{title},
				  icon     => $entry->{URLImage},
				  cover    => $entry->{URLImage},
				  type	   => 'Canal+',
				}, '30days') if ( !$cache->get("cp:meta-" . $entry->{contentID}) );

			createItem( $items, $entry, $args && length $args->{index} );				
			$cb->( $items );			
		} else {
			$cb->( undef );
		}	
	} );	
}

sub handleSeasons {
	my ($client, $cb, $args, $params) = @_;
	
	# don't display seasons, go right to latest episodes
	Plugins::CPlus::API::search( $params->{url}, sub {
			my $result = shift;
			return $cb->( $result ) if $result->{error};
			handleEpisodes( $client, $cb, $args, { 
								url => $result->{detail}->{seasons}->[0]->{onClick}->{URLPage}, 
								album => $params->{album} } );
	} );
}	

sub handleEpisodes {
	my ($client, $cb, $args, $params) = @_;
	
	Plugins::CPlus::API::searchEpisode( $params->{url}, sub {
		my $result = shift;
		my $items = [];

		for my $entry (@$result) {
			createItem( $items, $entry, $args && length $args->{index} );
		}
		
		$cb->( $items );				
	}, $params );
}	
			
sub createItem {
	my ($items, $entry, $enable) = @_;
	my $lastpos = $cache->get("cp:lastpos-$entry->{contentID}");
				
	if ($lastpos && $enable) {
		my $position = Slim::Utils::DateTime::timeFormat($lastpos);
		$position =~ s/^0+[:\.]//;

		push @$items, {
			name 		=> $entry->{title},
			type 		=> 'link',
			image 		=> $entry->{URLImage},
			items => [ {
				title => cstring(undef, 'PLUGIN_CPLUS_PLAY_FROM_BEGINNING'),
				type   => 'audio',
				url    => "cplus://id=$entry->{contentID}",
			}, {
				title => cstring(undef, 'PLUGIN_CPLUS_PLAY_FROM_POSITION_X', $position),
				type   => 'audio',
				url    => "cplus://id=$entry->{contentID}&lastpos=$lastpos",
			} ],
		};
		
	} else {

		push @$items, {
			name 		=> $entry->{title},
			type 		=> 'playlist',
			on_select 	=> 'play',
			play 		=> "cplus://id=$entry->{contentID}",
			image 		=> $entry->{URLImage},
			playall		=> 1,
			duration	=> $entry->{duration},					
		};

	}	
}	


1;
