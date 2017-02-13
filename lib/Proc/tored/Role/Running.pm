use strict;
use warnings;

package Proc::tored::Role::Running;
# ABSTRACT: Thing

use Moo::Role;
use Types::Standard -types;
use Time::HiRes 'sleep';

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

=head2 sigterm_handler

Used internally to store a previously set C<$SIG{TERM}> handler while
L</is_running> is true.

=cut

has sigterm_handler => (
  is  => 'ro',
  isa => Maybe[CodeRef],
  init_arg => undef,
);

=head1 METHODS

=head2 start

Flags the current process as I<running>. While running, a C<SIGTERM> handler is
installed that will L</stop> the current process. After calling this method,
L</is_running> will return true.

=cut

sub start {
  my $self = shift;
  $self->{is_running} = 1;
  $self->{sigterm_handler} = $SIG{TERM};

  $SIG{TERM} = sub {
    $self->{is_running} = 0; # redundant, but an existing sigterm handler may inspect it
    $self->sigterm_handler->(@_) if $self->sigterm_handler;
    $self->stop;
  };

  return 1;
}

=head2 stop

Flags the current process as I<not running> and restores any previously
configured C<SIGTERM> handlers. Once this method has been called,
L</is_running> will return false.

=cut

sub stop {
  my $self = shift;
  $self->{is_running} = 0;
  $SIG{TERM} = $self->{sigterm_handler};
  undef $self->{sigterm_handler};
  return 1;
}

=head2 stop_running_process

Sends a C<SIGTERM> to the active process. Returns 0 immediately if the pid file
does not exist or is empty. Otherwise, polls the running process until the OS
reports that it is no longer able to receive signals (using `kill(0, $pid)`).

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
