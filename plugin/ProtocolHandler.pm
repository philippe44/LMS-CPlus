package Plugins::CPlus::ProtocolHandler;
use base qw(IO::Handle);

use strict;

use List::Util qw(first);
use JSON::XS;
use XML::Simple;
use Data::Dump qw(dump);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::CPlus::m4a;

my $log   = logger('plugin.cplus');
my $prefs = preferences('plugin.cplus');
my $cache = Slim::Utils::Cache->new;

my $crypto = { };

Slim::Player::ProtocolHandlers->registerHandler('cplus', __PACKAGE__);

sub new {
	my ($class, $args) = @_;
	my ($index, $offset) = (0, 0);
	my $song = $args->{'song'};
	my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $track = $song->pluginData('track');
		
	# erase last position from cache
	$cache->remove("cp:lastpos-" . Plugins::CPlus::API::getId($args->{'url'}));
	
	# move to time offset if needed	
	if ( my $newtime = ($seekdata->{'timeOffset'} || $song->pluginData('lastpos')) ) {
		my $timescale = $song->pluginData('timescale');

		TIME: foreach (@{$track->{c}}) {
			for my $c (0..$_->{r} || 0) {
				last TIME if $offset + $_->{d} > $newtime * $timescale;
				$offset += $_->{d};				
			}	
			$index++;			
		}	

		$song->can('startOffset') ? $song->startOffset($newtime) : ($song->{startOffset} = $newtime);
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $newtime);
	}

	my $self = $class->SUPER::new;
	
	if (defined($self)) {
		# set esds parameters
		my $context = { };
		Plugins::CPlus::m4a::setEsds($context, $track->{QualityLevel}->{SamplingRate}, $track->{QualityLevel}->{Channels}, 2);
		
		# set sysread parameters
		${*$self}{'song'}    = $song;
		${*$self}{'vars'} = {         # variables which hold state for this instance: (created by "open")
			'inBuf'       => undef,   #  reference to buffer of received packets
			'index'  	  => $index,  #  current index in fragments
			'fetching'    => 0,		  #  flag for waiting chunk data
			'context'	  => $context,
			'offset'	  => $offset,
		};
	}

	return $self;
}

sub onStop {
    my ($class, $song) = @_;
	my $elapsed = $song->master->controller->playingSongElapsed;
	my $id = Plugins::CPlus::API::getId($song->track->url);
	
	if ($elapsed > 15 && $elapsed < $song->duration - 15) {
	
		$cache->set("cp:lastpos-$id", int ($elapsed), '30days');
		$log->info("Last position for $id is $elapsed");
	} else {
		$cache->remove("cp:lastpos-$id");
	}	
}

sub contentType { 'aac' }
sub isAudio { 1 }
sub isRemote { 1 }
sub songBytes { }
sub canSeek { 1 }

sub formatOverride {
	my $class = shift;
	my $song = shift;
	return $song->pluginData('format') || 'aac';
}

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	return { timeOffset => $newtime };
}

sub sysread {
	use bytes;

	my $self  = $_[0];
	my $v = ${*{$self}}{'vars'};;
		
	# waiting to get next chunk, nothing sor far	
	if ( $v->{'fetching'} ) {
		$! = EINTR;
		return undef;
	}
	
	# end of current segment, get next one
	if ( !defined $v->{'inBuf'} || length ${$v->{'inBuf'}} == 0 ) {
	
		my $song = ${*$self}{song};
		my $track = $song->pluginData('track');
		
		# end of stream
		return 0 if $v->{index} == scalar @{$track->{c}};
		
		# get next fragment/chunk
		my $item = @{$track->{c}}[$v->{index}];
		my $url = $track->{Url};
		
		$url =~ s/{bitrate}/$track->{QualityLevel}->{Bitrate}/;
		$url =~ s/{start time}/$v->{offset}/;
		$url = $song->pluginData('baseURL') . "/$url";
		
		$v->{offset} += $item->{d};
		$v->{repeat}++;
		$v->{fetching} = 1;
				
		if ($v->{repeat} > ($item->{r} || 0)) {
			$v->{index}++;
			$v->{repeat} = 0;
		}
				
		$log->info("fetching: $url");
					
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$v->{inBuf} = $_[0]->contentRef;
				$v->{fetching} = 0;
				$log->debug("got chunk length: ", length ${$v->{inBuf}});
			},
			
			sub { 
				$log->warn("error fetching $url");
				$v->{inBuf} = undef;
				$v->{fetching} = 0;
			}, 
			
			Plugins::CPlus::API::getSocks,
			
		)->get($url);
			
		$! = EINTR;
		return undef;
	}	
	
	my $len = Plugins::CPlus::m4a::getAudio($v->{inBuf}, $v->{context}, $_[1], $_[2]);
	return $len if $len;
	
	$! = EINTR;
	return undef;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $url = $song->track()->url;
	my $client = $song->master();
	my $http;
	my ($step1, $step2, $step3, $step4, $step5);
	
	$song->pluginData(lastpos => ($url =~ /&lastpos=([\d]+)/)[0] || 0);
	$url =~ s/&lastpos=[\d]*//;				
	
	my $id = Plugins::CPlus::API::getId($url);
	
	$log->info("getNextTrack : $url (id: $id)");
	
	if (!$id || !$url) {
		$errorCb->();
		return;
	}	
	
	my %headers;
	
	# get the initial video content
	$step1 = sub {
		%headers = (
			'Accept' => 'application/json, text/plain, */*',
			'Authorization' => "PASS Token=\"$crypto->{token}\"",
			'Content-Type' => 'application/json; charset=UTF-8',
			'XX-DEVICE' => "pc $crypto->{id}",
			'XX-DOMAIN' => 'cpfra',
			'XX-OPERATOR' => 'pc',
			'XX-Profile-Id' => '0',
			'XX-SERVICE' => 'mycanal',
		);		
		$http = Slim::Networking::SimpleAsyncHTTP->new( $step2, $errorCb );
		$http->get( "https://secure-gen-hapi.canal-plus.com/conso/playset?contentId=$id", %headers );
	};
	
	
	# get the list of medias that can be downloaded
	$step2 = sub {	
		my $data = shift->content;	
		eval { $data = decode_json($data) };
		($data) = grep { $_->{distTechnology} eq 'download' } @{$data->{available}};
	
		# there is no PUT in SimpleAsyncSock
		$http = Slim::Networking::Async::HTTP->new;
		$http->send_request( {
			request => HTTP::Request->new( PUT => 'https://secure-gen-hapi.canal-plus.com/conso/view', [%headers], encode_json($data)),
			onError	=> $errorCb,
			onBody => $step3,
			} 
		);		
	};
	
	# for that downloadable, get the URL where to get the content description
	$step3 = sub {
		my $data = shift->response->content;
		eval { $data = decode_json($data) };
		
		$http = Slim::Networking::SimpleAsyncHTTP->new( $step4, $errorCb);
		$http->get($data->{'@medias'}, %headers, encode_json($data));
	};	

	# get the real URL to download it (we need proxy here)
	$step4	= sub {
		my $data = shift->content;	
		eval { $data = decode_json($data) };
		$data = $data->{VF} || $data->{VM} || $data->{VOST};
		return $errorCb->() unless $data ;
		
		my $video = $data->[0]->{media}->[0]->{distribURL};
		$song->pluginData(baseURL => $video);
		$log->info("video url: $video");
		
		$http = Slim::Networking::SimpleAsyncHTTP->new( $step5, $errorCb, Plugins::CPlus::API::getSocks );
		$http->get("$video/manifest");
	};
	
	# get manifest and select audio
	$step5 = sub {
		my $data = shift->content;
		eval { $data = XMLin($data) };
		if ($@) {
			$log->error(dump($data));
			return $errorCb;
		}
		
		my $timescale = $data->{TimeScale} || 10_000_000;
		my $duration = $data->{Duration} / $timescale;
		my ($track) = grep { $_->{Type} eq 'audio' } @{$data->{StreamIndex} };
		$log->info("scale:$timescale duration:$duration");
		
		$song->pluginData( timescale => $timescale );
		$song->pluginData( track => $track );
		$song->track->secs( $duration );
		$song->track->samplerate( $track->{QualityLevel}->{SamplingRate} );
		$song->track->bitrate( $track->{QualityLevel}->{Bitrate} );
		$song->track->channels( $track->{QualityLevel}->{Channels} ); 
		
		if ( my $meta = $cache->get("cp:meta-" . $id) ) {
			$meta->{duration} = $duration;
			$meta->{type} = "aac\@$track->{QualityLevel}->{SamplingRate}Hz";
			$cache->set("cp:meta-" . $id, $meta);
		}	
		
		$client->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
				
		$successCb->();
	};
	
	getCrypto( $step1, $errorCb );
}

sub getCrypto {
	my ($successCb, $errorCb) = @_;
	my $http;
	my ($step1, $step2, $step3);

	# get crypto from cahce if possible
	return $successCb->() if $crypto = $cache->get('cp-crypto');
	
	$log->info('getting crypto');
	
	# get the portail_id
	$step1 = sub {
		my $data = shift->content;
		my ($data) = $data =~ /window\.app_config=(.*?});/;
		
		eval { $data = decode_json($data) };
		$crypto->{portail} = $data->{api}->{pass}->{portailIdEncrypted};
		
		$http = Slim::Networking::SimpleAsyncHTTP->new( $step2, $errorCb );
		$http->get('https://pass.canal-plus.com/service/HelloJSON.php',
					 referer => 'https://secure-player.canal-plus.com/one/prod/v2/');
	};
	
	# get the device_id
	$step2 = sub {
		my $data = shift->content;
		my ($device_id_seed) = $data =~ /"deviceId"[^:]*:[^"]*"([^"]+)/;
		
		my $content = "deviceId=$device_id_seed" . "&vect=INTERNET" . "&media=PC" . "&portailId=$crypto->{portail}";
		$http = Slim::Networking::SimpleAsyncHTTP->new( $step3, $errorCb );
		$http->post('https://pass-api-v2.canal-plus.com/services/apipublique/createToken', $content);
	};
	
	# get the pass_token and device_id
	$step3 = sub {
		my $data = shift->content;
		
		eval { $data = decode_json($data) };
		$crypto->{token} = $data->{response}->{passToken};
		$crypto->{id} = $data->{response}->{userData}->{deviceId};
		$cache->set('cp-crypto', $crypto, 3600);
		$log->info('crypto', dump($crypto));

		$successCb->();
	};
	
	Slim::Networking::SimpleAsyncHTTP->new( $step1, $errorCb )->get('https://www.mycanal.fr/chaines/canalplus-en-clair' );
}

sub getMetadataFor {
	my ($class, $client, $url) = @_;
	
	main::DEBUGLOG && $log->debug("getmetadata: $url");
	
	$url =~ s/&lastpos=[\d]*//;				
	my $id = Plugins::CPlus::API::getId($url);
			
	if ( my $meta = $cache->get("cp:meta-$id") ) {
						
		Plugins::CPlus::Plugin->updateRecentlyPlayed({
			url   => $url, 
			name  => $meta->{_fulltitle} || $meta->{title}, 
			icon  => $meta->{icon},
		});
		
		main::DEBUGLOG && $log->debug("cache hit: $id");
		
		return $meta;
	}	
	
	# For non-playing (yet) item, there is little interest to populate the metadata 
	# as getting real duration requires a lot digging into the actual links and that
	# is a lot network accesses - so, give up if it's not already in the cache
	
	my $icon = Plugins::CPlus::API::getIcon();
			
	return { type	=> 'Canal+',
			 title	=> 'Canal+',
			 icon	=> $icon,
			 cover	=> $icon,
			};
}	


1;
