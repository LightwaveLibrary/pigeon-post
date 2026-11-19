package Koha::Plugin::Pro::Koha::PigeonPost::Util;

# Pure helpers (no Koha dependencies) so they can be unit-tested anywhere.

use strict;
use warnings;
use POSIX qw(strftime);
use Time::Local qw(timegm);
use Exporter 'import';

our @EXPORT_OK = qw(today valid_date add_days days_between parse_range escape_html wday_of);

sub today { return strftime('%Y-%m-%d', localtime(shift // time)) }

sub valid_date {
    my ($d) = @_;
    return 0 unless defined $d && $d =~ /\A(\d{4})-(\d{2})-(\d{2})\z/;
    my ($y, $m, $day) = ($1, $2, $3);
    return 0 if $m < 1 || $m > 12 || $day < 1 || $day > 31;
    my $ok = eval { timegm(0, 0, 12, $day, $m - 1, $y); 1 };
    return $ok ? 1 : 0;
}

sub _epoch {
    my ($d) = @_;
    my ($y, $m, $day) = split /-/, $d;
    return timegm(0, 0, 12, $day, $m - 1, $y);
}

sub add_days {
    my ($d, $n) = @_;
    return strftime('%Y-%m-%d', gmtime(_epoch($d) + $n * 86400));
}

sub days_between {    # inclusive count of days from $a to $b
    my ($a, $b) = @_;
    return int((_epoch($b) - _epoch($a)) / 86400 + 0.5) + 1;
}

sub wday_of {    # 0 = Sunday .. 6 = Saturday
    my ($d) = @_;
    return (gmtime(_epoch($d)))[6];
}

# Normalise a user-supplied date range. Defaults to the last 30 days ending
# today, swaps reversed bounds, never runs past today, caps at ~10 years.
sub parse_range {
    my ($from, $to, $today) = @_;
    $today //= today();
    $to   = $today                 unless valid_date($to);
    $from = add_days($to, -29)     unless valid_date($from);
    ($from, $to) = ($to, $from) if $from gt $to;
    $to = $today if $to gt $today;
    $from = $to if $from gt $to;
    $from = add_days($to, -3659) if days_between($from, $to) > 3660;
    return ($from, $to);
}

sub escape_html {
    my ($s) = @_;
    $s //= '';
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    return $s;
}

1;
