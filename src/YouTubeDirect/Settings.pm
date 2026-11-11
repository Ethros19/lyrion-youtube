package Plugins::YouTubeDirect::Settings;

use strict;
use base qw(Slim::Web::Settings);

use POSIX qw(strftime);

use Slim::Utils::Prefs;

use Plugins::YouTubeDirect::API;
use Plugins::YouTubeDirect::SponsorBlock;
use Plugins::YouTubeDirect::YtDlp;

my $prefs = preferences('plugin.youtubedirect');

my $updateMessage;

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_YOUTUBEDIRECT');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/YouTubeDirect/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(apiKey ytdlpPath autoUpdate));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ($params->{saveSettings}) {
		$params->{pref_apiKey} =~ s/^\s+|\s+$//g if defined $params->{pref_apiKey};
		$params->{pref_ytdlpPath} =~ s/^\s+|\s+$//g if defined $params->{pref_ytdlpPath};
		$params->{pref_autoUpdate} ||= 0;

		my $all = Plugins::YouTubeDirect::SponsorBlock::CATEGORIES;
		$prefs->set(categories => [ grep { $params->{"cat_$_"} } @$all ]);
	}

	if ($params->{updateYtdlp}) {
		$updateMessage = Slim::Utils::Strings::string('PLUGIN_YOUTUBEDIRECT_YTDLP_UPDATING');
		Plugins::YouTubeDirect::YtDlp->update(sub {
			my ($msg, $error) = @_;
			$error = Slim::Utils::Strings::string($error) if $error && $error =~ /^PLUGIN_/;
			$updateMessage = $error ? "yt-dlp: $error" : "yt-dlp: $msg";
		});
	}

	return $class->SUPER::handler($client, $params, $callback, @args);
}

sub beforeRender {
	my ($class, $params) = @_;

	my $ytdlp = 'Plugins::YouTubeDirect::YtDlp';
	my $bin = $ytdlp->binary;
	$ytdlp->checkVersion(sub {}) if $bin && !$ytdlp->version;

	my $last = $prefs->get('lastUpdate');
	$params->{ytdVersion}      = Plugins::YouTubeDirect::Plugin->_pluginDataFor('version');
	$params->{ytdYtdlpPath}    = $bin;
	$params->{ytdYtdlpVersion} = $ytdlp->version;
	$params->{ytdYtdlpManaged} = $ytdlp->isManaged;
	$params->{ytdYtdlpAsset}   = $ytdlp->asset;
	$params->{ytdYtdlpError}   = $ytdlp->lastError;
	$params->{ytdYtdlpUpdated} = $last ? strftime('%Y-%m-%d %H:%M', localtime $last) : '';
	$params->{ytdUpdateMessage} = $updateMessage;

	$params->{ytdKeySource} = Plugins::YouTubeDirect::API->keySource;
	$params->{ytdKeyError}  = Plugins::YouTubeDirect::API->lastError;

	my %on = map { $_ => 1 } @{ Plugins::YouTubeDirect::SponsorBlock::enabledCategories() };
	$params->{ytdCategories} = [ map { { id => $_, on => $on{$_} ? 1 : 0 } } @{ Plugins::YouTubeDirect::SponsorBlock::CATEGORIES() } ];

	$params->{ytdFollows} = scalar keys %{ $prefs->get('follows') || {} };
	$params->{ytdProject} = 'https://github.com/Ethros19/lyrion-youtube';
	$params->{ytdIssues}  = 'https://github.com/Ethros19/lyrion-youtube/issues';
}

1;
