package Proc::tored::Role::Running;
# ABSTRACT: add running state and signal handling to services

use strict;
use warnings;
use Moo::Role;
use Carp;
use Const::Fast;
use Guard 'guard';
use Path::Tiny 'path';
use Time::HiRes 'alarm';
use Types::Standard -types;

const our $NOSIGNALS => $^O eq 'MSWin32';
const our @SIGNALS => qw(TERM INT PIPE HUP);

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
class L</is_running>. If a C<SIGTERM> is received via another process (e.g., by
calling L<Proc::tored::Manager/stop_running_process>), the class will
voluntarily L</stop> itself.

=head1 ATTRIBUTES

=head2 term_file

On systems where posix signals are not supported or are poorly implemented (looking
at YOU, MSWin32), setting a C<term_file> causes the class to instead monitor for a
touch file's existence as the signal to stop running.

=cut

has term_file => (
  is  => 'ro',
  isa => Maybe[Str],
  required => $NOSIGNALS,
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

=head2 is_running

Returns true while the service is running in the current process.

=cut

#sub is_running { defined $_[0]->run_guard ? 1 : 0 }

sub is_running {
  my $self = shift;
  return 0 unless defined $self->run_guard;
  return 0 if $self->term_file && path($self->term_file)->exists;
  return 1;
}

=head2 start

Flags the current process as I<running>. While running, handlers for
C<SIGTERM>, C<SIGINT>, C<SIGPIPE>, and C<SIGHUP> are installed. After calling
this method, L</is_running> will return true.

=cut

sub start {
  my $self = shift;
  return if $self->is_running;

  if ($self->term_file) {
    $self->_install_timer;
  }
  else {
    $self->_install_handlers;
  }

  $self->is_running;
}

=head2 stop

Flags the current process as I<not running> and restores any previously
configured signal handlers. Once this method has been called, L</is_running>
will return false.

=cut

sub stop {
  my $self = shift;
  undef $self->{run_guard};
  !$self->is_running;
}

=head2 signal

Signals the process to stop running. If L</term_file> is set, this is done by
creating a touch file. Otherwise, the caller is required to specify the pid of
the process being signalled.

=cut

sub signal {
  my $self = shift;

  if ($self->term_file) {
    path($self->term_file)->touch;
  }
  else {
    my $pid = shift or croak 'expected $pid';
    kill 'TERM', $pid;
  }
}

#-------------------------------------------------------------------------------
# Installs signal handlers for @SIGNALS and creates the run_guard.
#-------------------------------------------------------------------------------
sub _install_handlers {
  my $self = shift;
  my @existing = grep { $SIG{$_} } @SIGNALS;
  my %sig = %SIG;

  $self->{run_guard} = guard {
    undef $SIG{$_} foreach @SIGNALS; # remove our handlers
    $SIG{$_} = $sig{$_} foreach @existing; # restore original handlers
    undef %sig;
  };

  foreach my $signal (@SIGNALS) {
    my $orig = $SIG{$signal};
    $SIG{$signal} = sub { $self->stop; $orig && $orig->(@_); };
  }
}

#-------------------------------------------------------------------------------
# Install an alarm timer and create the run_guard.
#-------------------------------------------------------------------------------
sub _install_timer {
  my $self = shift;
  my $file = path($self->term_file);
  my $intvl = 0.2;

  $self->{run_guard} = guard {
    alarm 0;
    undef $SIG{ALRM};
    $file->remove;
  };

  $SIG{ALRM} = sub {
    $self->stop if $file->exists;
    alarm $intvl;
  };

  alarm $intvl;
}

1;
