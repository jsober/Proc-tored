package Proc::tored::Manager;
# ABSTRACT: OO interface to creating a proctored service

=head1 SYNOPSIS

  my $proctor = Proc::tored::Manager->new(dir => '/tmp', name => 'my-service');

  # Call do_stuff while the service is running or until do_stuff returns false
  $proctor->service(\&do_stuff)
    or die sprintf('process %d is already running this service!', $proctor->running_pid);

  # Signal another process running this service to quit gracefully, throwing an
  # error if it does not self-terminate after 15 seconds.
  if (my $pid = $proctor->stop_wait(15)) {
    die "process $pid is being stubborn!";
  }

=head1 DESCRIPTION

Objective interface for creating and managing a proctored service.

=cut

use strict;
use warnings;
use Moo;
use Carp;
use Fcntl qw(:flock :seek :DEFAULT);
use Guard qw(guard);
use Path::Tiny qw(path);
use Time::HiRes qw(sleep);
use Try::Tiny;
use Types::Standard -all;
use Proc::tored::Types -types;
use Proc::tored::Flag;

=head1 METHODS

=head2 new

Creates a new service object, which can be used to run the service and/or
signal another process to quit. The pid file is not created or accessed by this
method.

=over

=cut

=item name

The name of the service. Services created with an identical L</name> and
L</dir> will use the same pid file and share flags.

=cut

has name => (
  is  => 'ro',
  isa => NonEmptyStr,
  required => 1,
);

=item dir

A valid run directory (C</var/run> is a common choice). The path must be
writable.

=cut

has dir => (
  is  => 'ro',
  isa => Dir,
  required => 1,
);

=item pid_file

Unless manually specified, the pid file's path is L</dir>/L</name>.pid.

=cut

has pid_file => (
  is  => 'lazy',
  isa => NonEmptyStr,
);

sub _build_pid_file {
  my $self = shift;
  my $file = path($self->dir)->child($self->name . '.pid');
  return "$file";
}

=item stop_file

Unless manually specified, the stop file's path is L</dir>/L</name>.stopped.

=cut

has stop_file => (
  is => 'lazy',
  isa => NonEmptyStr,
);

sub _build_stop_file {
  my $self = shift;
  my $file = path($self->dir)->child($self->name . '.stopped');
  return "$file";
}

has stop_flag => (
  is  => 'lazy',
  isa => InstanceOf['Proc::tored::Flag'],
  handles => {
    stop => 'set',
    start => 'unset',
    is_stopped => 'is_set',
  },
);

sub _build_stop_flag {
  my $self = shift;
  Proc::tored::Flag->new(touch_file_path => $self->stop_file);
}

=item pause_file

Unless manually specified, the pause file's path is L</dir>/L</name>.paused.

=back

=cut

has pause_file => (
  is => 'lazy',
  isa => NonEmptyStr,
);

sub _build_pause_file {
  my $self = shift;
  my $file = path($self->dir)->child($self->name . '.paused');
  return "$file";
}

has pause_flag => (
  is  => 'lazy',
  isa => InstanceOf['Proc::tored::Flag'],
  handles => {
    pause => 'set',
    resume => 'unset',
    is_paused => 'is_set',
  },
);

sub _build_pause_flag {
  my $self = shift;
  Proc::tored::Flag->new(touch_file_path => $self->pause_file);
}

has lock_file => (
  is  => 'lazy',
  isa => NonEmptyStr,
  init_arg => undef,
);

sub _build_lock_file {
  my $self = shift;
  my $file = path($self->dir)->child($self->name . '.lock');
  return "$file";
}

=head1 METHODS

=head2 stop

=head2 start

=head2 is_stopped

Controls and inspects the "stopped" flag. While stopped, the L</service> loop
will refuse to run.

=head2 pause

=head2 resume

=head2 is_paused

Controls and inspects the "paused" flag. While paused, the L</service> loop
will continue to run but will not execute the code block passed in.

=head2 clear_flags

Clears both the "stopped" and "paused" flags.

=cut

sub clear_flags {
  my $self = shift;
  $self->start;
  $self->resume;
}

=head2 is_running

Returns true if the current process is the active, running process.

=cut

sub is_running {
  my $self = shift;
  return $self->running_pid == $$;
}

=head2 service

Accepts a code ref which will be called repeatedly until it returns false or
the "stopped" flag is set. If the "paused" flag is set, will continue to rune
but will not execute the code block until the "paused" flag has been cleared.

Example using a pool of forked workers, an imaginary task queue, and a
secondary condition that decides whether to stop running.

  $proctor->service(sub {
    # Wait for an available worker, but with a timeout
    my $worker = $worker_pool->next_available(0.1);

    if ($worker) {
      # Pull next task from the queue with a 0.1s timeout
      my $task = poll_queue_with_timeout(0.1);

      if ($task) {
        $worker->assign($task);
      }
    }

    return unless touch_file_exists();
    return 1;
  });

=cut

sub service {
  my ($self, $code) = @_;
  return 0 if $self->is_stopped;
  return 0 if $self->running_pid;
  die 'expected a CODE ref' unless is_CodeRef($code);

  if (my $guard = $self->run_lock) {
    until ($self->is_stopped) {
      if ($self->is_paused) {
        sleep 0.2;
        next;
      }

      last unless $code->();
    }

    return 1;
  }

  return 0;
}

=head2 read_pid

Returns the pid identified in the pid file. Returns 0 if the pid file does
not exist or is empty.

=cut

sub read_pid {
  my $self = shift;
  my $file = path($self->pid_file);
  return 0 unless $file->is_file;
  my ($line) = $file->lines({count => 1, chomp => 1}) or return 0;
  my ($pid) = $line =~ /^(\d+)$/;
  return $pid || 0;
}

=head2 running_pid

Returns the pid of an already-running process or 0 if the pid file does not
exist, is empty, or the process identified by the pid does not exist or is not
visible.

=cut

sub running_pid {
  my $self = shift;
  my $pid = $self->read_pid;
  return 0 unless $pid;
  return $pid if kill 0, $pid;
  return 0;
}

=head2 stop_wait

Sets the "stopped" flag and blocks until the L<running_pid> exits or the
C<$timeout> is reached.

  $service->stop_wait(30); # stop and block for up to 30 seconds

=cut

sub stop_wait {
  my ($self, $timeout, $sleep) = @_;
  $sleep ||= 0.2;

  $self->stop;
  return if $self->is_running;

  my $pid = $self->running_pid || return 0;

  while (kill(0, $pid) && $timeout > 0) {
    sleep $sleep;
    $timeout -= $sleep;
  }

  !kill(0, $pid);
}

#-------------------------------------------------------------------------------
# Attempts to atomically acquire the run lock. Once held, the pid file is created
# if needed, the current process' pid is written to it.
#
# If the lock is acquired, a L<Guard> object is returned that will release the
# lock once out of scope. Returns undef otherwise.
#
# This method is I<not> used to determine if there is an existing process
# running. It is I<only> used to safely manage the pid file while running.
# service() should instead be used for coordinated launch of a service.
#-------------------------------------------------------------------------------
sub run_lock {
  my $self = shift;
  return if $self->is_running;

  my $locked = $self->_lock;

  if ($locked) {
    # Write pid to the pidfile
    my $file = path($self->pid_file);
    $file->spew("$$\n");

    # Create guard object that releases the pidfile once out of scope
    return guard {
      $file->append({truncate => 1})
        if $self->is_running;
    };
  }

  return;
}

#-------------------------------------------------------------------------------
# Creates a .lock file based on $self->pid_file. While the file exists, the
# lock is considered to be held. Returns a Guard that removes the file.
#-------------------------------------------------------------------------------
sub _lock {
  my $self = shift;

  # Existing .lock file means another process came in ahead
  my $lock = path($self->lock_file);
  return if $lock->exists;

  my $locked = try {
      $lock->filehandle({exclusive => 1}, '>');
    }
    catch {
      # Rethrow if error was something other than the file already existing.
      # Assume any 'sysopen' error matching 'File exists' is an indication
      # of that.
      die $_
        unless $_->{op} eq 'sysopen' && $_->{err} =~ /File exists/i
            || $lock->exists;
    };

  return unless $locked;
  return guard { $self->_unlock if $self->is_running };
}

#-------------------------------------------------------------------------------
# Removes the .lock file.
#-------------------------------------------------------------------------------
sub _unlock {
  my $self = shift;
  try { path($self->lock_file)->remove }
  catch { carp "unable to remove lock file: $_" }
}

1;
