package Plugins::YouTubeDirect::ProtocolHandler;

# ytdirect://<videoId>
#
# At play time yt-dlp gives us a short-lived url for the video's AAC audio
# (itag 140): one fragmented MP4 file whose sidx box indexes every ~10 s
# fragment. We fetch the index, then one fragment per range request (YouTube
# refuses ranges much over 512 KB, and wants yt-dlp's User-Agent), turn each
# into ADTS AAC and hand that to LMS. There's no socket: sysread serves a
# buffer that async fetches fill, returning EINTR while one is in flight.
#
# SponsorBlock segments are cut out right here, by dropping the frames that
# fall inside them (whole fragments aren't even fetched). The player's clock
# then runs on a "virtual" timeline without the skipped parts: durations,
# seeks and chapter lookups convert between it and the video's own time.

use strict;
use utf8;
use base qw(IO::Handle);

use HTTP::Request;
use Time::HiRes;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Errno;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::YouTubeDirect::SponsorBlock;
use Plugins::YouTubeDirect::Source;
use Plugins::YouTubeDirect::YtDlp;
use Plugins::YouTubeDirect::Util qw(
	parseVideoUrl thumbnail parseSidx mp4AudioConfig fmp4Samples adtsHeader fragmentAt
	mergeSkips realToVirtual virtualToReal skipAt normalizeChapters trackAt
);

my $log   = logger('plugin.youtubedirect');
my $prefs = preferences('plugin.youtubedirect');

use constant HEAD_BYTES     => 131_072;   # ftyp + moov + sidx; ~14 h of index
use constant MAX_RANGE      => 524_288;   # YouTube 403s larger ranges
use constant PREFETCH_BYTES => 400_000;   # ~25 s at 128k: two or three fragments ahead
use constant MAX_RETRIES    => 4;
use constant REFRESH_AFTER  => 60;        # don't re-resolve more often than this

sub isRemote        { 1 }
sub isAudio         { 1 }
sub canDirectStream { 0 }    # players can't do this themselves; we always proxy
sub getFormatForURL { 'aac' }
sub formatOverride  { 'aac' }
sub canSeek         { 1 }
sub isRepeatingStream { 0 }
sub audioScrobblerSource { 'P' }
sub getIcon         { Plugins::YouTubeDirect::Plugin->icon }

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	return { timeOffset => $newtime };
}

# -- resolving -----------------------------------------------------------------

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $url = $song->currentTrack->url;
	my $id = parseVideoUrl($url) or return $errorCb->('PLUGIN_YOUTUBEDIRECT_NOT_FOUND', $url);

	my ($info, $error, $segments);
	my $pending = 2;

	my $ready = sub {
		return if --$pending;
		return $errorCb->($error || 'PLUGIN_YOUTUBEDIRECT_ERROR', $url) unless $info;

		_loadIndex($info, sub {
			my ($index, $config, $indexError) = @_;
			return $errorCb->($indexError, $url) unless $index;

			my $skips = mergeSkips($segments, $index->{duration});
			my $virtual = realToVirtual($skips, $index->{duration});
			my $bitrate = ($info->{abr} ? int($info->{abr} * 1000) : undef) || $config->{bitrate} || 128_000;
			my $skipped = $index->{duration} - $virtual;

			main::INFOLOG && $log->info(sprintf('%s: %d fragments, %.0fs, %d bps, %d skip(s) totalling %.0fs',
				$id, scalar @{ $index->{fragments} }, $index->{duration}, $bitrate, scalar @$skips, $skipped));

			my $video = Plugins::YouTubeDirect::Source->store($id, {
				title      => $info->{title},
				channel    => $info->{channel} || $info->{uploader},
				channel_id => $info->{channel_id},
				duration   => $info->{duration},
				thumb      => $info->{thumbnail},
				chapters   => normalizeChapters($info->{chapters}),
			});

			$song->pluginData(ytdirect => {
				id        => $id,
				media     => $info->{url},
				userAgent => $info->{userAgent},
				resolved  => time(),
				fragments => $index->{fragments},
				config    => $config,
				bitrate   => $bitrate,
				skips     => $skips,
				skipped   => $skipped,
				real      => $index->{duration},
				chapters  => $video->{chapters},
			});
			$song->duration($virtual);

			Slim::Music::Info::setDuration($url, $virtual);
			Slim::Music::Info::setBitrate($url, $bitrate);
			Slim::Music::Info::setContentType($url, 'aac');
			$song->currentTrack->title($info->{title}) if $info->{title} && $song->currentTrack->can('title');

			$song->master->currentPlaylistUpdateTime(Time::HiRes::time());
			Slim::Control::Request::notifyFromArray($song->master, ['newmetadata']);

			$successCb->();
		});
	};

	Plugins::YouTubeDirect::YtDlp->resolve($id, sub { ($info, $error) = @_; $ready->() });
	Plugins::YouTubeDirect::SponsorBlock->get($id, sub { $segments = shift; $ready->() });
}

sub _request {
	my ($url, $userAgent, $from, $to) = @_;
	my $request = HTTP::Request->new(GET => $url);
	$request->protocol('HTTP/1.1');
	$request->header('User-Agent' => $userAgent || 'Mozilla/5.0');
	$request->header(Range => "bytes=$from-$to");
	return $request;
}

# GET $size bytes from $offset, in pieces YouTube accepts:
# cb->($bytes) or cb->(undef, $error, $httpCode)
sub _getRange {
	my ($url, $userAgent, $offset, $size, $cb) = @_;

	my $buf = '';
	my $piece;
	my $finish = sub { undef $piece; $cb->(@_) };    # break the closure's self-reference
	$piece = sub {
		use bytes;
		my $from = $offset + length $buf;
		my $remaining = $size - length $buf;
		return $finish->($buf) if $remaining <= 0;
		my $to = $from + ($remaining > MAX_RANGE ? MAX_RANGE : $remaining) - 1;

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $content = shift->content;
				return $finish->(undef, 'empty response', 0) unless length $content;
				$buf .= $content;
				$piece->();
			},
			sub {
				my ($http, $error) = @_;
				my ($code) = ($error // '') =~ /(\d{3})/;
				$finish->(undef, $error, $code || 0);
			},
			{ timeout => 30, request => _request($url, $userAgent, $from, $to) },
		)->get($url);
	};
	$piece->();
}

# The file's head -> cb->($index, $config) or cb->(undef, undef, $token)
sub _loadIndex {
	my ($info, $cb) = @_;

	my $parse = sub {
		my $head = shift;
		my $index = parseSidx($head);
		return (undef, undef, $index) if $index && $index->{need};
		my $config = mp4AudioConfig($head);
		return ($index, $config) if $index && $config;
		return;
	};

	_getRange($info->{url}, $info->{userAgent}, 0, HEAD_BYTES, sub {
		my ($head, $error) = @_;
		if (!defined $head) {
			$log->error("Couldn't read the stream header: $error");
			return $cb->(undef, undef, 'PLUGIN_YOUTUBEDIRECT_NO_STREAM');
		}

		my ($index, $config, $more) = $parse->($head);
		return $cb->($index, $config) if $index;

		# a very long video: its index runs past what we fetched
		if ($more && $more->{need} <= 4 * MAX_RANGE) {
			return _getRange($info->{url}, $info->{userAgent}, 0, $more->{need}, sub {
				my ($bigger) = @_;
				my ($i, $c) = $parse->($bigger // '');
				return $cb->($i, $c) if $i;
				$cb->(undef, undef, 'PLUGIN_YOUTUBEDIRECT_NO_STREAM');
			});
		}

		$log->error("No fragment index in $info->{id}'s audio (format $info->{format_id})");
		$cb->(undef, undef, 'PLUGIN_YOUTUBEDIRECT_NO_STREAM');
	});
}

# -- streaming -------------------------------------------------------------------

sub new {
	my ($class, $args) = @_;

	my $song = $args->{song};
	my $data = $song->pluginData('ytdirect');
	return unless $data && $data->{fragments} && @{ $data->{fragments} };

	my $from = ($song->seekdata || {})->{timeOffset} || 0;   # on the virtual timeline
	my $real = virtualToReal($data->{skips}, $from);
	my $index = fragmentAt($data->{fragments}, $real);

	main::INFOLOG && $log->info(sprintf('Streaming %s from %.1fs (video time %.1fs, fragment %d)', $args->{url}, $from, $real, $index));

	# the elapsed-time clock starts here (frames before $real are dropped)
	$song->startOffset($from);

	my $self = $class->SUPER::new;
	${*$self}{ytd} = {
		url        => $args->{url},
		data       => $data,
		next       => $index,
		dropBefore => $real,
		buf        => '',
		retries    => 0,
	};

	$self->_fetch;
	return $self;
}

sub contentType { 'aac' }

sub bitrate {
	my $self = shift;
	return ref $self ? ${*$self}{ytd}{data}{bitrate} : undef;
}

sub _fetch {
	my $self = shift;
	my $v = ${*$self}{ytd} || return;
	my $data = $v->{data};
	my $fragments = $data->{fragments};

	return if $v->{pending} || $v->{closed} || $v->{eof};
	return if length($v->{buf}) >= PREFETCH_BYTES;

	# don't even fetch fragments that lie entirely inside a skip
	while ($v->{next} < @$fragments) {
		my $f = $fragments->[ $v->{next} ];
		my $skip = skipAt($data->{skips}, $f->{start});
		last unless $skip && $skip->[1] >= $f->{start} + $f->{duration};
		$v->{next}++;
	}

	if ($v->{next} >= @$fragments) {
		$v->{eof} = 1;
		return;
	}

	my $f = $fragments->[ $v->{next} ];
	$v->{pending} = 1;

	main::DEBUGLOG && $log->debug("Fetching fragment $v->{next} ($f->{size} bytes at $f->{offset})");

	_getRange($data->{media}, $data->{userAgent}, $f->{offset}, $f->{size}, sub {
		my ($bytes, $error, $code) = @_;
		return if $v->{closed};
		$v->{pending} = 0;

		return $self->_expired($error) if !defined $bytes && $code == 403;
		return $self->_failed($error) unless defined $bytes;

		my @samples = fmp4Samples($bytes);
		return $self->_failed("no audio in fragment $v->{next}") unless @samples;

		my $config = $data->{config};
		my $frame = 1024 / ($config->{samplerate} || 44100);
		my $out = '';
		my $dropped = 0;

		for my $i (0 .. $#samples) {
			my $mid = $f->{start} + ($i + 0.5) * $frame;
			if ($mid < $v->{dropBefore} || skipAt($data->{skips}, $mid)) {
				$dropped++;
				next;
			}
			$out .= adtsHeader($config, length $samples[$i]) . $samples[$i];
		}

		main::INFOLOG && $dropped && $log->info(sprintf('Fragment %d: dropped %.1fs (seek/skip)', $v->{next}, $dropped * $frame));

		$v->{dropBefore} = 0;
		$v->{buf} .= $out;
		$v->{next}++;
		$v->{retries} = 0;

		$self->_fetch;
	});
}

# Stream urls expire after some hours (a long pause): get a fresh one
sub _expired {
	my ($self, $error) = @_;
	my $v = ${*$self}{ytd};
	my $data = $v->{data};

	return $self->_failed($error) if time() - ($data->{resolved} || 0) < REFRESH_AFTER;

	$log->warn("Stream url for $data->{id} refused ($error); fetching a fresh one");
	$v->{pending} = 1;

	Plugins::YouTubeDirect::YtDlp->resolve($data->{id}, sub {
		my ($info, $err) = @_;
		return if $v->{closed};
		$v->{pending} = 0;
		$data->{resolved} = time();
		return $self->_failed($err || $error) unless $info;
		$data->{media} = $info->{url};
		$data->{userAgent} = $info->{userAgent};
		$self->_fetch;
	});
}

sub _failed {
	my ($self, $error) = @_;
	my $v = ${*$self}{ytd};

	if (++$v->{retries} > MAX_RETRIES) {
		$log->error("Giving up on $v->{url} at fragment $v->{next}: $error");
		$v->{eof} = 1;
		return;
	}

	$log->warn("Fragment $v->{next} of $v->{url} failed ($error), retry $v->{retries}");
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + $v->{retries}, \&_fetch);
}

sub sysread {
	use bytes;
	my $self = $_[0];
	my $v = ${*$self}{ytd};

	if (length $v->{buf}) {
		$_[1] = substr($v->{buf}, 0, $_[2] || 32768, '');
		$self->_fetch;
		return length $_[1];
	}

	if ($v->{eof} && !$v->{pending}) {
		$_[1] = '';
		return 0;
	}

	$self->_fetch;
	$! = EINTR;
	return undef;
}

sub close {
	my $self = shift;
	my $v = ${*$self}{ytd} || return 1;
	$v->{closed} = 1;
	$v->{buf} = '';
	Slim::Utils::Timers::killTimers($self, \&_fetch);
	return 1;
}

# -- now playing -------------------------------------------------------------------

sub getMetadataFor {
	my ($class, $client, $url) = @_;

	my $icon = Plugins::YouTubeDirect::Plugin->icon;
	my $id = parseVideoUrl($url) or return {};
	my $video = Plugins::YouTubeDirect::Source->video($id) || {};

	my $song = $client && $client->playingSong;
	my $isCurrent = $song && $song->currentTrack && $song->currentTrack->url eq $url;
	my $data = $isCurrent && $song->pluginData('ytdirect');

	my $type = 'AAC (YouTube)';
	if ($data && $data->{skipped} && $data->{skipped} >= 1) {
		$type .= ' · ' . sprintf(cstring($client, 'PLUGIN_YOUTUBEDIRECT_SKIPPED_N'), scalar @{ $data->{skips} }, Plugins::YouTubeDirect::Util::formatDuration($data->{skipped}));
	}

	my $meta = {
		title    => $video->{title} || $id,
		artist   => $video->{channel},
		album    => 'YouTube',
		cover    => $video->{thumb} || thumbnail($id),
		icon     => $icon,
		duration => $data ? realToVirtual($data->{skips}, $data->{real}) : $video->{duration},
		type     => $type,
	};
	$meta->{bitrate} = int($data->{bitrate} / 1000) . 'kbps' if $data && $data->{bitrate};

	my $chapters = $data && $data->{chapters};
	return $meta unless $chapters && @$chapters && !$client->isStopped;

	# chapters (often a DJ mix's tracklist) have start times: show the one playing now
	my $elapsed = $client->controller->playingSongElapsed || 0;
	my $real = virtualToReal($data->{skips}, $elapsed);
	my $track = trackAt($chapters, $real);

	if ($track) {
		$meta->{title}  = $track->{title};
		$meta->{artist} = $track->{artist} if $track->{artist};
		$meta->{album}  = join(' · ', grep { $_ } $video->{title}, $video->{channel});
	}

	# nudge clients to refresh when the chapter changes
	my $key = $track ? $track->{start} : -1;
	if (!defined $data->{lastTrack} || $data->{lastTrack} != $key) {
		$data->{lastTrack} = $key;
		Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
	}

	_scheduleTrackChange($client, $url, $chapters, $data->{skips}, $elapsed, $real);

	return $meta;
}

# Clients that only listen for pushed updates (Material) never ask for
# metadata again by themselves, so wake them when the next chapter starts.
# Capped so pauses and seeks get re-checked.
use constant MAX_TRACK_WAIT => 60;

sub _scheduleTrackChange {
	my ($client, $url, $chapters, $skips, $elapsed, $real) = @_;

	Slim::Utils::Timers::killTimers($client, \&_trackChanged);

	my ($next) = grep { $_->{start} > $real } @$chapters;
	return unless $next;

	my $wait = realToVirtual($skips, $next->{start}) - $elapsed;
	$wait = MAX_TRACK_WAIT if $wait > MAX_TRACK_WAIT;
	$wait = 1 if $wait < 1;

	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $wait + 0.5, \&_trackChanged, $url);
}

sub _trackChanged {
	my ($client, $url) = @_;

	my $song = $client->playingSong;
	return unless $song && $song->currentTrack && $song->currentTrack->url eq $url;

	# getMetadataFor (run by the status query this triggers) reschedules
	if ($client->isPlaying) {
		__PACKAGE__->getMetadataFor($client, $url);
	}
	else {
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + MAX_TRACK_WAIT, \&_trackChanged, $url);
	}
}

1;
