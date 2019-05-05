package Plugins::CPlus::Settings;
use base qw(Slim::Web::Settings);

use strict;

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log = logger('plugin.CPlus');

sub name {
	return 'PLUGIN_CPLUS';
}

sub page {
	return 'plugins/CPlus/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.cplus'), qw(socks no_cache));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;
	
	$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}

	
1;
