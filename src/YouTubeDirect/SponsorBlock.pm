package Plugins::YouTubeDirect::SponsorBlock;

# Crowd-sourced segments to skip (sponsor reads, self-promotion, the
# non-music parts of music videos...) from sponsor.ajay.app. Only the video
# id is sent. Any failure just means "nothing to skip": playback never waits
# more than a few seconds on it.

use strict;
use utf8;

use HTTP::Request;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::YouTubeDirect::Util qw(skipSegments);

use constant API => 'https://sponsor.ajay.app/api/skipSegments';

# every category we offer in settings, in display order
use constant CATEGORIES => [qw(sponsor selfpromo interaction music_offtopic intro outro preview filler)];
use constant DEFAULTS   => [qw(sponsor selfpromo interaction music_offtopic)];

my $log   = logger('plugin.youtubedirect');
my $prefs = preferences('plugin.youtubedirect');
my $cache = Slim::Utils::Cache->new;

sub enabledCategories {
	my $cats = $prefs->get('categories');
	return ref $cats eq 'ARRAY' ? $cats : DEFAULTS;
}

# cb->([[start, end], ...]) for the enabled categories (unmerged)
sub get {
	my ($class, $id, $cb) = @_;

	my $cats = enabledCategories();
	return $cb->([]) unless @$cats;

	my $key = "ytd:sb:$id";
	if (my $cached = $cache->get($key)) {
		return $cb->(skipSegments($cached, $cats));
	}

	# ask for every category and filter locally, so changing the settings
	# doesn't need a new request
	my $url = API . '?videoID=' . uri_escape_utf8($id)
	        . '&categories=' . uri_escape_utf8(to_json(CATEGORIES))
	        . '&actionTypes=' . uri_escape_utf8('["skip"]');

	my $request = HTTP::Request->new(GET => $url);
	$request->protocol('HTTP/1.1');
	$request->header('User-Agent' => 'Lyrion Music Server (YouTubeDirect)');

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $data = eval { from_json(shift->content) };
			$data = [] unless ref $data eq 'ARRAY';
			$cache->set($key, $data, 6 * 3600);
			main::INFOLOG && $log->info("SponsorBlock: " . scalar(@$data) . " segment(s) for $id");
			$cb->(skipSegments($data, $cats));
		},
		sub {
			my ($http, $error) = @_;
			# 404 is SponsorBlock for "no segments"
			if ($error =~ /404/) {
				$cache->set($key, [], 6 * 3600);
				main::INFOLOG && $log->info("SponsorBlock: no segments for $id");
			}
			else {
				$log->warn("SponsorBlock lookup failed for $id: $error");
			}
			$cb->([]);
		},
		{ timeout => 5, request => $request },
	)->get($url);
}

1;
