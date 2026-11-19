use strict;
use warnings;
use Test::More;
use lib '.';
use Koha::Plugin::Pro::Koha::PigeonPost::Digest;
use Koha::Plugin::Pro::Koha::PigeonPost::Smtp;

my $D = 'Koha::Plugin::Pro::Koha::PigeonPost::Digest';

# should_send: 2026-11-16 is a Monday (weekday 1)
ok($D->can('should_send')->(today => '2026-11-16', weekday => 1), 'right weekday, never sent');
ok(!$D->can('should_send')->(today => '2026-11-17', weekday => 1), 'wrong weekday');
ok(!$D->can('should_send')->(today => '2026-11-16', weekday => 1, last_sent => '2026-11-16'), 'not twice the same day');
ok($D->can('should_send')->(today => '2026-11-16', weekday => 1, last_sent => '2026-11-09'), 'a week later');
ok(!$D->can('should_send')->(today => '2026-11-16', weekday => 1, last_sent => '2026-11-12'), 'too soon after a manual-day change');
ok(!$D->can('should_send')->(today => '2026-11-16', weekday => 'x'), 'bad weekday');

is_deeply($D->can('parse_recipients')->("a\@lib.org, b\@lib.org;A\@LIB.org bad c\@x"), [ 'a@lib.org', 'b@lib.org' ], 'recipients parsed, deduped, invalid dropped');

my $d = {
    from => '2026-11-09', to => '2026-11-15',
    week => { sent => 12345, failed => 67, failure_rate => 0.5 }, prev => { sent => 10000, failed => 100 },
    reasons => [ { code => '<script>alert(1)</script>', n => 40 }, { code => 'SENDMAIL', n => 27 } ],
    letters => [ { letter_code => 'CHECKOUT', sent => 5000, failed => 3 } ],
    cleared => 4, candidates => 2, queue => { pending => 12, oldest_age_minutes => 180 },
    smtp => [ { name => 'Main relay', light => 'green', ms => 41 }, { name => 'Backup', light => 'red', ms => 5000 } ],
    dashboard_url => 'https://staff.example.org/cgi-bin/koha/plugins/run.pl?class=X&method=tool', library => 'Golden Gate Library',
};
my $html = $D->can('build_html')->($d);
like($html, qr/12,345/, 'thousands separators');
like($html, qr/\+23%/, 'week-over-week change');
like($html, qr/-33%/, 'failed change');
unlike($html, qr/<script>/, 'failure codes are escaped');
like($html, qr/&lt;script&gt;/, '...as entities');
like($html, qr/Queue may be stuck/, 'stuck queue warning when oldest > 60 min');
like($html, qr/DOWN/, 'smtp down shown');
like($html, qr/#002f65/, 'koha.pro navy used');
like($html, qr/Golden Gate Library/, 'library name');
like($html, qr/method=tool/, 'dashboard link');
like($D->can('subject')->($d), qr/12,345 sent, 67 failed/, 'subject');

my $quiet = $D->can('build_html')->({ from => 'a', to => 'b', week => {}, prev => {}, queue => {} });
like($quiet, qr/Nothing to report/, 'empty sections render gracefully');
unlike($quiet, qr/Queue may be stuck/, 'no warning without backlog');

my $cl = \&Koha::Plugin::Pro::Koha::PigeonPost::Smtp::classify;
is($cl->(connected => 0), 'red', 'no connection = red');
is($cl->(connected => 1, ms => 100), 'green', 'fast = green');
is($cl->(connected => 1, ms => 2500), 'amber', 'slow = amber');
is($cl->(connected => 1, ms => 100, tls_failed => 1), 'amber', 'TLS failure = amber');

# live probe against a closed local port must come back red, quickly
my $p = Koha::Plugin::Pro::Koha::PigeonPost::Smtp::probe({ name => 'closed', host => '127.0.0.1', port => 1, ssl_mode => 'disabled' }, timeout => 2);
is($p->{light}, 'red', 'closed port probes red');
ok($p->{ms} < 3000, 'probe respects timeout');

done_testing;
