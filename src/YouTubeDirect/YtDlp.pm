package Plugins::YouTubeDirect::YtDlp;

# Finds, installs, updates and runs yt-dlp.
#
# YouTube can't be decoded from plain Perl any more, so yt-dlp does the one
# thing we can't: turn a video id into a short-lived audio url (and, without
# an API key, search and list channels). It runs for a second or two and
# exits; we stream the audio ourselves. A stale yt-dlp is the usual reason
# YouTube playback breaks, so we install our own copy into the cache folder
# (no shell access needed) and update it daily with yt-dlp's own updater.

use strict;
use utf8;

use Config;
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;
use Time::HiRes;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::YouTubeDirect::Util qw(assetFor);

my $log   = logger('plugin.youtubedirect');
my $prefs = preferences('plugin.youtubedirect');
my $cache = Slim::Utils::Cache->new;

use constant RELEASES    => 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/';
use constant MAX_RUNNING => 2;
use constant TIMEOUT     => 60;
use constant UPDATE_EVERY => 86400;

use constant INSTALL_RETRY => 600;   # after a failed install, don't try again for 10 min
use constant TIMED_OUT     => -2;    # exit status we report when we had to kill it

my @queue;
my $running = 0;
my $installing;          # callbacks waiting for an install in progress
my $installFailedAt = 0;
my $version;             # cached `yt-dlp --version`
my $lastError;

sub _setError {
	my $error = shift;
	$log->error($error) unless defined $lastError && $lastError eq $error;
	$lastError = $error;
}

sub init {
	my $class = shift;
	# know the installed version for the settings page
	Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 10, sub { $class->checkVersion(sub {}) });
	# first update check a minute after startup, then every 6 hours
	Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 60, \&_autoUpdate);
}

sub shutdown {
	my $class = shift;
	Slim::Utils::Timers::killTimers($class, \&_autoUpdate);
}

sub dir {
	my $dir = catdir(preferences('server')->get('cachedir'), 'YouTubeDirect');
	mkdir $dir unless -d $dir;
	return $dir;
}

sub asset {
	my $musl = $^O eq 'linux' && (glob('/lib/ld-musl-*'))[0] ? 1 : 0;
	return assetFor($^O, $Config{archname}, $musl);
}

sub managedPath {
	my $asset = asset() || return;
	return catfile(dir(), $asset);
}

# The yt-dlp we'll run: a custom path from settings, else our managed copy
sub binary {
	my $custom = $prefs->get('ytdlpPath');
	return $custom if $custom && -f $custom && (main::ISWINDOWS || -x $custom);
	my $managed = managedPath() || return;
	return $managed if -f $managed && -s $managed > 1_000_000;
	return;
}

sub isManaged {
	my $bin = binary() || return 0;
	my $managed = managedPath();
	return $managed && $bin eq $managed ? 1 : 0;
}

sub lastError { $lastError }
sub version   { $version }

# cb->($path) once yt-dlp is available, or cb->(undef, $error)
sub ensure {
	my ($class, $cb) = @_;

	if (my $bin = binary()) {
		return $cb->($bin);
	}

	if ($prefs->get('ytdlpPath')) {
		_setError("yt-dlp not found (or not executable) at " . $prefs->get('ytdlpPath'));
		return $cb->(undef, 'PLUGIN_YOUTUBEDIRECT_NO_YTDLP');
	}

	# don't start another download (and keep menus waiting) after a failure
	return $cb->(undef, 'PLUGIN_YOUTUBEDIRECT_NO_YTDLP') if time() - $installFailedAt < INSTALL_RETRY;

	$class->install($cb);
}

# Download the latest release for this platform into the cache folder
sub install {
	my ($class, $cb) = @_;

	my $asset = asset();
	if (!$asset) {
		_setError("no yt-dlp build for $^O/$Config{archname}; set a custom path in settings");
		return $cb->(undef, 'PLUGIN_YOUTUBEDIRECT_NO_YTDLP');
	}

	if ($installing) {
		push @$installing, $cb;
		return;
	}
	$installing = [ $cb ];

	my $target = managedPath();
	my $part = "$target.part";
	my $url = RELEASES . $asset;
	unlink $part;

	$log->warn("Installing yt-dlp ($asset) from $url");

	my $finish = sub {
		my $error = shift;
		unlink $part;

		my @waiting = @{ $installing || [] };
		$installing = undef;

		if ($error) {
			$installFailedAt = time();
			_setError("yt-dlp install failed: $error (will retry in " . INSTALL_RETRY / 60 . " min, or press Install in settings)");
			$_->(undef, 'PLUGIN_YOUTUBEDIRECT_NO_YTDLP') for @waiting;
			return;
		}

		$lastError = undef;
		$installFailedAt = 0;
		$prefs->set(lastUpdate => time());
		$log->warn("yt-dlp $version installed at $target");
		$_->($target) for @waiting;
	};

	# LMS's HTTP client can report a cut-off download as a success, so only
	# install a file that actually runs
	my $done = sub {
		my $error = shift;
		return $finish->($error) if $error;
		return $finish->('download incomplete') unless -s $part > 1_000_000;

		chmod 0755, $part;
		_spawn([ $part, '--version' ], 60, sub {
			my ($out, $err, $status) = @_;
			my ($v) = ($out // '') =~ /(\d{4}\.\d\d\.\d\d(?:\.\d+)?)/;
			return $finish->("downloaded file doesn't run (exit $status): " . substr($err // '', 0, 200)) if $status || !$v;
			rename $part, $target or return $finish->("can't move $part into place: $!");
			$version = $v;
			$finish->();
		});
	};

	# LMS's own HTTP client first; some older LMS versions choke on GitHub's
	# long redirect headers, so fall back to curl or wget if it fails
	Slim::Networking::SimpleAsyncHTTP->new(
		sub { $done->() },
		sub {
			my (undef, $error) = @_;
			$log->warn("Download via LMS failed ($error), trying curl/wget");
			unlink $part;
			_systemDownload($url, $part, $done);
		},
		{ saveAs => $part, timeout => 120 },
	)->get($url);
}

sub _systemDownload {
	my ($url, $file, $done) = @_;

	my ($tool) = grep { -x $_ } map { ("/usr/bin/$_", "/bin/$_", "/usr/local/bin/$_") } qw(curl wget);
	return $done->('no curl or wget') unless $tool;

	my @cmd = $tool =~ /curl$/
		? ($tool, '-fsSL', '--max-time', '300', '-o', $file, $url)
		: ($tool, '-q', '-T', '300', '-O', $file, $url);

	_spawn(\@cmd, 330, sub {
		my ($out, $err, $status) = @_;
		$done->($status ? "$tool exited $status: $err" : undef);
	});
}

sub checkVersion {
	my ($class, $cb) = @_;
	my $bin = binary() || return $cb->();
	_spawn([ $bin, '--version' ], 30, sub {
		my ($out) = @_;
		($version) = ($out // '') =~ /(\d{4}\.\d\d\.\d\d(?:\.\d+)?)/;
		$cb->($version);
	});
}

# Self-update via yt-dlp -U (managed copy only: a custom yt-dlp is the
# server admin's to update). cb->($message, $error)
sub update {
	my ($class, $cb) = @_;
	$cb ||= sub {};

	if (!binary()) {
		$installFailedAt = 0;    # pressed the button: try now
		return $class->install(sub { $cb->($_[0] ? 'installed' : undef, $lastError || $_[1]) });
	}
	return $cb->(undef, 'custom yt-dlp: update it yourself') unless isManaged();

	_spawn([ binary(), '-U' ], 300, sub {
		my ($out, $err, $status) = @_;
		$prefs->set(lastUpdate => time());
		my $msg = join(' ', grep { length } map { s/\s+$//r } split /\n/, ($out // '') . ($err // ''));
		$log->warn("yt-dlp -U: $msg");
		$version = undef;
		$class->checkVersion(sub {});
		$status ? $cb->(undef, $msg || "exit $status") : $cb->($msg);
	});
}

sub _autoUpdate {
	my $class = shift;
	Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 6 * 3600, \&_autoUpdate);

	return unless $prefs->get('autoUpdate');
	return unless binary() && isManaged();
	return if time() - ($prefs->get('lastUpdate') || 0) < UPDATE_EVERY;

	main::INFOLOG && $log->info('Daily yt-dlp update check');
	$class->update;
}

# -- running -----------------------------------------------------------------

# Run yt-dlp with @args: cb->($stdout, $stderr, $exitStatus). Urgent jobs
# (resolving what a player is waiting to play) go ahead of queued listings.
sub run {
	my ($class, $args, $cb, $timeout, $urgent) = @_;

	$class->ensure(sub {
		my ($bin, $error) = @_;
		return $cb->(undef, $error, -1) unless $bin;
		my $job = [ [ $bin, '--no-update', '--ignore-config', '--no-warnings', '--socket-timeout', '20', @$args ], $cb, $timeout || TIMEOUT ];
		$urgent ? unshift(@queue, $job) : push(@queue, $job);
		_next();
	});
}

sub _next {
	while ($running < MAX_RUNNING && @queue) {
		my ($cmd, $cb, $timeout) = @{ shift @queue };
		$running++;
		my $start = Time::HiRes::time();
		_spawn($cmd, $timeout, sub {
			$running--;
			main::INFOLOG && $log->info(sprintf('yt-dlp %s finished in %.1fs (exit %s)', $cmd->[-1], Time::HiRes::time() - $start, $_[2]));
			eval { $cb->(@_) };
			$log->error("yt-dlp callback failed: $@") if $@;
			_next();
		});
	}
}

# Start a process without blocking LMS: cb->($stdout, $stderr, $exitStatus)
sub _spawn {
	my ($cmd, $timeout, $cb) = @_;

	main::DEBUGLOG && $log->debug('run: ' . join(' ', @$cmd));

	return _spawnWindows($cmd, $timeout, $cb) if main::ISWINDOWS;

	require AnyEvent::Util;

	my ($out, $err, $pid) = ('', '');
	my $guard = {};
	my $timedOut;
	my $cv = eval {
		AnyEvent::Util::run_cmd(
			$cmd,
			'<'  => '/dev/null',
			'>'  => \$out,
			'2>' => \$err,
			'$$' => \$pid,
		);
	};
	if (!$cv) {
		$log->error("Can't run $cmd->[0]: $@");
		return $cb->(undef, "$@", -1);
	}

	# yt-dlp's standalone builds are a launcher plus the process doing the
	# work: TERM reaches both (the launcher passes it on); KILL only the
	# launcher, which would leave the worker holding our pipes open
	my $kill = sub {
		$log->error("$cmd->[0] timed out after ${timeout}s; stopping it");
		$timedOut = 1;
		return unless $pid;
		kill 'TERM', $pid;
		Slim::Utils::Timers::setTimer($guard, Time::HiRes::time() + 5, sub { kill 'KILL', $pid });
	};
	Slim::Utils::Timers::setTimer($guard, Time::HiRes::time() + $timeout, $kill);

	$cv->cb(sub {
		my $status = eval { shift->recv } // -1;
		Slim::Utils::Timers::killTimers($guard, $kill);
		return $cb->($out, ($err // '') . "\n(timed out after ${timeout}s)", TIMED_OUT) if $timedOut;
		$cb->($out, $err, $status == -1 ? -1 : ($status >> 8 || ($status & 127 ? -1 : 0)));
	});
}

# Windows can't select() on pipes inside LMS: run through cmd.exe into temp
# files and poll for the process to finish
sub _spawnWindows {
	my ($cmd, $timeout, $cb) = @_;

	require Proc::Background;
	my $base = catfile(dir(), 'run-' . int(Time::HiRes::time() * 1000) . "-$$");
	my ($outFile, $errFile) = ("$base.out", "$base.err");
	my $line = join(' ', map { /[\s"&|<>^]/ ? '"' . s/"/\\"/gr . '"' : $_ } @$cmd) . qq{ > "$outFile" 2> "$errFile"};

	my $proc = eval { Proc::Background->new($ENV{COMSPEC} || 'cmd.exe', '/c', $line) };
	return $cb->(undef, "can't start $cmd->[0]: $@", -1) unless $proc;

	my $deadline = Time::HiRes::time() + $timeout;
	my $poll;
	$poll = sub {
		if ($proc->alive) {
			if (Time::HiRes::time() > $deadline) {
				$proc->die;
			}
			else {
				return Slim::Utils::Timers::setTimer($proc, Time::HiRes::time() + 0.25, $poll);
			}
		}
		my $slurp = sub { open my $fh, '<:raw', $_[0] or return ''; local $/; my $s = <$fh>; close $fh; unlink $_[0]; $s };
		$cb->($slurp->($outFile), $slurp->($errFile), $proc->exit_code // -1);
	};
	Slim::Utils::Timers::setTimer($proc, Time::HiRes::time() + 0.25, $poll);
}

# -- what we use it for ---------------------------------------------------------

use constant RESOLVE_FIELDS => '%(.{id,title,channel,uploader,channel_id,duration,thumbnail,chapters,url,format_id,filesize,abr,asr,http_headers,live_status,availability})j';

# yt-dlp's stderr -> a strings.txt token for the person holding the remote
sub _errorToken {
	my $err = shift // '';
	return 'PLUGIN_YOUTUBEDIRECT_ERR_BOT'         if $err =~ /confirm you.re not a bot|Sign in to confirm/i && $err !~ /age/i;
	return 'PLUGIN_YOUTUBEDIRECT_ERR_AGE'         if $err =~ /confirm your age|age.restricted|inappropriate for some users/i;
	return 'PLUGIN_YOUTUBEDIRECT_ERR_PRIVATE'     if $err =~ /Private video|members.only|Join this channel/i;
	return 'PLUGIN_YOUTUBEDIRECT_ERR_LIVE'        if $err =~ /live event will begin|Premieres in|is_upcoming/i;
	return 'PLUGIN_YOUTUBEDIRECT_ERR_UNAVAILABLE' if $err =~ /Video unavailable|has been removed|not available in your country|blocked it/i;
	return 'PLUGIN_YOUTUBEDIRECT_NO_STREAM'       if $err =~ /Requested format is not available/i;
	return 'PLUGIN_YOUTUBEDIRECT_ERROR';
}

# Why a run gave nothing: yt-dlp missing, killed for taking too long, or
# something YouTube said
sub _failureToken {
	my ($out, $err, $status) = @_;
	return 'PLUGIN_YOUTUBEDIRECT_ERROR' if $status == TIMED_OUT;
	return $err if ($err // '') =~ /^PLUGIN_/;                       # from ensure()
	return 'PLUGIN_YOUTUBEDIRECT_NO_YTDLP' if $status == -1 && !length($out // '');
	return _errorToken($err);
}

sub _lastJson {
	my $out = shift // return;
	for my $line (reverse split /\n/, $out) {
		next unless $line =~ /^\s*\{/;
		my $data = eval { from_json($line) };
		return $data if ref $data eq 'HASH';
	}
	return;
}

# Video id -> cb->({ url, userAgent, title, channel, ... }) or cb->(undef, token)
# Not cached: stream urls are tied to this server's IP and expire in hours.
sub resolve {
	my ($class, $id, $cb) = @_;

	$class->run([
		'--no-playlist',
		'-f', '140/139/bestaudio[ext=m4a]',
		'-O', RESOLVE_FIELDS,
		'--', "https://www.youtube.com/watch?v=$id",
	], sub {
		my ($out, $err, $status) = @_;
		my $info = _lastJson($out);

		if (!$info || !$info->{url}) {
			$err //= '';
			$err =~ s/\s+$//;
			$log->error("yt-dlp couldn't resolve $id: " . (length $err ? substr($err, -500) : "exit $status"));
			return $cb->(undef, _failureToken($out, $err, $status));
		}

		return $cb->(undef, 'PLUGIN_YOUTUBEDIRECT_ERR_LIVE') if ($info->{live_status} || '') =~ /^(?:is_live|is_upcoming)$/;

		$info->{userAgent} = $info->{http_headers} && $info->{http_headers}{'User-Agent'};
		$cb->($info);
	}, undef, 1);
}

# Flat listing of a YouTube url (search, channel tab, playlist), items
# $from..$to: cb->(data) or cb->(undef, token). Cached for $ttl seconds.
sub list {
	my ($class, $url, $from, $to, $cb, $ttl) = @_;

	my $key = "ytd:list:$url:$from-$to";
	if ($ttl && (my $cached = $cache->get($key))) {
		return $cb->($cached);
	}

	$class->run([ '--flat-playlist', '-J', '--playlist-items', "$from-$to", '--', $url ], sub {
		my ($out, $err, $status) = @_;
		my $data = _lastJson($out);

		if (!$data) {
			$err //= '';
			# a channel without that tab, or a search with no results: empty, not an error
			return $cb->({ entries => [] }) if $err =~ /does not have a \w+ tab|no results|This playlist is empty/i;
			$log->error("yt-dlp listing failed for $url: " . substr($err, -300));
			return $cb->(undef, _failureToken($out, $err, $status));
		}

		$cache->set($key, $data, $ttl) if $ttl;
		$cb->($data);
	});
}

1;
