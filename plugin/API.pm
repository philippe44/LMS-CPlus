package Plugins::CPlus::API;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min max first);
use MIME::base64;
use Exporter qw(import);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

our @EXPORT = qw(obfuscate deobfuscate);
	
my $prefs = preferences('plugin.cplus');
my $log   = logger('plugin.cplus');
my $cache = Slim::Utils::Cache->new();

use constant API_URL => 'http://service.mycanal.fr/authenticate.json/ipad/1.7?geozone=1&highResolution=1&isActivated=0&isAuthenticated=0&paired=0';

sub getSocks {
	my ($server, $port) = split (/:/, $prefs->get('socksProxy'));
	return {
		socks => {
			ProxyAddr => $server,
			ProxyPort => $port,
			Username => deobfuscate($prefs->get('socksUsername')),
			Password => deobfuscate($prefs->get('socksPassword')),
		}	
	};	
}

sub searchProgram {
	my ( $cb ) = @_;
	my ($step1, $step2, $step3);
	
	$step1 = sub {
		my $result = shift;
		
		return $cb->( $result ) if $result->{error};
				
		$result = first { $_->{picto} eq 'OnDemand' } @{$result->{arborescence}};
						
		search( $result->{onClick}->{URLPage}, $step2)
	};
	
	$step2 = sub {
		my $result = shift;
		
		return $cb->( $result ) if $result->{error};
		
		$result = first { $_->{type} eq 'links' } @{$result->{strates}};
		$result = first { $_->{title} eq 'Divertissement' } @{$result->{contents}};
			
		search( $result->{onClick}->{URLPage}, $step3)
	};
	
	$step3 = sub {
		my $result = shift;
				
		return $cb->( $result ) if $result->{error};
		
		$result = first { $_->{type} eq 'contentGrid' } @{$result->{strates}};
		my @list = @{$result->{contents}};
		# $log->debug(Dumper(@list));
		
		$cb->( \@list );
	};
	
	search( API_URL, $step1 );
}


sub searchEpisode {
	my ( $cb, $params ) = @_;
		
	$log->debug("get episodes for $params->{link}");
	
	# list of episodes from an emission link changes pretty quickly
	$params->{_ttl} = 900;
		
	search( $params->{link}, sub {
		my $result = shift;
		
		$result = first { $_->{title} =~ /missions/ || $_->{title} =~ /vid/ } @{$result->{strates}};		
		my @list = @{$result->{contents}};
		@list = sort {$b->{contentID} > $a->{contentID}} @list;
			
		for my $entry (@list) {
								
			$cache->set("cp:meta-" . $entry->{contentID}, 
				{ title    => "$entry->{title} ($entry->{subtitle})",
				  icon     => $entry->{URLImage},
				  cover    => $entry->{URLImage},
				  duration => 0,
				  artist   => $params->{artist},
				  album    => $params->{album},
				  type	   => 'Canal+',
				}, 3600*24) if ( !$cache->get("cp:meta-" . $entry->{contentID}) );
				
		}
		
		$cb->( \@list );
	
	}, $params ); 
	
}	


sub updateMetadata {
	my ( $cb, $url ) = @_;
	my $id = getId($url);
	
	$url =~ m|&artist=([^&]+)&album=(.+)|;
	my ($artist, $album) = ($1, $2);
	
	$log->debug("get metadata for $url ($id $artist $album)");
	
	search( "http://service.canal-plus.com/video/rest/getvideos/cplus/$id?format=json", sub {
		my $result = shift;
											
		$cache->set( "cp:meta-" . $id, 
			{ title    => "$result->{INFOS}->{TITRAGE}->{SOUS_TITRE} ($result->{INFOS}->{TITRAGE}->{TITRE})",
			  icon     => $result->{MEDIA}->{IMAGES}->{GRAND},
			  cover    => $result->{MEDIA}->{IMAGES}->{GRAND},
			  duration => $result->{DURATION},
			  artist   => $artist,
			  album    => $album,
			  type	   => 'Canal+',
			}, 3600*240 );
				
		$cb->( $result );
	
		}
	); 
}


sub search	{
	my ( $url, $cb, $params ) = @_;
	my $cacheKey = md5_hex($url);
	my $cached;
	
	$log->debug("wanted url: $url");
	
	if ( !$prefs->get('no_cache') && ($cached = $cache->get($cacheKey)))  {
		main::INFOLOG && $log->info("Returning cached data for: $url");
		$cb->($cached);
		return;
	}
	
	Slim::Networking::SimpleAsyncHTTP->new(
	
		sub {
			my $response = shift;
			my $result = eval { decode_json($response->content) };
			
			$result ||= {};
			$cache->set($cacheKey, $result, $params->{_ttl} || 3600*24);
			
			$cb->($result, $params);
		},

		sub {
			$log->error($_[1]);
			$cb->( { error => $_[1] } );
		},
		
		getSocks,

	)->get($url);
}


sub getIcon {
	return Plugins::CPlus::Plugin->_pluginDataFor('icon');
}


sub getId {
	my ($url) = @_;

	if ( $url =~ m|(?:cplus)://.+id=(\d+)| ) {
		return $1;
	}
		
	return undef;
}

sub obfuscate {
  # this is vain unless we have a machine-specific ID	
  return MIME::Base64::encode(scalar(reverse(unpack('H*', $_[0]))));
}

sub deobfuscate {
  # this is vain unless we have a machine-specific ID	
  return pack('H*', scalar(reverse(MIME::Base64::decode($_[0]))));
}




1;