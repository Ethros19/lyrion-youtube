package Plugins::YouTubeDirect::API;

# YouTube Data API v3 client, used only when an API key is set (ours, or the
# one already entered in the YouTube plugin's settings). It's faster than
# yt-dlp for search and browsing, but has a daily quota (searches cost 100
# of 10,000 units); when the key is missing, rejected or out of quota,
# Source.pm falls back to yt-dlp.

use strict;
use utf8;

use HTTP::Request;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::YouTubeDirect::Util qw(iso8601Duration);

use constant BASE => 'https://www.googleapis.com/youtube/v3/';

my $log   = logger('plugin.youtubedirect');
my $prefs = preferences('plugin.youtubedirect');
my $cache = Slim::Utils::Cache->new;

my $suspendedUntil = 0;    # after quotaExceeded / a rejected key
my $suspendedKey   = '';
my $lastError;

sub key {
	my $key = $prefs->get('apiKey');
	$key = preferences('plugin.youtube')->get('APIkey') unless $key;
	$key =~ s/^\s+|\s+$//g if defined $key;
	return $key || undef;
}

sub keySource {
	return 'own' if $prefs->get('apiKey');
	return 'youtube' if key();
	return;
}

sub lastError { $lastError }

# Is the API worth trying right now?
sub available {
	my $key = key() || return 0;
	return 1 if $key ne $suspendedKey;
	return time() >= $suspendedUntil;
}

sub _suspend {
	my ($reason, $secs) = @_;
	$suspendedKey = key() // '';
	$suspendedUntil = time() + $secs;
	$lastError = $reason;
	$log->warn("YouTube Data API unavailable ($reason); using yt-dlp for " . int($secs / 60) . " min");
}

# GET <endpoint>?<params>&key=...: cb->(data) or cb->(undef, reason)
sub call {
	my ($class, $endpoint, $params, $cb, $ttl) = @_;

	my $key = key() || return $cb->(undef, 'no key');
	my $query = join('&', map { "$_=" . uri_escape_utf8($params->{$_}) } sort grep { defined $params->{$_} } keys %$params);
	my $cacheKey = "ytd:api:$endpoint?$query";

	if ($ttl && (my $cached = $cache->get($cacheKey))) {
		return $cb->($cached);
	}

	my $url = BASE . "$endpoint?$query&key=" . uri_escape_utf8($key);
	my $request = HTTP::Request->new(GET => $url);
	$request->protocol('HTTP/1.1');
	$request->header('User-Agent' => 'Lyrion Music Server (YouTubeDirect)');
	$request->header(Accept => 'application/json');

	main::DEBUGLOG && $log->debug("API $endpoint?$query");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $data = eval { from_json(shift->content) };
			if (!$data || $data->{error}) {
				$log->error("API $endpoint: bad response");
				return $cb->(undef, 'bad response');
			}
			$lastError = undef;
			$cache->set($cacheKey, $data, $ttl) if $ttl;
			$cb->($data);
		},
		sub {
			my ($http, $error) = @_;
			my $data = $http && $http->can('content') && eval { from_json($http->content) };
			my $err = $data && $data->{error} || {};
			my $reason = ($err->{errors} && $err->{errors}[0] && $err->{errors}[0]{reason}) || $err->{status} || $error;
			my $message = $err->{message} || $error;

			# LMS often doesn't hand us the error body, so go by status too:
			# Google answers a bad key with 400 and quota/access problems with 403
			if ($reason =~ /quota|rateLimit/i) {
				_suspend('daily quota used up', 3600);
			}
			elsif ($reason =~ /keyInvalid|API_KEY_INVALID|accessNotConfigured|forbidden|keyExpired/i || $message =~ /API key/i || $error =~ /^400/) {
				_suspend("API key rejected ($message)", 6 * 3600);
			}
			elsif ($error =~ /^403/) {
				_suspend("API refused the request ($message): quota used up, or the YouTube Data API isn't enabled for this key", 3600);
			}
			else {
				$log->error("API $endpoint failed: $reason ($message)");
			}
			$cb->(undef, $reason);
		},
		{ timeout => 15, request => $request },
	)->get($url);
}

# -- normalizers -------------------------------------------------------------

sub _thumb {
	my $t = shift || return;
	for (qw(high medium default)) {
		return $t->{$_}{url} if $t->{$_} && $t->{$_}{url};
	}
	return;
}

# search.list item / playlistItems.list item / videos.list item -> our shapes
sub normalize {
	my ($class, $item) = @_;
	my $s = $item->{snippet} || {};
	my $kind = $item->{kind} || '';
	my $id = $item->{id};

	if ($kind eq 'youtube#searchResult') {
		my $k = $id->{kind} || '';
		return { type => 'video', id => $id->{videoId}, title => $s->{title}, channel => $s->{channelTitle}, channel_id => $s->{channelId}, published => $s->{publishedAt}, live => ($s->{liveBroadcastContent} || '') eq 'live' ? 1 : 0 } if $k eq 'youtube#video';
		return { type => 'channel', id => $id->{channelId}, title => $s->{title}, thumb => _thumb($s->{thumbnails}) } if $k eq 'youtube#channel';
		return { type => 'playlist', id => $id->{playlistId}, title => $s->{title}, channel => $s->{channelTitle}, thumb => _thumb($s->{thumbnails}) } if $k eq 'youtube#playlist';
		return;
	}
	if ($kind eq 'youtube#playlistItem') {
		my $vid = $item->{contentDetails} && $item->{contentDetails}{videoId} || $s->{resourceId} && $s->{resourceId}{videoId} or return;
		return if ($s->{title} || '') =~ /^(?:Private|Deleted) video$/;
		return { type => 'video', id => $vid, title => $s->{title}, channel => $s->{videoOwnerChannelTitle} || $s->{channelTitle}, channel_id => $s->{videoOwnerChannelId} || $s->{channelId}, published => $item->{contentDetails} && $item->{contentDetails}{videoPublishedAt} || $s->{publishedAt} };
	}
	if ($kind eq 'youtube#playlist') {
		return { type => 'playlist', id => $id, title => $s->{title}, channel => $s->{channelTitle}, count => $item->{contentDetails} && $item->{contentDetails}{itemCount}, thumb => _thumb($s->{thumbnails}) };
	}
	if ($kind eq 'youtube#channel') {
		return { type => 'channel', id => $id, title => $s->{title}, thumb => _thumb($s->{thumbnails}) };
	}
	return;
}

# Fill in durations (search and playlist items don't carry them): 1 unit per 50
sub addDurations {
	my ($class, $items, $cb) = @_;
	my @ids = map { $_->{id} } grep { $_->{type} eq 'video' && !defined $_->{duration} } @$items;
	return $cb->($items) unless @ids;

	$class->call('videos', { part => 'contentDetails', id => join(',', splice(@ids, 0, 50)), maxResults => 50 }, sub {
		my $data = shift;
		my %dur = map { $_->{id} => iso8601Duration($_->{contentDetails} && $_->{contentDetails}{duration}) } @{ $data && $data->{items} || [] };
		for (@$items) {
			$_->{duration} = $dur{ $_->{id} } if $_->{type} eq 'video' && !defined $_->{duration};
		}
		$cb->($items);
	}, 86400);
}

1;
