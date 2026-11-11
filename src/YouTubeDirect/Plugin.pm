package Plugins::YouTubeDirect::Plugin;

use strict;
use utf8;
use base qw(Slim::Plugin::OPMLBased);

use HTTP::Request;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::YouTubeDirect::ProtocolHandler;
use Plugins::YouTubeDirect::SponsorBlock;
use Plugins::YouTubeDirect::Source;
use Plugins::YouTubeDirect::YtDlp;
use Plugins::YouTubeDirect::Util qw(videoUrl parseLink thumbnail formatDuration isChannelId);

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.youtubedirect',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_YOUTUBEDIRECT',
});

my $prefs = preferences('plugin.youtubedirect');
my $cache = Slim::Utils::Cache->new;

sub initPlugin {
	my $class = shift;

	$prefs->init({
		apiKey     => '',
		categories => Plugins::YouTubeDirect::SponsorBlock::DEFAULTS,
		ytdlpPath  => '',
		autoUpdate => 1,
		lastUpdate => 0,
		follows    => {},
	});

	Slim::Player::ProtocolHandlers->registerHandler(
		ytdirect => 'Plugins::YouTubeDirect::ProtocolHandler'
	);

	Plugins::YouTubeDirect::YtDlp->init;

	if (main::WEBUI) {
		require Plugins::YouTubeDirect::Settings;
		Plugins::YouTubeDirect::Settings->new;
	}

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'youtubedirect',
		menu   => 'apps',
		is_app => 1,
		weight => 10,
	);
}

sub shutdownPlugin {
	Plugins::YouTubeDirect::YtDlp->shutdown;
}

sub getDisplayName { 'PLUGIN_YOUTUBEDIRECT_MENU' }

sub icon { __PACKAGE__->_pluginDataFor('icon') }

# Menu icons: Material Skin sees "MTL_icon_<name>" and draws its own
# (themed) icon of that name; other skins show the PNG (scripts/icon.py).
sub _icon { 'plugins/YouTubeDirect/html/images/MTL_icon_' . $_[0] . '.png' }

sub handleFeed {
	my ($client, $cb) = @_;

	$cb->({ items => [
		{
			name  => cstring($client, 'PLUGIN_YOUTUBEDIRECT_SEARCH'),
			type  => 'link',
			url   => \&searchMenu,
			image => _icon('search'),
		},
		{
			name  => cstring($client, 'PLUGIN_YOUTUBEDIRECT_FOLLOWED_MENU'),
			type  => 'link',
			url   => \&followedMenu,
			image => _icon('star'),
		},
	] });
}

# Material shows search fields as bare text boxes without icons, so they
# live in this folder rather than at the top level
sub searchMenu {
	my ($client, $cb) = @_;

	$cb->({ items => [
		(map {
			{
				name  => cstring($client, 'PLUGIN_YOUTUBEDIRECT_SEARCH_' . uc($_) . 'S'),
				type  => 'search',
				url   => \&search,
				passthrough => [{ type => $_ }],
				image => _icon('search'),
			}
		} qw(video channel playlist)),
		{
			name  => cstring($client, 'PLUGIN_YOUTUBEDIRECT_OPEN_URL'),
			type  => 'search',
			url   => \&openUrl,
			image => _icon('link'),
		},
	] });
}

sub _error {
	my ($client, $cb, $token) = @_;
	$cb->({ items => [{ name => cstring($client, $token || 'PLUGIN_YOUTUBEDIRECT_ERROR'), type => 'text' }] });
}

sub _empty {
	my ($client, $cb) = @_;
	$cb->({ items => [{ name => cstring($client, 'PLUGIN_YOUTUBEDIRECT_EMPTY'), type => 'text' }] });
}

# -- items -------------------------------------------------------------------

sub _videoItem {
	my ($client, $v) = @_;

	my $title = $v->{title} || $v->{id};
	my $full = $v->{channel} ? "$title - $v->{channel}" : $title;

	if ($v->{live}) {
		return {
			name  => $full,
			line1 => $title,
			line2 => cstring($client, 'PLUGIN_YOUTUBEDIRECT_LIVE_UNSUPPORTED'),
			type  => 'text',
			image => thumbnail($v->{id}),
		};
	}

	# LyrionJS saves favourites under `name`, so it carries the full title;
	# line1/line2 are what list views show.
	return {
		name  => $full,
		line1 => $title,
		line2 => join(' · ', grep { $_ } $v->{channel}, formatDuration($v->{duration}), substr($v->{published} || '', 0, 10)),
		favorites_title => $full,
		type  => 'audio',
		url   => videoUrl($v->{id}),
		play  => videoUrl($v->{id}),
		image => thumbnail($v->{id}),
		duration => $v->{duration},
		on_select => 'play',
	};
}

sub _channelItem {
	my ($client, $c) = @_;
	return {
		name  => $c->{title} || $c->{id},
		type  => 'link',
		url   => \&channelMenu,
		passthrough => [{ id => $c->{id}, title => $c->{title}, thumb => $c->{thumb} }],
		image => $c->{thumb} || icon(),
	};
}

sub _playlistItem {
	my ($client, $p) = @_;
	return {
		name  => $p->{title} || $p->{id},
		line2 => join(' · ', grep { $_ } $p->{channel}, defined $p->{count} ? sprintf(cstring($client, 'PLUGIN_YOUTUBEDIRECT_VIDEOS_COUNT'), $p->{count}) : undef),
		type  => 'link',
		url   => \&playlistMenu,
		passthrough => [{ id => $p->{id}, title => $p->{title} }],
		image => $p->{thumb} || _icon('playlist_play'),
	};
}

sub _item {
	my ($client, $x) = @_;
	return _videoItem($client, $x)    if $x->{type} eq 'video';
	return _channelItem($client, $x)  if $x->{type} eq 'channel';
	return _playlistItem($client, $x) if $x->{type} eq 'playlist';
	return;
}

# A Source result -> menu, with "More..." calling $again for the next page
sub _listResult {
	my ($client, $cb, $pass, $again) = @_;
	return sub {
		my ($res, $error) = @_;
		return _error($client, $cb, $error) unless $res;

		my @items = grep { $_ } map { _item($client, $_) } @{ $res->{items} || [] };

		push @items, {
			name  => cstring($client, 'PLUGIN_YOUTUBEDIRECT_MORE'),
			type  => 'link',
			image => _icon('more_horiz'),
			url   => $again,
			passthrough => [{ %$pass, page => $res->{next} }],
		} if $res->{next} && @items;

		return _empty($client, $cb) unless @items;
		$cb->({ items => \@items });
	};
}

# -- search ------------------------------------------------------------------

sub search {
	my ($client, $cb, $args, $pass) = @_;

	my $query = $pass->{query} // $args->{search};
	$query =~ s/^\s+|\s+$//g if defined $query;
	return _empty($client, $cb) unless defined $query && length $query;

	# a pasted link does what you'd expect
	return openUrl($client, $cb, { search => $query }) if !$pass->{page} && parseLink($query) && $query =~ m{youtu|^@};

	Plugins::YouTubeDirect::Source->search($pass->{type}, $query, $pass->{page},
		_listResult($client, $cb, { %$pass, query => $query }, \&search));
}

# -- channels ----------------------------------------------------------------

sub _follows { $prefs->get('follows') || {} }

sub channelMenu {
	my ($client, $cb, $args, $pass) = @_;

	my $id = $pass->{id};
	my @items = (
		{
			name  => cstring($client, 'PLUGIN_YOUTUBEDIRECT_VIDEOS'),
			type  => 'link',
			image => _icon('queue_music'),
			url   => \&channelVideos,
			passthrough => [{ id => $id }],
		},
		{
			name  => cstring($client, 'PLUGIN_YOUTUBEDIRECT_PLAYLISTS'),
			type  => 'link',
			image => _icon('playlist_play'),
			url   => \&channelPlaylists,
			passthrough => [{ id => $id }],
		},
	);

	# One Follow/Unfollow toggle, last, so Videos and Playlists never move.
	# It has no type and no icon on purpose: Material then treats it as a
	# clickable text row, runs the action in place, shows setFollow's reply
	# as a message and reloads this page (nextWindow "refresh"), so there's
	# never a stale toggle to tap. (A link entry would open a new page, and
	# Material only honours "refresh" after a link when the result is empty,
	# which LMS never sends in menu mode: it adds an "Empty" item.)
	my $following = _follows()->{$id};

	push @items, {
		name  => cstring($client, $following ? 'PLUGIN_YOUTUBEDIRECT_UNFOLLOW' : 'PLUGIN_YOUTUBEDIRECT_FOLLOW'),
		url   => \&setFollow,
		passthrough => [{ id => $id, title => $pass->{title}, thumb => $pass->{thumb}, follow => $following ? 0 : 1 }],
		nextWindow => 'refresh',
	};

	$cb->({ items => \@items });
}

sub channelVideos {
	my ($client, $cb, $args, $pass) = @_;
	Plugins::YouTubeDirect::Source->channelVideos($pass->{id}, $pass->{page}, _listResult($client, $cb, $pass, \&channelVideos));
}

sub channelPlaylists {
	my ($client, $cb, $args, $pass) = @_;
	Plugins::YouTubeDirect::Source->channelPlaylists($pass->{id}, $pass->{page}, _listResult($client, $cb, $pass, \&channelPlaylists));
}

sub playlistMenu {
	my ($client, $cb, $args, $pass) = @_;
	Plugins::YouTubeDirect::Source->playlist($pass->{id}, $pass->{page}, _listResult($client, $cb, $pass, \&playlistMenu));
}

# -- follows (kept in Lyrion, never sent anywhere) ------------------------------

sub setFollow {
	my ($client, $cb, $args, $pass) = @_;

	my %follows = %{ _follows() };
	my $id = $pass->{id};
	my $name = $pass->{title} || ($follows{$id} && $follows{$id}{name}) || $id;

	if ($pass->{follow}) {
		$follows{$id} ||= { name => $name, image => $pass->{thumb}, added => time() };
	}
	else {
		delete $follows{$id};
	}

	$prefs->set(follows => \%follows);
	main::INFOLOG && $log->info(($pass->{follow} ? 'follow' : 'unfollow') . ": $id ($name)");

	# one line of text: Material shows it as a message, then reloads the
	# channel page in place (see channelMenu)
	my $token = $pass->{follow} ? 'PLUGIN_YOUTUBEDIRECT_FOLLOWED' : 'PLUGIN_YOUTUBEDIRECT_UNFOLLOWED';
	$cb->({ items => [{ name => sprintf(cstring($client, $token), $name), type => 'text' }] });
}

sub followedMenu {
	my ($client, $cb) = @_;

	my $follows = _follows();
	my @ids = sort { lc($follows->{$a}{name} || $a) cmp lc($follows->{$b}{name} || $b) } keys %$follows;

	return $cb->({ items => [{ name => cstring($client, 'PLUGIN_YOUTUBEDIRECT_NO_FOLLOWS'), type => 'text' }] }) unless @ids;

	$cb->({ items => [
		{
			name  => cstring($client, 'PLUGIN_YOUTUBEDIRECT_NEW_FROM_FOLLOWED'),
			type  => 'link',
			url   => \&followedFeed,
			image => _icon('new_releases'),
		},
		map { _channelItem($client, { id => $_, title => $follows->{$_}{name}, thumb => $follows->{$_}{image} }) } @ids
	] });
}

use constant FEED_MAX => 100;

# Newest uploads from every followed channel, newest first
sub followedFeed {
	my ($client, $cb) = @_;

	my @ids = keys %{ _follows() };
	return _empty($client, $cb) unless @ids;

	my $pending = @ids;
	my @videos;

	for my $id (@ids) {
		Plugins::YouTubeDirect::Source->latest($id, sub {
			push @videos, @{ shift || [] };
			return if --$pending;

			my @items = map  { _videoItem($client, $_) }
			            sort { ($b->{published} || '') cmp ($a->{published} || '') } @videos;
			splice @items, FEED_MAX if @items > FEED_MAX;

			return _empty($client, $cb) unless @items;
			$cb->({ items => \@items });
		});
	}
}

# -- links -------------------------------------------------------------------

# Title/channel for one video without a key or yt-dlp: YouTube's oEmbed
sub _oembed {
	my ($id, $cb) = @_;

	if (my $known = Plugins::YouTubeDirect::Source->video($id)) {
		return $cb->($known) if $known->{title};
	}

	my $url = 'https://www.youtube.com/oembed?format=json&url=' . uri_escape_utf8("https://www.youtube.com/watch?v=$id");
	my $request = HTTP::Request->new(GET => $url);
	$request->protocol('HTTP/1.1');

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $data = eval { from_json(shift->content) } || {};
			my $v = { type => 'video', id => $id, title => $data->{title}, channel => $data->{author_name} };
			Plugins::YouTubeDirect::Source->remember([ $v ]);
			$cb->($v);
		},
		sub { $cb->({ type => 'video', id => $id }) },
		{ timeout => 10, request => $request },
	)->get($url);
}

# Paste a YouTube link: a video plays, a playlist or channel opens
sub openUrl {
	my ($client, $cb, $args) = @_;

	my $link = parseLink($args->{search}) or return _error($client, $cb, 'PLUGIN_YOUTUBEDIRECT_NOT_FOUND');

	if ($link->{type} eq 'video') {
		return _oembed($link->{id}, sub { $cb->({ items => [ _videoItem($client, shift) ] }) });
	}

	if ($link->{type} eq 'playlist') {
		return playlistMenu($client, $cb, $args, { id => $link->{id} });
	}

	my $ref = $link->{id} || $link->{handle} || $link->{url};
	Plugins::YouTubeDirect::Source->channel($ref, sub {
		my ($channel, $error) = @_;
		return _error($client, $cb, $error) unless $channel;
		channelMenu($client, $cb, $args, $channel);
	});
}

1;
