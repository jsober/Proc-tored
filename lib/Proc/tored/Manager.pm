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
use Type::Utils qw(declare as where);
use Types::Standard qw(Str Bool Num is_CodeRef);

my $NonEmptyStr = declare, as Str, where { $_ =~ /\S/ };
my $Directory = declare, as $NonEmptyStr, where { -d $_ && -w $_ };

with 'Proc::tored::Role::Running';

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

=item term_file

By default (and on supported platforms), posix signals are used to signal a
managed process to voluntarily self-terminate. On non-compliant systems (e.g.
MSWin32), a touch file is used instead. The path to this file is automatically
constructed from L</name> in L</dir> unless manually specified.

=item filepath

Unless manually specified, the pid file's C<filepath> is constructed from
L</name> in L</dir>.

=back

=cut

has dir => (
  is  => 'ro',
  isa => $Directory,
  required => 1,
);

has name => (
  is  => 'ro',
  isa => $NonEmptyStr,
  required => 1,
);

has '+term_file' => (
  is => 'lazy',
);

sub _build_term_file {
  my $self = shift;
  my $file = path($self->dir)->child($self->name . '.term');
  return "$file";
}

=head2 filepath

Returns the file system path created by concatenating the values of C<dir> and
C<name> that were passed to C<new>.

=cut

has filepath => (
  is  => 'lazy',
  isa => $NonEmptyStr,
  init_arg => undef,
);

sub _build_filepath {
  my $self = shift;
  my $file = path($self->dir)->child($self->name . '.pid');
  return "$file";
}

=head2 is_running

See L<Proc::tored::Role::Running/is_running>.

=cut

=head2 service

Accepts a code ref which will be called repeatedly until it or L</is_running>
return false.

Example using a pool of forked workers, an imaginary task queue, and a
secondary condition that decides whether to stop running (aside from the
built-in signal handlers):

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
    while ($self->is_running && $code->()) {
      ;
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
  my $file = path($self->filepath);
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

  if ($self->signal > 0) {
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

  my $file = path($self->filepath);

  # Write pid to the pidfile
  if ($self->with_lock(sub { $file->spew("$$\n") })) {
    $self->start;

    # Create guard object that releases the pidfile once out of scope
    return guard {
      $self->stop;
      $file->append({truncate => 1});
    };
  }

  return;
}

#-------------------------------------------------------------------------------
# Calls $code while holding the lock, unlocking afterward. Returns true when
# the lock is achieved and $code is called.
#-------------------------------------------------------------------------------
sub with_lock {
  my ($self, $code) = @_;
  my $lock = $self->_lock or return;
  $code->();
  undef $lock;
  return 1;
}

#-------------------------------------------------------------------------------
# Creates a .lock file based on $self->filepath. While the file exists, the
# lock is considered to be held. Returns a Guard that removes the file.
#-------------------------------------------------------------------------------
sub _lock {
  my $self = shift;

  # Existing .lock file means another process came in ahead
  my $lock = path($self->filepath . '.lock');
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
  return guard { $self->_unlock };
}

#-------------------------------------------------------------------------------
# Removes the .lock file.
#-------------------------------------------------------------------------------
sub _unlock {
  my $self = shift;
  my $lock = path($self->filepath . '.lock');
  try { $lock->remove }
  catch { carp "unable to remove lock file: $_" }
}

1;
