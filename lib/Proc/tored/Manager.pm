package Proc::tored::Manager;
# ABSTRACT: OO interface to creating a proctored service

=head1 SYNOPSIS

  my $proctor = Proc::tored::Manager->new(dir => '/tmp', name => 'my-service');

  # Call do_stuff while the service is running or until do_stuff returns false
  $proctor->service(\&do_stuff)
    or die sprintf('process %d is already running this service!', $proctor->running_pid);

  # Signal another process running this service to quit gracefully, throwing an
  # error if it does not self-terminate after 15 seconds.
  if (my $pid = $proctor->stop_running_process(15)) {
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

=item name

The file name to be used when creating or accessing the service's associated
pid file.

=item dir

A valid directory path where the pid file is to be created or an existing pid
file is to be found.

=item lock_file

Before writing the pid file, a lock is secured through the atomic creation of a
lock file. If the file fails to be created (with O_EXCL), the lock fails.

=cut

=item pid_file

Unless manually specified, the pid file's C<pid_file> is constructed from
L</name> in L</dir>.

=back

=cut

has dir => (
  is  => 'ro',
  isa => Dir,
  required => 1,
);

has name => (
  is  => 'ro',
  isa => NonEmptyStr,
  required => 1,
);

has pid_file => (
  is  => 'lazy',
  isa => NonEmptyStr,
);

sub _build_pid_file {
  my $self = shift;
  my $file = path($self->dir)->child($self->name . '.pid');
  return "$file";
}

has lock_file => (
  is  => 'lazy',
  isa => NonEmptyStr,
);

sub _build_lock_file {
  my $self = shift;
  my $file = path($self->dir)->child($self->name . '.lock');
  return "$file";
}

has term_flag => (
  is  => 'lazy',
  isa => InstanceOf['Proc::tored::Flag'],
  handles => {
    stop => 'unset',
    start => 'set',
    signal => 'signal',
    is_running => 'is_set',
  },
);

sub _build_term_flag {
  my $self = shift;
  my $file = path($self->dir)->child($self->name . '.term');
  Proc::tored::Flag->new(touch_file_path => "$file");
}

=head2 is_running

Returns true if the service has been started and the touch file used to signal
the process to self-terminate does not exist.

=cut

has pause_flag => (
  is  => 'lazy',
  isa => InstanceOf['Proc::tored::Flag'],
  handles => {
    halt => 'unset',
    resume => 'set',
    pause => 'signal',
  },
);

sub _build_pause_flag {
  my $self = shift;
  my $file = path($self->dir)->child($self->name . '.paused');
  my $flag = Proc::tored::Flag->new(touch_file_path => "$file");
  return $flag;
}

=head2 is_paused

Returns true if the service has been paused.

=cut

sub is_paused { !$_[0]->pause_flag->is_set }

=head2 service

Accepts a code ref which will be called repeatedly until it or L</is_running>
return false.

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
  die 'expected a CODE ref' unless is_CodeRef($code);

  if (my $guard = $self->run_lock) {
    while (1) {
      last unless $self->is_running;

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

=head2 stop_running_process

Signals a running instance to self-terminate. Returns 0 immediately if the pid
file does not exist or is empty. Otherwise, polls the running process until the
OS reports that it is no longer able to receive signals (with `kill(0, $pid)`).

Optional parameter C<$timeout> may be specified in fractional seconds, causing
C<stop_running_process> to block up to (around) C<$timeout> seconds waiting for
the signaled process to exit. Optional parameter C<$sleep> specifies the
interval between polls in fractional seconds.

Returns the pid of the completed process otherwise.

  $service->stop_running_process; # signal running process and return
  $service->stop_running_process(10, 0.5); # signal, then poll every 0.5s for 10s

=cut

sub stop_running_process {
  my ($self, $timeout, $sleep) = @_;
  $sleep ||= 0.2;

  my $pid = $self->running_pid || return 0;
  return $self->stop if $pid == $$;

  if ($self->signal) {
    if ($timeout) {
      while (kill(0, $pid) && $timeout > 0) {
        sleep $sleep;
        $timeout -= $sleep;
      }
    }
  }

  !kill(0, $pid);
}

=head2 run_lock

Attempts to atomically acquire the run lock. Once held, the pid file is created
(if needed) and the current process' pid is written to it, L</is_running> will
return true and a signal handlers will be active. Existing handlers will be
executed after the one assigned for the run lock.

If the lock is acquired, a L<Guard> object is returned that will release the
lock once out of scope. Returns undef otherwise.

L</service> is preferred to this method for most uses.

=cut

sub run_lock {
  my $self = shift;
  return if $self->running_pid;
  my $pid = $$;
  my $locked = $self->_lock;

  if ($locked) {
    # Write pid to the pidfile
    my $file = path($self->pid_file);
    $file->spew("$pid\n");
    $self->start;
    $self->resume;

    # Create guard object that releases the pidfile once out of scope
    return guard {
      if ($$ == $pid) {
        $self->stop;
        $file->append({truncate => 1});
      }
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
  my $pid = $$;

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
  return guard { $self->_unlock if $$ == $pid };
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
