package Plugins::CPlus::ProtocolHandler;
use base qw(IO::Handle);

use strict;

use List::Util qw(first);
use JSON::XS;
use Data::Dumper;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::CPlus::MPEGTS;

my $log   = logger('plugin.cplus');
my $prefs = preferences('plugin.cplus');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerHandler('cplus', __PACKAGE__);

sub new {
	my $class = shift;
	my $args  = shift;
	my $song  = $args->{'song'};
	my $index = 0;
	my $seekdata   = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
		
	if ( my $newtime = $seekdata->{'timeOffset'} ) {
		my $streams = \@{$args->{song}->pluginData('streams')};
		
		$index = first { $streams->[$_]->{position} >= int $newtime } 0..scalar @$streams;
		
		$song->can('startOffset') ? $song->startOffset($newtime) : ($song->{startOffset} = $newtime);
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $newtime);
	}

	my $self = $class->SUPER::new;
	
	if (defined($self)) {
		${*$self}{'song'}    = $args->{'song'};
		${*$self}{'vars'} = {         # variables which hold state for this instance: (created by "open")
			'inBuf'       => undef,   #  reference to buffer of received packets
			'state'       => Plugins::CPlus::MPEGTS::SYNCHRO, #  mpeg2ts decoder state
			'index'  	  => $index,  #  current index in fragments
			'fetching'    => 0,		  #  flag for waiting chunk data
			'pos'		  => 0,		  #  position in the latest input buffer
		};
	}

	return $self;
}

sub contentType { 'aac' }
	
sub formatOverride {
	my $class = shift;
	my $song = shift;

	return $song->pluginData('format') || 'aac';
}

sub isAudio { 1 }

sub isRemote { 1 }

sub songBytes { }

sub canSeek { 1 }

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;

	return { timeOffset => $newtime };
}

sub vars {
	return ${*{$_[0]}}{'vars'};
}


sub sysread {
	use bytes;

	my $self  = $_[0];
	# return in $_[1]
	my $maxBytes = $_[2];
	my $v = $self->vars;
		
	# waiting to get next chunk, nothing sor far	
	if ( $v->{'fetching'} ) {
		$! = EINTR;
		return undef;
	}
			
	# end of current segment, get next one
	if ( !defined $v->{'inBuf'} || $v->{'pos'} == length ${$v->{'inBuf'}} ) {
	
		# end of stream
		return 0 if $v->{index} == scalar @{${*$self}{song}->pluginData('streams')};
		
		# get next fragment/chunk
		my $url = @{${*$self}{song}->pluginData('streams')}[$v->{index}]->{url};
		$v->{index}++;
		$v->{'pos'} = 0;
		$v->{'fetching'} = 1;
						
		$log->info("fetching: $url");
		my $socks = { socksAddr => $prefs->get('socks_server'), socksPort => $prefs->get('socks_port') } if $prefs->get('socks'); 
			
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$v->{'inBuf'} = $_[0]->contentRef;
				$v->{'fetching'} = 0;
				$log->debug("got chunk length: ", length ${$v->{'inBuf'}});
			},
			
			sub { 
				$log->warn("error fetching $url");
				$v->{'inBuf'} = undef;
				$v->{'fetching'} = 0;
			}, 
			
			$socks
			
		)->get($url);
			
		$! = EINTR;
		return undef;
	}	
				
	my $len = Plugins::CPlus::MPEGTS::processTS($v, \$_[1], $maxBytes);
			
	return $len if $len;
	
	$! = EINTR;
	return undef;
}


sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $url 	 = $song->track()->url;
	my $client   = $song->master();
	my ($id)	 = Plugins::CPlus::API::getId($url);
	
	$log->info("getNextTrack : $url (id: $id)");
	
	if (!$id || !$url) {
		$errorCb->();
		return;
	}	
			
	getFragments( 
	
		sub {
			my $fragments = shift;
			my $bitrate = shift;
					
			return $errorCb->() unless (defined $fragments && scalar @$fragments);
			
			my ($server) = Slim::Utils::Misc::crackURL( $fragments->[0]->{url} );
						
			$song->pluginData(streams => $fragments);	
			$song->pluginData(stream  => $server);
			$song->pluginData(format  => 'aac');
			$song->track->bitrate( $bitrate );
									
			getSampleRate( $fragments->[0]->{url}, sub {
				my $sampleRate = shift || 48000;
							
				$song->track->samplerate( $sampleRate );
							
				$client->currentPlaylistUpdateTime( Time::HiRes::time() );
				Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
																				
				$successCb->();
			} );
						
		} , $id, $song 
		
	);
}	


sub getSampleRate {
	use bytes;
	
	my ($url, $cb) = @_;
	my $socks = { socksAddr => $prefs->get('socks_server'), socksPort => $prefs->get('socks_port') } if $prefs->get('socks'); 
	
	Slim::Networking::SimpleAsyncHTTP->new ( 
	sub {
			my $data = shift->content;
					
			return $cb->( undef ) if !defined $data;
			
			my $adts;
			my $v = { 'inBuf' => \$data,
					  'pos'   => 0, 
					  'state' => Plugins::CPlus::MPEGTS::SYNCHRO } ;
			my $len = Plugins::CPlus::MPEGTS::processTS($v, \$adts, 256); # must be more than 188
			
			return $cb->( undef ) if !$len || (unpack('n', substr($adts, 0, 2)) & 0xFFF0 != 0xFFF0);
						
			my $sampleRate = (unpack('C', substr($adts, 2, 1)) & 0x3c) >> 2;
			my @rates = ( 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 
						  12000, 11025, 8000, 7350, undef, undef, undef );
						
			$sampleRate = $rates[$sampleRate];			
			$log->info("AAC samplerate: $sampleRate");
			$cb->( $sampleRate );
		},

		sub {
			$log->warn("HTTP error, cannot find sample rate");
			$cb->( undef );
		},
		
		$socks

	)->get( $url, 'Range' => 'bytes=0-16384' );

}


sub getFragments {
	my ($cb, $id, $song) = @_;
	my $url	= "http://service.canal-plus.com/video/rest/getvideos/cplus/$id?format=json";
	my $socks = { socksAddr => $prefs->get('socks_server'), socksPort => $prefs->get('socks_port') } if $prefs->get('socks'); 
			
	$log->debug("getting master url for : $url");
	
	Slim::Networking::SimpleAsyncHTTP->new ( 
		sub {
			my $result = decode_json(shift->content);
			my $master = $result->{MEDIA}->{VIDEOS}->{HLS};
						
			$song->track->secs( $result->{DURATION} );
			
			$log->debug("master url: $master");
			
			getFragmentsUrl($cb, $master);
		},

		sub {
			$cb->(undef);
		},
		
		$socks

	)->get($url);
}


sub getFragmentsUrl {
	my ($cb, $url) = @_;
	my $socks = { socksAddr => $prefs->get('socks_server'), socksPort => $prefs->get('socks_port') } if $prefs->get('socks'); 
				
	Slim::Networking::SimpleAsyncHTTP->new ( 
		sub {
			my $result = shift->content;
			my $bitrate;
			my $fragmentUrl;
				
			for my $item ( split (/#EXT-X-STREAM-INF:/, $result) ) {
				next if ($item !~ m/BANDWIDTH=(\d+),([\S\s]*)(http\S*)/s); 
					
				if (!defined $bitrate || $1 < $bitrate) {
					$bitrate = $1;
					$fragmentUrl = $3;
				}
			}
			
			$log->debug("fragment url: $fragmentUrl");
			
			getFragmentList($cb, $fragmentUrl, $bitrate);
		},
			
		sub {
			$cb->(undef);
		},
		
		$socks
		
	)->get($url);
}	


sub getFragmentList {
	my ($cb, $url, $bitrate) = @_;
	my $socks = { socksAddr => $prefs->get('socks_server'), socksPort => $prefs->get('socks_port') } if $prefs->get('socks'); 
			
	Slim::Networking::SimpleAsyncHTTP->new ( 
		sub {
			my $fragmentList = shift->content;
			my @fragments;
			my $position = 0;
					
			$log->debug("got fragment list: $fragmentList");
			
			for my $item ( split (/#EXTINF:/, $fragmentList) ) {
				$item =~ m/([^,]+),([\S\s]*)(http\S*)/s;
				$position += $1 if $3;
				push @fragments, { position => $position, url => $3 } if $3;
			}	
									
			$cb->(\@fragments, $bitrate);
		},	
			
		sub {
			$cb->(undef);
		},
		
		$socks
					
	)->get($url);
}	


sub getMetadataFor {
	my ($class, $client, $url) = @_;
	my $icon = Plugins::CPlus::API::getIcon();
		
	main::DEBUGLOG && $log->debug("getmetadata: $url");
			
	my $id = Plugins::CPlus::API::getId($url);
	return unless $id;
	
	my $meta = $cache->get("cp:meta-$id");
	
	if ( $meta && $meta->{duration} ) {
						
		Plugins::CPlus::Plugin->updateRecentlyPlayed({
			url   => $url, 
			name  => $meta->{_fulltitle} || $meta->{title}, 
			icon  => $meta->{icon},
		});
		
		main::DEBUGLOG && $log->debug("cache hit: $id");
		
		return $meta;
	}	

	Plugins::CPlus::API::updateMetadata( sub {
						
		if ($client) {
			$client->currentPlaylistUpdateTime( Time::HiRes::time() );
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		}
		
	}, $url );
			
	return { type	=> 'Canal+',
			 title	=> 'Canal+',
			 icon	=> $icon,
			 cover	=> $icon,
			};
}	


1;
