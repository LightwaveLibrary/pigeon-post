package Koha::Plugin::Pro::Koha::PigeonPost::PrintQueue;

# Print notices sit in message_queue as status 'pending' until
# gather_print_notices.pl collects them. If nobody prints them they pile up
# forever. This module reports on that backlog and (on request, or nightly when
# opted in) marks notices older than N days as 'deleted'. Nothing is physically
# deleted; every run records the exact message_ids so it can be undone.

use strict;
use warnings;
use Koha::Plugin::Pro::Koha::PigeonPost::Util qw(today add_days);

sub new {
    my ($class, %args) = @_;
    return bless {%args}, $class;    # dbh, log_table, ids_table
}

# Valid "older than" setting: whole days, 1..3650. Anything else -> default 90.
sub valid_days {
    my ($d) = @_;
    return defined $d && $d =~ /\A\d+\z/ && $d >= 1 && $d <= 3650 ? $d + 0 : 90;
}

# Notices queued before this moment are "older than $days days".
sub cutoff {
    my ($days, $today) = @_;
    return add_days($today // today(), -valid_days($days)) . ' 00:00:00';
}

# { pending, oldest, oldest_days, old, days, old_by_letter => [{letter_code, n}] }
sub summary {
    my ($self, $days) = @_;
    $days = valid_days($days);
    my $dbh = $self->{dbh};
    my $cut = cutoff($days);
    my ($pending, $oldest, $age, $old) = $dbh->selectrow_array(q{
        SELECT COUNT(*), MIN(time_queued), DATEDIFF(NOW(), MIN(time_queued)), COALESCE(SUM(time_queued < ?), 0)
          FROM message_queue WHERE message_transport_type = 'print' AND status = 'pending'}, undef, $cut);
    my $by = $dbh->selectall_arrayref(q{
        SELECT COALESCE(NULLIF(letter_code, ''), '(none)') AS letter_code, COUNT(*) AS n
          FROM message_queue WHERE message_transport_type = 'print' AND status = 'pending' AND time_queued < ?
      GROUP BY 1 ORDER BY n DESC LIMIT 15}, { Slice => {} }, $cut);
    return { pending => $pending + 0, oldest => $oldest, oldest_days => defined $age ? $age + 0 : undef,
             old => $old + 0, days => $days, old_by_letter => [ map { { letter_code => $_->{letter_code}, n => $_->{n} + 0 } } @$by ] };
}

sub _txn {
    my ($self, $code) = @_;
    my $dbh = $self->{dbh};
    my $own = $dbh->{AutoCommit};
    $dbh->begin_work if $own;
    my $r = eval { my $v = $code->(); $dbh->commit if $own; $v };
    if (my $e = $@) { eval { $dbh->rollback } if $own; die $e }
    return $r;
}

# Mark pending print notices older than $days as deleted. Returns { ok, cleared, log_id }.
sub clear {
    my ($self, $days, %o) = @_;
    $days = valid_days($days);
    my $dbh = $self->{dbh};
    my ($lt, $it) = @$self{qw(log_table ids_table)};
    my $cut = cutoff($days);
    return $self->_txn(sub {
        my $ids = $dbh->selectcol_arrayref(q{
            SELECT message_id FROM message_queue
             WHERE message_transport_type = 'print' AND status = 'pending' AND time_queued < ? FOR UPDATE}, undef, $cut);
        return { ok => 1, cleared => 0 } unless @$ids;
        $dbh->do(qq{INSERT INTO $lt (days, cutoff, cleared, source, ran_at, ran_by) VALUES (?,?,?,?,NOW(),?)},
            undef, $days, $cut, scalar(@$ids), $o{source}, $o{staff});
        my $log_id = $dbh->{mysql_insertid} // $dbh->last_insert_id(undef, undef, $lt, 'id');
        my $n = 0;
        for (my $i = 0; $i < @$ids; $i += 500) {
            my @chunk = @$ids[ $i .. ($i + 499 < $#$ids ? $i + 499 : $#$ids) ];
            my $ph = join ',', ('?') x @chunk;
            $dbh->do("INSERT INTO $it (log_id, message_id) VALUES " . join(',', ('(?,?)') x @chunk), undef, map { ($log_id, $_) } @chunk);
            $n += $dbh->do(qq{UPDATE message_queue SET status = 'deleted'
                               WHERE message_id IN ($ph) AND message_transport_type = 'print' AND status = 'pending'}, undef, @chunk);
        }
        $dbh->do("UPDATE $lt SET cleared = ? WHERE id = ?", undef, $n, $log_id);
        return { ok => 1, cleared => $n + 0, log_id => $log_id };
    });
}

# Put a run's notices back to pending (only those still 'deleted').
sub undo {
    my ($self, $id, $staff) = @_;
    my $dbh = $self->{dbh};
    my ($lt, $it) = @$self{qw(log_table ids_table)};
    my $row = $dbh->selectrow_hashref("SELECT * FROM $lt WHERE id = ?", undef, $id) or return { ok => 0, error => 'Log entry not found' };
    return { ok => 0, error => 'Already undone' } if $row->{undone_at};
    my $n = $self->_txn(sub {
        my $c = $dbh->do(qq{UPDATE message_queue mq JOIN $it x ON x.message_id = mq.message_id
                               SET mq.status = 'pending'
                             WHERE x.log_id = ? AND mq.status = 'deleted' AND mq.message_transport_type = 'print'}, undef, $id);
        $dbh->do("UPDATE $lt SET undone_at = NOW(), undone_by = ? WHERE id = ?", undef, $staff, $id);
        return $c + 0;
    });
    return { ok => 1, restored => $n };
}

sub log_entries {
    my ($self, $limit) = @_;
    my $lt = $self->{log_table};
    return $self->{dbh}->selectall_arrayref(
        qq{SELECT l.*, CONCAT_WS(' ', s.firstname, s.surname) AS ran_by_name
             FROM $lt l LEFT JOIN borrowers s ON s.borrowernumber = l.ran_by
         ORDER BY l.id DESC LIMIT ?}, { Slice => {} }, $limit || 50);
}

sub cleared_between {
    my ($self, $from, $to) = @_;
    my ($n) = $self->{dbh}->selectrow_array(
        "SELECT COALESCE(SUM(cleared), 0) FROM $self->{log_table} WHERE ran_at >= ? AND ran_at < ? AND undone_at IS NULL",
        undef, "$from 00:00:00", add_days($to, 1) . ' 00:00:00');
    return $n + 0;
}

1;
