package Proc::tored::Role::Running;
# ABSTRACT: Thing

use strict;
use warnings;
use Moo::Role;
use Types::Standard -types;
use Time::HiRes 'sleep';
use Guard 'guard';

=head1 NAME

Proc::tored::Role::Running

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

=head2 poll_wait_time

Optionally specifies the length of time (in fractional seconds) during which
the process will sleep when calling L</stop_running_service> with a C<timeout>.
Defaults to 0.2 seconds.

=cut

has poll_wait_time => (
  is  => 'ro',
  isa => Num,
  default => 0.2,
);

=head2 is_running

Returns true while the service is running in the current process.

=cut

has is_running => (
  is  => 'ro',
  isa => Bool,
  default => 0,
  init_arg => undef,
);

=head2 signal_handler

Used internally to store the previously set signal handlers while
L</is_running> is true.

=cut

has signal_handler => (
  is  => 'ro',
  isa => Map[Str, CodeRef],
  default => sub { {} },
  init_arg => undef,
);

=head2 run_guard

A Guard used to ensure signal handlers are restored when the object is destroyed.

=cut

has run_guard => (
  is  => 'ro',
  isa => Maybe[InstanceOf['Guard']],
  init_arg => undef,
);

=head1 METHODS

=head2 start

Flags the current process as I<running>. While running, handlers for
C<SIGTERM>, C<SIGINT>, C<SIGPIPE>, and C<SIGHUP> are installed. After calling
this method, L</is_running> will return true.

=cut

sub _build_signal_handler {
  my ($self, $signal) = @_;

  sub {
    $self->{is_running} = 0; # redundant, but an existing sigterm handler may inspect it
    $self->signal_handler->{$signal}->(@_)
      if $self->signal_handler->{$signal};
    $self->stop;
  };
}

sub start {
  my $self = shift;
  $self->{is_running} = 1;

  my %sig = %SIG;
  $self->{signal_handler} = \%sig;

  $SIG{$_} = $self->_build_signal_handler($_)
    foreach qw(TERM INT PIPE HUP);

  $self->{run_guard} = guard {
    $SIG{$_} = $sig{$_} # resore signal handlers
      foreach qw(TERM INT PIPE HUP);
  };

  return 1;
}

=head2 stop

Flags the current process as I<not running> and restores any previously
configured signal handlers. Once this method has been called, L</is_running>
will return false.

=cut

sub stop {
  my $self = shift;
  $self->{is_running} = 0;
  undef $self->{run_guard};
  $self->{signal_handler} = {};
  return 1;
}

=head2 stop_running_process

Issues a C<SIGTERM> to the active process. Returns 0 immediately if the pid
file does not exist or is empty. Otherwise, polls the running process until the
OS reports that it is no longer able to receive signals (using `kill(0,
$pid)`).

Accepts a C<$timeout> in fractional seconds, causing the function to return 0
if the process takes longer than C<$timeout> seconds to complete.

Returns the pid of the completed process otherwise.

=cut

sub _alive { kill(0, $_[0]) > 0 }

sub stop_running_process {
  my ($self, $pid, $timeout) = @_;
  my $sleep = $self->poll_wait_time;
  return 0 unless $pid;

  if (kill('SIGTERM', $pid) > 0) {
    if ($timeout) {
      while (_alive($pid) && $timeout > 0) {
        sleep $sleep;
        $timeout -= $sleep;
      }
    }
  }

  _alive($pid) ? $pid : 0;
}

1;
