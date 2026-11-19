package Koha::Plugin::Pro::Koha::PigeonPost::Stats;

# Email activity statistics. Reads Koha's message_queue (never writes it) and
# the plugin-owned daily rollup table, which preserves history that Koha's
# cleanup_database.pl --mail would otherwise purge.

use strict;
use warnings;
use Koha::Plugin::Pro::Koha::PigeonPost::Util qw(today add_days days_between);

use constant FINAL_LAG_DAYS => 2;    # days older than today-2 are finalised into the rollup

sub new {
    my ($class, %args) = @_;
    my $self = bless {%args}, $class;    # dbh, rollup_table
    return $self;
}

sub cutoff { my ($self, $today) = @_; return add_days($today // today(), -FINAL_LAG_DAYS) }

sub has_failure_code {
    my ($self) = @_;
    return $self->{_has_fc} //= do {
        my $sth = $self->{dbh}->prepare(q{SHOW COLUMNS FROM message_queue LIKE 'failure_code'});
        $sth->execute;
        $sth->fetchrow_arrayref ? 1 : 0;
    };
}

# ---- pure aggregation -------------------------------------------------------

# $rows: arrayref of { day, letter_code, sent, failed, pending, deleted }
# Returns { series => [ {day, sent, failed, pending} ... contiguous ],
#           totals => {sent, failed, pending}, by_letter => [ {letter_code, sent, failed} ] }
sub aggregate {
    my ($rows, $from, $to, $letter) = @_;
    my (%day, %by_letter);
    for my $r (@$rows) {
        next if $r->{day} lt $from || $r->{day} gt $to;
        my $code = $r->{letter_code} // '';
        next if defined $letter && length $letter && $code ne $letter;
        for my $k (qw(sent failed pending)) {
            $day{ $r->{day} }{$k} += $r->{$k} // 0;
            $by_letter{$code}{$k} += $r->{$k} // 0;
        }
    }
    my (@series, %totals);
    my $n = days_between($from, $to);
    for my $i (0 .. $n - 1) {
        my $d = add_days($from, $i);
        my $e = { day => $d, map { $_ => $day{$d}{$_} // 0 } qw(sent failed pending) };
        $totals{$_} += $e->{$_} for qw(sent failed pending);
        push @series, $e;
    }
    $totals{$_} //= 0 for qw(sent failed pending);
    my @letters = sort { ($b->{sent} + $b->{failed}) <=> ($a->{sent} + $a->{failed}) || $a->{letter_code} cmp $b->{letter_code} }
        map { { letter_code => ($_ eq '' ? '(none)' : $_), sent => $by_letter{$_}{sent} // 0, failed => $by_letter{$_}{failed} // 0 } }
        keys %by_letter;
    my $attempted = $totals{sent} + $totals{failed};
    $totals{failure_rate} = $attempted ? sprintf('%.1f', 100 * $totals{failed} / $attempted) + 0 : 0;
    return { series => \@series, totals => \%totals, by_letter => \@letters };
}

# ---- queries ----------------------------------------------------------------

my $LIVE_GROUP = q{
    SELECT DATE(time_queued) AS day, COALESCE(letter_code,'') AS letter_code,
           SUM(status='sent') AS sent, SUM(status='failed') AS failed,
           SUM(status='pending') AS pending, SUM(status='deleted') AS deleted
      FROM message_queue
     WHERE message_transport_type='email' AND time_queued >= ? AND time_queued < ?
  GROUP BY DATE(time_queued), COALESCE(letter_code,'')
};

sub _live_rows {
    my ($self, $from, $to) = @_;
    return $self->{dbh}->selectall_arrayref($LIVE_GROUP, { Slice => {} }, "$from 00:00:00", add_days($to, 1) . ' 00:00:00');
}

sub _rollup_rows {
    my ($self, $from, $to) = @_;
    my $t = $self->{rollup_table};
    return $self->{dbh}->selectall_arrayref(
        "SELECT day, letter_code, sent, failed, pending, deleted FROM $t WHERE day >= ? AND day <= ?",
        { Slice => {} }, $from, $to);
}

# Rows for any range: finalised days come from the rollup, recent days live.
sub day_rows {
    my ($self, $from, $to, $today) = @_;
    my $cut = $self->cutoff($today);
    my @rows;
    my $last_final = add_days($cut, -1);
    push @rows, @{ $self->_rollup_rows($from, $to lt $last_final ? $to : $last_final) } if $from le $last_final;
    my $live_from = $from gt $cut ? $from : $cut;
    push @rows, @{ $self->_live_rows($live_from, $to) } if $live_from le $to;
    $_->{day} = "$_->{day}" for @rows;
    return \@rows;
}

sub summary {
    my ($self, %a) = @_;
    my ($from, $to, $letter, $today) = @a{qw(from to letter today)};
    $today //= today();
    my $dbh  = $self->{dbh};
    my $agg  = aggregate($self->day_rows($from, $to, $today), $from, $to, $letter);
    my $cut  = $self->cutoff($today);
    my $t    = $self->{rollup_table};

    my ($roll_sent, $roll_failed, $first_roll) = $dbh->selectrow_array("SELECT COALESCE(SUM(sent),0), COALESCE(SUM(failed),0), MIN(day) FROM $t WHERE day < ?", undef, $cut);
    my ($live_sent, $live_failed) = $dbh->selectrow_array(
        q{SELECT COALESCE(SUM(status='sent'),0), COALESCE(SUM(status='failed'),0) FROM message_queue WHERE message_transport_type='email' AND time_queued >= ?},
        undef, "$cut 00:00:00");
    my ($first_live) = $dbh->selectrow_array(q{SELECT DATE(MIN(time_queued)) FROM message_queue WHERE message_transport_type='email'});
    my ($pending, $oldest) = $dbh->selectrow_array(
        q{SELECT COUNT(*), MIN(time_queued) FROM message_queue WHERE message_transport_type='email' AND status='pending'});
    my ($oldest_age_min) = $oldest
        ? $dbh->selectrow_array(q{SELECT TIMESTAMPDIFF(MINUTE, ?, NOW())}, undef, $oldest)
        : (undef);

    my @lf = (defined $letter && length $letter) ? (' AND letter_code = ?', $letter) : ('');
    my ($lsql, @lbind) = @lf;
    my @range = ("$from 00:00:00", add_days($to, 1) . ' 00:00:00');

    my $reasons = [];
    if ($self->has_failure_code) {
        $reasons = $dbh->selectall_arrayref(
            qq{SELECT COALESCE(NULLIF(failure_code,''),'(unspecified)') AS code, COUNT(*) AS n FROM message_queue
                WHERE message_transport_type='email' AND status='failed' AND time_queued >= ? AND time_queued < ? $lsql
             GROUP BY code ORDER BY n DESC LIMIT 12}, { Slice => {} }, @range, @lbind);
    }
    my $hours = $dbh->selectall_arrayref(
        qq{SELECT HOUR(time_queued) AS hour, SUM(status='sent') AS sent, SUM(status='failed') AS failed FROM message_queue
            WHERE message_transport_type='email' AND time_queued >= ? AND time_queued < ? $lsql GROUP BY HOUR(time_queued)},
        { Slice => {} }, @range, @lbind);
    my %h = map { $_->{hour} => $_ } @$hours;
    my @by_hour = map { { hour => $_, sent => ($h{$_}{sent} // 0) + 0, failed => ($h{$_}{failed} // 0) + 0 } } 0 .. 23;

    my $letters = $dbh->selectcol_arrayref(
        "SELECT DISTINCT letter_code FROM (SELECT letter_code FROM $t UNION SELECT DISTINCT letter_code FROM message_queue WHERE message_transport_type='email') x WHERE letter_code IS NOT NULL AND letter_code <> '' ORDER BY letter_code");

    my $first_ever = (grep defined, $first_roll, $first_live)[0];
    $first_ever = $first_live if defined $first_live && defined $first_ever && $first_live lt $first_ever;

    return {
        from => $from, to => $to, letter => $letter // '',
        lifetime => {
            sent => $roll_sent + $live_sent, failed => $roll_failed + $live_failed,
            since => $first_ever,
        },
        range         => $agg->{totals},
        series        => $agg->{series},
        by_letter     => [ @{ $agg->{by_letter} }[ 0 .. ($#{ $agg->{by_letter} } < 9 ? $#{ $agg->{by_letter} } : 9) ] ],
        reasons       => [ map { { code => $_->{code}, n => $_->{n} + 0 } } @$reasons ],
        by_hour       => \@by_hour,
        queue         => { pending => $pending + 0, oldest => $oldest, oldest_age_minutes => defined $oldest_age_min ? $oldest_age_min + 0 : undef },
        retained_from => $first_live,
        letter_codes  => $letters,
    };
}

sub failed_list {
    my ($self, %a) = @_;
    my ($from, $to, $letter) = @a{qw(from to letter)};
    my $fc = $self->has_failure_code ? "SUBSTRING_INDEX(GROUP_CONCAT(COALESCE(mq.failure_code,'') ORDER BY mq.time_queued DESC SEPARATOR '\\n'), '\\n', 1)" : "''";
    my ($lsql, @lbind) = (defined $letter && length $letter) ? (' AND mq.letter_code = ?', $letter) : ('');
    return $self->{dbh}->selectall_arrayref(
        qq{SELECT LOWER(TRIM(mq.to_address)) AS address, COUNT(*) AS failures, MAX(mq.time_queued) AS last_failed,
                  $fc AS last_code, MAX(mq.borrowernumber) AS borrowernumber,
                  MAX(CONCAT_WS(' ', b.firstname, b.surname)) AS patron
             FROM message_queue mq LEFT JOIN borrowers b ON b.borrowernumber = mq.borrowernumber
            WHERE mq.message_transport_type='email' AND mq.status='failed'
              AND mq.time_queued >= ? AND mq.time_queued < ? $lsql
         GROUP BY LOWER(TRIM(mq.to_address)) ORDER BY failures DESC, last_failed DESC LIMIT 500},
        { Slice => {} }, "$from 00:00:00", add_days($to, 1) . ' 00:00:00', @lbind);
}

# Finalise every day after $rolled_through (exclusive) and before the cutoff.
# Returns the new rolled-through day (or the old one if nothing to do).
sub rollup {
    my ($self, $rolled_through, $today) = @_;
    my $cut  = $self->cutoff($today);
    my $last = add_days($cut, -1);
    return $rolled_through if defined $rolled_through && $rolled_through ge $last;
    my $t     = $self->{rollup_table};
    my $start = defined $rolled_through ? add_days($rolled_through, 1) . ' 00:00:00' : '1970-01-01 00:00:00';
    $self->{dbh}->do(
        qq{REPLACE INTO $t (day, letter_code, sent, failed, pending, deleted)
           SELECT DATE(time_queued), COALESCE(letter_code,''), SUM(status='sent'), SUM(status='failed'),
                  SUM(status='pending'), SUM(status='deleted')
             FROM message_queue
            WHERE message_transport_type='email' AND time_queued >= ? AND time_queued < ?
         GROUP BY DATE(time_queued), COALESCE(letter_code,'')},
        undef, $start, "$cut 00:00:00");
    return $last;
}

1;
