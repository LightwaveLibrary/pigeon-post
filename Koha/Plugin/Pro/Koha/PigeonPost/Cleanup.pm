package Koha::Plugin::Pro::Koha::PigeonPost::Cleanup;

# Finds patron email addresses that keep failing and (on request) clears them so
# they stop clogging the message queue. Every change is logged and undoable.

use strict;
use warnings;
use Koha::Plugin::Pro::Koha::PigeonPost::Util qw(today add_days);

our @FIELDS = qw(email emailpro B_email);
our %FIELD_OK = map { $_ => 1 } @FIELDS;

# Failure codes that say nothing about the address itself; they neither count
# toward the threshold nor reset the streak.
our %IGNORED_CODES = map { $_ => 1 } qw(NO_EMAIL NO_FROM INVALID_BORNUMBER DUPLICATE_MESSAGE MISSING_SMS);

sub new {
    my ($class, %args) = @_;
    return bless {%args}, $class;    # dbh, log_table
}

# ---- pure logic -------------------------------------------------------------

sub _ignored {
    my ($code) = @_;
    return 0 unless defined $code && length $code;
    (my $base = $code) =~ s/:.*//;
    return $IGNORED_CODES{$base} ? 1 : 0;
}

# $rows: arrayref of { address, status ('sent'|'failed'), code, time } sorted by
# address then time ascending. Returns { address => {fails, last_time, last_code} }
# counting failures since that address's most recent successful send.
sub consecutive_failures {
    my ($rows) = @_;
    my %s;
    for my $r (@$rows) {
        my $a = lc($r->{address} // '');
        $a =~ s/^\s+|\s+$//g;
        next unless length $a;
        my $e = $s{$a} //= { fails => 0 };
        if (($r->{status} // '') eq 'sent') {
            $e->{fails} = 0;
            delete @$e{qw(last_time last_code)};
        } elsif (($r->{status} // '') eq 'failed' && !_ignored($r->{code})) {
            $e->{fails}++;
            $e->{last_time} = $r->{time};
            $e->{last_code} = $r->{code};
        }
    }
    return \%s;
}

# Outage guard: if most recent sends failed, the problem is SMTP, not addresses.
sub looks_like_outage {
    my ($sent, $failed) = @_;
    my $total = ($sent // 0) + ($failed // 0);
    return 0 if ($failed // 0) < 10;
    return $failed / $total > 0.5 ? 1 : 0;
}

# ---- queries ----------------------------------------------------------------

sub recent_health {
    my ($self) = @_;
    my ($sent, $failed) = $self->{dbh}->selectrow_array(
        q{SELECT COALESCE(SUM(status='sent'),0), COALESCE(SUM(status='failed'),0) FROM message_queue
           WHERE message_transport_type='email' AND updated_on >= NOW() - INTERVAL 1 DAY});
    return { sent => $sent + 0, failed => $failed + 0, outage => looks_like_outage($sent, $failed) };
}

# Returns arrayref of candidates:
# { borrowernumber, cardnumber, name, field, address, fails, last_time, last_code }
sub candidates {
    my ($self, %o) = @_;
    my $threshold = $o{threshold} && $o{threshold} =~ /^\d+$/ && $o{threshold} > 0 ? $o{threshold} : 3;
    my $days      = $o{days} && $o{days} =~ /^\d+$/ && $o{days} > 0 ? $o{days} : 90;
    my @fields    = grep { $FIELD_OK{$_} } @{ $o{fields} || ['email'] };
    @fields = ('email') unless @fields;
    my $dbh   = $self->{dbh};
    my $since = add_days(today(), -$days) . ' 00:00:00';
    my $has_fc = $o{has_failure_code} // 1;
    my $fc = $has_fc ? 'failure_code' : "''";

    my $addrs = $dbh->selectcol_arrayref(
        q{SELECT LOWER(TRIM(to_address)) a FROM message_queue
           WHERE message_transport_type='email' AND status='failed' AND to_address IS NOT NULL AND to_address <> ''
             AND time_queued >= ? GROUP BY a HAVING COUNT(*) >= ? LIMIT 5000}, undef, $since, $threshold);
    return [] unless @$addrs;

    my %streak;
    while (my @chunk = splice(@$addrs, 0, 500)) {
        my $ph   = join ',', ('?') x @chunk;
        my $rows = $dbh->selectall_arrayref(
            qq{SELECT LOWER(TRIM(to_address)) AS address, status, $fc AS code, time_queued AS time FROM message_queue
                WHERE message_transport_type='email' AND status IN ('sent','failed') AND time_queued >= ?
                  AND LOWER(TRIM(to_address)) IN ($ph) ORDER BY address, time_queued, message_id},
            { Slice => {} }, $since, @chunk);
        my $s = consecutive_failures($rows);
        $streak{$_} = $s->{$_} for grep { $s->{$_}{fails} >= $threshold } keys %$s;
    }
    return [] unless %streak;

    my @out;
    my @bad = sort keys %streak;
    for my $field (@fields) {    # $field is from the allowlist above
        for (my $i = 0; $i < @bad; $i += 500) {
            my @chunk = @bad[ $i .. ($i + 499 < $#bad ? $i + 499 : $#bad) ];
            my $ph    = join ',', ('?') x @chunk;
            my $rows  = $dbh->selectall_arrayref(
                qq{SELECT borrowernumber, cardnumber, CONCAT_WS(' ', firstname, surname) AS name, LOWER(TRIM($field)) AS address
                     FROM borrowers WHERE LOWER(TRIM($field)) IN ($ph)}, { Slice => {} }, @chunk);
            for my $r (@$rows) {
                my $st = $streak{ $r->{address} };
                push @out, { %$r, field => $field, fails => $st->{fails}, last_time => $st->{last_time}, last_code => $st->{last_code} // '' };
            }
        }
    }
    return [ sort { $b->{fails} <=> $a->{fails} || $a->{address} cmp $b->{address} } @out ];
}

# $items: arrayref of candidate hashes (already validated by the caller against
# a fresh candidates() call). $staff: borrowernumber of the acting user or undef (auto).
# %o: after => sub { my ($item, $log_id) = @_; returns a hashref merged into the result }
sub apply {
    my ($self, $items, $staff, %o) = @_;
    require Koha::Patrons;
    my $dbh = $self->{dbh};
    my $t   = $self->{log_table};
    my @results;
    for my $it (@$items) {
        my $res = { borrowernumber => $it->{borrowernumber}, field => $it->{field}, address => $it->{address} };
        my $ok  = eval {
            die "bad field\n" unless $FIELD_OK{ $it->{field} };
            my $patron = Koha::Patrons->find($it->{borrowernumber}) or die "patron not found\n";
            my $cur    = lc($patron->${\ $it->{field} } // '');
            $cur =~ s/^\s+|\s+$//g;
            die "address changed since preview\n" unless $cur eq $it->{address};
            $patron->set({ $it->{field} => undef })->store;

            my $marked = $dbh->do(
                q{UPDATE message_queue SET status='deleted' WHERE status='pending' AND message_transport_type='email'
                    AND LOWER(TRIM(to_address)) = ?}, undef, $it->{address}) + 0;
            $patron->discard_changes;
            my $left = grep { my $v = $patron->$_; defined $v && $v =~ /\S/ } @FIELDS;
            unless ($left) {    # nothing left to send to: queued rows without an address can't succeed
                $marked += $dbh->do(
                    q{UPDATE message_queue SET status='deleted' WHERE status='pending' AND message_transport_type='email'
                        AND borrowernumber = ? AND (to_address IS NULL OR to_address = '')}, undef, $it->{borrowernumber}) + 0;
            }
            $dbh->do(qq{INSERT INTO $t (borrowernumber, field, old_address, failures, last_failure_code, pending_marked, cleared_at, cleared_by)
                         VALUES (?,?,?,?,?,?,NOW(),?)},
                undef, $it->{borrowernumber}, $it->{field}, $it->{address}, $it->{fails}, $it->{last_code}, $marked, $staff);
            $res->{pending_marked} = $marked;
            $res->{log_id} = $dbh->{mysql_insertid} // $dbh->last_insert_id(undef, undef, $t, 'id');
            1;
        };
        if ($ok && $o{after}) {    # follow-up work must never undo a successful clear
            my $extra = eval { $o{after}->($it, $res->{log_id}) };
            if ($@) { ($res->{after_error} = $@) =~ s/\s+$//; }
            elsif (ref $extra eq 'HASH') { %$res = (%$res, %$extra) }
        }
        $res->{ok} = $ok ? 1 : 0;
        ($res->{error} = $@) =~ s/\s+$// unless $ok;
        push @results, $res;
    }
    return \@results;
}

sub undo {
    my ($self, $id, $staff) = @_;
    require Koha::Patrons;
    my $t   = $self->{log_table};
    my $row = $self->{dbh}->selectrow_hashref("SELECT * FROM $t WHERE id = ?", undef, $id) or return { ok => 0, error => 'Log entry not found' };
    return { ok => 0, error => 'Already undone' } if $row->{undone_at};
    return { ok => 0, error => 'Bad field' } unless $FIELD_OK{ $row->{field} };
    my $patron = Koha::Patrons->find($row->{borrowernumber}) or return { ok => 0, error => 'Patron no longer exists' };
    my $cur = $patron->${\ $row->{field} };
    return { ok => 0, error => 'Patron already has a new address in that field' } if defined $cur && $cur =~ /\S/;
    $patron->set({ $row->{field} => $row->{old_address} })->store;
    $self->{dbh}->do("UPDATE $t SET undone_at = NOW(), undone_by = ? WHERE id = ?", undef, $staff, $id);
    return { ok => 1 };
}

sub log_entries {
    my ($self, $limit) = @_;
    my $t = $self->{log_table};
    return $self->{dbh}->selectall_arrayref(
        qq{SELECT l.*, CONCAT_WS(' ', b.firstname, b.surname) AS name, b.cardnumber,
                  CONCAT_WS(' ', s.firstname, s.surname) AS cleared_by_name
             FROM $t l LEFT JOIN borrowers b ON b.borrowernumber = l.borrowernumber
                       LEFT JOIN borrowers s ON s.borrowernumber = l.cleared_by
         ORDER BY l.id DESC LIMIT ?}, { Slice => {} }, $limit || 100);
}

sub cleared_between {
    my ($self, $from, $to) = @_;
    my $t = $self->{log_table};
    my ($n) = $self->{dbh}->selectrow_array("SELECT COUNT(*) FROM $t WHERE cleared_at >= ? AND cleared_at < ? AND undone_at IS NULL",
        undef, "$from 00:00:00", add_days($to, 1) . ' 00:00:00');
    return $n + 0;
}

1;
