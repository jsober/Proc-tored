package Proc::tored::Role::Running;
# ABSTRACT: add running state and signal handling to services

use strict;
use warnings;
use Moo::Role;
use Types::Standard -types;
use Time::HiRes 'sleep';
use Guard 'guard';

my @SIGNALS = qw(TERM INT PIPE HUP);

=head1 SYNOPSIS

  package Some::Thing;
  use Moo;

  with 'Proc::tored::Running';

  sub run {
    my $self = shift;

    $self->start;

    while ($self->is_running) {
      do_stuff(...);
    }
  }

=head1 DESCRIPTION

Classes consuming this role are provided with controls to L</start> and
L</stop> voluntarily, along with a C<SIGTERM> handler that is active while the
class L</is_running>. If a C<SIGTERM> is received via another process (by
calling L</stop_running_process>), the class will voluntarily L</stop> itself.

=head1 ATTRIBUTES

=head2 run_guard

A Guard used to ensure signal handlers are restored when the object is destroyed.

=cut

has run_guard => (
  is  => 'ro',
  isa => Maybe[InstanceOf['Guard']],
  init_arg => undef,
);

=head1 METHODS

=head2 is_running

Returns true while the service is running in the current process.

=cut

sub is_running { defined $_[0]->run_guard ? 1 : 0 }

=head2 start

Flags the current process as I<running>. While running, handlers for
C<SIGTERM>, C<SIGINT>, C<SIGPIPE>, and C<SIGHUP> are installed. After calling
this method, L</is_running> will return true.

=cut

sub start {
  my $self = shift;
  my %sig = %SIG;
  my @existing = grep { $sig{$_} } @SIGNALS;

  foreach my $signal (@SIGNALS) {
    $SIG{$signal} = sub {
      $sig{$signal} && $sig{$signal}->(@_);
      $self->stop;
    };
  }

  $self->{run_guard} = guard {
    undef $SIG{$_} foreach @SIGNALS; # remove our handlers
    $SIG{$_} = $sig{$_} foreach @existing; # restore original handlers
    undef %sig;
  };

  $self->is_running;
}

=head2 stop

Flags the current process as I<not running> and restores any previously
configured signal handlers. Once this method has been called, L</is_running>
will return false.

=cut

sub stop { undef $_[0]->{run_guard}; !$_[0]->is_running; }

=head2 stop_running_process

Issues a C<SIGTERM> to the active process. Returns 0 immediately if the pid
file does not exist or is empty. Otherwise, polls the running process until the
OS reports that it is no longer able to receive signals (with `kill(0, $pid)`).

Optional parameter C<$timeout> may be specified in fractional seconds, causing
C<stop_running_process> to block up to (around) C<$timeout> seconds waiting for
the signaled process to exit.

Returns the pid of the completed process otherwise.

=cut

sub stop_running_process {
  my ($self, $pid, $timeout, $sleep) = @_;
  return 0 unless $pid;
  $sleep ||= 0.2;

  if (kill('TERM', $pid) > 0) {
    if ($timeout) {
      while (kill(0, $pid) && $timeout > 0) {
        sleep $sleep;
        $timeout -= $sleep;
      }
    }
  }

  !kill(0, $pid);
}

1;
