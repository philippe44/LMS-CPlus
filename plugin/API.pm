package Plugins::CPlus::API;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min max first);
use MIME::Base64;
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
	return undef unless $prefs->get('socks');
	my ($server, $port) = split (/:/, $prefs->get('socksProxy'));
	return {
		ProxyAddr => $server,
		ProxyPort => $port,
		Username => deobfuscate($prefs->get('socksUsername')),
		Password => deobfuscate($prefs->get('socksPassword')),
	};	
}

sub searchProgram {
	my ( $cb ) = @_;

	# scrape page for programs
	search( 'https://www.mycanal.fr/chaines/canalplus-en-clair',  sub {
					my $data = shift;
	
					($data) = $data =~ /window\.__data\=(.*?)\; window\.app_config/;
					$data = decode_json($data);
					$data = $data->{templates}->{landing}->{strates};
					($data) = grep { $_->{type} eq "contentRow" && $_->{title} =~/missions Canal/ } @{$data};				
					return $cb->( $data );
				}, {_raw => 1} 
	);
}

sub searchEpisode {
	my ($url, $cb, $params) = @_;
	my $step1;
		
	$log->debug("get episodes for $url");
	
	$step1 = sub {
		my $result = shift;
		return $cb->( $result ) if $result->{error};
		
		my @list = sort { $b->{uploadDate} <=> $a->{uploadDate} } @{$result->{episodes}->{contents}};

		for my $entry (@list) {
			#($entry->{_contentID}) = $entry->{contentAvailability}->{availabilities}->{download}->{URLMedias} =~ /([^\/]+)\.json/;
			$cache->set("cp:meta-" . $entry->{contentID}, 
				{ title    => $entry->{title},
				  icon     => $entry->{URLImage},
				  cover    => $entry->{URLImage},
#				  duration => N/A,
#				  artist   => $params->{artist},
				  album    => $params->{album},
				  type	   => 'Canal+',
				}, '30days') if ( !$cache->get("cp:meta-" . $entry->{contentID}) );
		}	
		
		$cb->( \@list );
	};
	
	search( $url, $step1, { _ttl => 900 } );
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
			my $result = shift->content;
			$result = eval { decode_json($result) } unless $params->{_raw};
			
			$result ||= {};
			$cache->set($cacheKey, $result, $params->{_ttl} || '1days');
			
			$cb->($result, $params);
		},

		sub {
			$log->error($_[1]);
			$cb->( { error => $_[1] } );
		},
		
		#getSocks,

	)->get($url);
}


sub getIcon {
	return Plugins::CPlus::Plugin->_pluginDataFor('icon');
}


sub getId {
	my ($url) = @_;

	if ( $url =~ m|(?:cplus)://id=([^&]+)| ) {
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