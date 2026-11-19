package Koha::Plugin::Pro::Koha::PigeonPost::Smtp;

# Up/down probe for the SMTP servers configured in Koha. Connects, reads the
# banner, says EHLO (and STARTTLS when configured), then QUITs. Never
# authenticates and never sends mail.

use strict;
use warnings;
use Time::HiRes qw(time);

use constant SLOW_MS => 2000;

# Pure: decide the light colour.
sub classify {
    my (%r) = @_;
    return 'red'   unless $r{connected};
    return 'amber' if $r{tls_failed};
    return 'amber' if ($r{ms} // 0) > SLOW_MS;
    return 'green';
}

sub servers {
    my @list;
    my %seen;
    eval {
        require Koha::SMTP::Servers;
        for my $s (Koha::SMTP::Servers->search({}, { order_by => 'name' })->as_list) {
            my $u = $s->unblessed;
            push @list, { id => $u->{id}, name => $u->{name}, host => $u->{host}, port => $u->{port},
                          ssl_mode => $u->{ssl_mode} // 'disabled', timeout => $u->{timeout}, is_default => $u->{is_default} ? 1 : 0 };
            $seen{"$u->{host}:$u->{port}"} = 1;
        }
        my $d = Koha::SMTP::Servers->get_default;
        if ($d && !$seen{ $d->host . ':' . $d->port }) {
            push @list, { id => undef, name => 'Koha default (koha-conf.xml)', host => $d->host, port => $d->port,
                          ssl_mode => $d->ssl_mode // 'disabled', timeout => $d->timeout, is_default => 1 };
        }
        1;
    } or push @list, { name => 'SMTP configuration', error => 'Could not read Koha SMTP servers' };
    return \@list;
}

sub probe {
    my ($s, %o) = @_;
    my $timeout = $o{timeout} // 5;
    return { %$s, light => 'red', message => $s->{error} } if $s->{error};
    my $t0 = time;
    my %r  = (connected => 0);
    my $msg;
    eval {
        require Net::SMTP;
        my $smtp = Net::SMTP->new(
            $s->{host},
            Port    => $s->{port} || 25,
            Timeout => $timeout,
            Hello   => 'pigeon-post.koha.local',
            ($s->{ssl_mode} eq 'ssl' ? (SSL => 1) : ()),
        );
        if ($smtp) {
            $r{connected} = 1;
            $msg = $smtp->banner // 'Connected';
            if ($s->{ssl_mode} eq 'starttls') {
                my $ok = eval { $smtp->starttls };
                unless ($ok) { $r{tls_failed} = 1; $msg = 'Connected, but STARTTLS failed' }
            }
            $smtp->quit;
        } else {
            $msg = $@ || $! || 'Connection failed';
        }
        1;
    } or $msg = "Probe error: $@";
    $r{ms} = int((time - $t0) * 1000);
    $msg =~ s/\s+$// if defined $msg;
    return {
        name => $s->{name}, host => $s->{host}, port => $s->{port}, ssl_mode => $s->{ssl_mode},
        is_default => $s->{is_default}, ms => $r{ms}, light => classify(%r), message => $msg,
    };
}

sub check_all { my (%o) = @_; return [ map { probe($_, %o) } @{ servers() } ] }

1;
