package Plugins::YouTubeDirect::Source;

# Where menus get their data: the YouTube Data API when a key is set and
# working, otherwise yt-dlp. Either way callers get the same shapes:
#   video    { type, id, title, channel, channel_id, duration, published }
#   channel  { type, id, title, thumb }
#   playlist { type, id, title, channel, count, thumb }
# and cb->({ items => [...], next => $page }) or cb->(undef, $stringToken).
# A page is { token => ... } (API) or { start => n } (yt-dlp).

use strict;
use utf8;

use HTTP::Request;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::YouTubeDirect::API;
use Plugins::YouTubeDirect::YtDlp;
use Plugins::YouTubeDirect::Util qw(flatEntries parseRss uploadsPlaylist isChannelId);

use constant PAGE => 50;

my $log   = logger('plugin.youtubedirect');
my $cache = Slim::Utils::Cache->new;

# what we know about videos we've listed, for now-playing
my %videos;

sub remember {
	my ($class, $items) = @_;
	for my $v (grep { $_->{type} eq 'video' && $_->{id} } @{ $items || [] }) {
		$videos{ $v->{id} } = { %{ $videos{ $v->{id} } || {} }, map { defined $v->{$_} ? ($_ => $v->{$_}) : () } qw(id title channel channel_id duration) };
	}
	return $items;
}

sub video {
	my ($class, $id) = @_;
	return $videos{$id} ||= $cache->get("ytd:video:$id");
}

# after a successful resolve: keep it for later sessions too
sub store {
	my ($class, $id, $info) = @_;
	my $v = $videos{$id} = { %{ $videos{$id} || {} }, %$info, id => $id };
	$cache->set("ytd:video:$id", $v, '30 days');
	return $v;
}

sub _api { Plugins::YouTubeDirect::API->available }

sub _done {
	my ($class, $cb, $items, $next) = @_;
	$class->remember($items);
	$cb->({ items => $items, next => $next });
}

# -- yt-dlp listings -------------------------------------------------------------

sub _ytdlp {
	my ($class, $url, $page, $cb, $ttl) = @_;
	my $from = $page && $page->{start} || 1;
	my $to = $from + PAGE - 1;
	$url =~ s/\{TO\}/$to/;

	Plugins::YouTubeDirect::YtDlp->list($url, $from, $to, sub {
		my ($data, $error) = @_;
		return $cb->(undef, $error) unless $data;
		my $items = flatEntries($data);
		my $raw = scalar @{ $data->{entries} || [] };
		$class->_done($cb, $items, $raw >= PAGE ? { start => $to + 1 } : undef);
	}, $ttl);
}

# -- API listings ------------------------------------------------------------------

sub _apiList {
	my ($class, $endpoint, $params, $page, $cb, $ttl, $fallback) = @_;

	Plugins::YouTubeDirect::API->call($endpoint, { %$params, maxResults => PAGE, ($page && $page->{token} ? (pageToken => $page->{token}) : ()) }, sub {
		my ($data, $error) = @_;
		return $fallback->() if !$data && $fallback;
		return $cb->(undef, 'PLUGIN_YOUTUBEDIRECT_ERROR') unless $data;

		my $items = [ grep { $_ && $_->{id} } map { Plugins::YouTubeDirect::API->normalize($_) } @{ $data->{items} || [] } ];
		my $next = $data->{nextPageToken} ? { token => $data->{nextPageToken} } : undef;

		Plugins::YouTubeDirect::API->addDurations($items, sub { $class->_done($cb, shift, $next) });
	}, $ttl);
}

# A page token only means something to the source that made it
sub _useApi {
	my $page = shift;
	return 0 if $page && $page->{start};
	return 1 if $page && $page->{token};
	return _api();
}

# -- what menus call -------------------------------------------------------------------

my %SEARCH_FILTER = (channel => 'EgIQAg%253D%253D', playlist => 'EgIQAw%253D%253D');

sub search {
	my ($class, $type, $query, $page, $cb) = @_;

	my $viaYtdlp = sub {
		return $class->_ytdlp('ytsearch{TO}:' . $query, $page, $cb, 900) if $type eq 'video';
		$class->_ytdlp('https://www.youtube.com/results?search_query=' . uri_escape_utf8($query) . "&sp=$SEARCH_FILTER{$type}", $page, $cb, 900);
	};

	return $viaYtdlp->() unless _useApi($page);
	$class->_apiList('search', { part => 'snippet', type => $type, q => $query }, $page, $cb, 900, $page ? undef : $viaYtdlp);
}

sub channelVideos {
	my ($class, $channel, $page, $cb) = @_;
	my $viaYtdlp = sub { $class->_ytdlp("https://www.youtube.com/channel/$channel/videos", $page, $cb, 600) };
	return $viaYtdlp->() unless _useApi($page) && uploadsPlaylist($channel);
	$class->_apiList('playlistItems', { part => 'snippet,contentDetails', playlistId => uploadsPlaylist($channel) }, $page, $cb, 600, $page ? undef : $viaYtdlp);
}

sub channelPlaylists {
	my ($class, $channel, $page, $cb) = @_;
	my $viaYtdlp = sub { $class->_ytdlp("https://www.youtube.com/channel/$channel/playlists", $page, $cb, 3600) };
	return $viaYtdlp->() unless _useApi($page);
	$class->_apiList('playlists', { part => 'snippet,contentDetails', channelId => $channel }, $page, $cb, 3600, $page ? undef : $viaYtdlp);
}

sub playlist {
	my ($class, $id, $page, $cb) = @_;
	my $viaYtdlp = sub { $class->_ytdlp("https://www.youtube.com/playlist?list=$id", $page, $cb, 600) };
	return $viaYtdlp->() unless _useApi($page);
	$class->_apiList('playlistItems', { part => 'snippet,contentDetails', playlistId => $id }, $page, $cb, 600, $page ? undef : $viaYtdlp);
}

# A channel's name and picture, from a channel id, @handle or /c/ url:
# cb->({ id, title, thumb }) or cb->(undef, token)
sub channel {
	my ($class, $ref, $cb) = @_;

	my $key = "ytd:channel:$ref";
	if (my $cached = $cache->get($key)) {
		return $cb->($cached);
	}

	my $finish = sub {
		my $ch = shift;
		return $cb->(undef, 'PLUGIN_YOUTUBEDIRECT_NOT_FOUND') unless $ch && isChannelId($ch->{id});
		$cache->set($key, $ch, 86400);
		$cb->($ch);
	};

	# the channel's main page, not its Videos tab: "- Topic" channels have no tabs
	my $viaYtdlp = sub {
		my $url = isChannelId($ref) ? "https://www.youtube.com/channel/$ref"
		        : $ref =~ m{^https?://} ? $ref
		        : 'https://www.youtube.com/@' . uri_escape_utf8($ref);
		Plugins::YouTubeDirect::YtDlp->list($url, 1, 1, sub {
			my $data = shift || return $finish->();
			my ($thumb) = map { $_->{url} } sort { ($b->{width} || 0) <=> ($a->{width} || 0) } grep { $_->{url} && ($_->{id} || '') =~ /avatar/ } @{ $data->{thumbnails} || [] };
			$finish->({ id => $data->{channel_id}, title => $data->{channel} || $data->{uploader}, thumb => $thumb });
		});
	};

	return $viaYtdlp->() unless _api() && $ref !~ m{^https?://};

	my %by = isChannelId($ref) ? (id => $ref) : (forHandle => '@' . $ref);
	Plugins::YouTubeDirect::API->call('channels', { part => 'snippet', %by }, sub {
		my $data = shift;
		my $item = $data && $data->{items} && $data->{items}[0];
		return $viaYtdlp->() unless $item;
		$finish->(Plugins::YouTubeDirect::API->normalize($item));
	}, 86400);
}

# A channel's newest uploads for the "New from channels you follow" feed.
# The channel RSS feed is free and needs no key; fall back if it fails.
sub latest {
	my ($class, $channel, $cb) = @_;

	my $key = "ytd:latest:$channel";
	if (my $cached = $cache->get($key)) {
		return $cb->($class->remember($cached));
	}

	my $url = "https://www.youtube.com/feeds/videos.xml?channel_id=$channel";
	my $request = HTTP::Request->new(GET => $url);
	$request->protocol('HTTP/1.1');
	$request->header('User-Agent' => 'Lyrion Music Server (YouTubeDirect)');

	my $fallback = sub {
		$class->channelVideos($channel, undef, sub {
			my $res = shift;
			my $items = $res ? [ grep { $_ } @{ $res->{items} }[0 .. 14] ] : [];
			$cache->set($key, $items, 900) if $res;
			$cb->($items);
		});
	};

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $items = parseRss(shift->content);
			return $fallback->() unless @$items;
			$cache->set($key, $items, 900);
			$cb->($class->remember($items));
		},
		sub {
			main::INFOLOG && $log->info("RSS failed for $channel ($_[1]), falling back");
			$fallback->();
		},
		{ timeout => 15, request => $request },
	)->get($url);
}

1;
