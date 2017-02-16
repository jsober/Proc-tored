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
use Guard qw(guard scope_guard);
use Path::Tiny qw(path);
use Time::HiRes qw(sleep);
use Try::Tiny;
use Type::Utils qw(declare as where);
use Types::Standard qw(Str Bool Num is_CodeRef);

my $NonEmptyStr = declare, as Str, where { $_ =~ /\S/ };
my $Directory = declare, as $NonEmptyStr, where { -d $_ };

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
  sprintf '%s/%s.pid', $self->dir, $self->name;
}

=head2 is_running

See L<Proc::tored::Role::Running/is_running>.

=cut

=head2 service

Accepts a code ref which will be called repeatedly until it or L</is_running>
return false. While the service is running, handlers for C<SIGTERM>, C<SIGINT>,
C<SIGPIPE>, and C<SIGHUP> are installed. When one of these signals are
received, L</is_running> will be set to false and service loop will
self-terminate.

Note that it is possible for a signal to arrive between the L</is_running>
check and the execution of the code ref. If this is a concern for the caller,
it is recommended that the code ref avoid blocking for long periods, such as
extended C<sleep> times or long-running database queries which perl cannot
interrupt.

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

=head2 running_pid

Returns the pid identified in the pid file. Returns 0 if the pid file does
not exist or is empty.

=cut

sub running_pid {
  my $self = shift;
  my $file = path($self->filepath);
  return 0 unless $file->is_file;
  my ($line) = $file->lines({count => 1, chomp => 1}) or return 0;
  my ($pid) = $line =~ /^(\d+)$/;
  return $pid || 0;
}

=head2 stop_running_process

See L<Proc::tored::Role::Running/stop_running_process>. When called from this
class, the C<$pid> parameter is provided via L</running_pid>.

=cut

around stop_running_process => sub {
  my $orig = shift;
  my $self = shift;
  my $pid  = $self->running_pid or return 0;
  return $self->$orig($pid, @_);
};

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
  my $pid = $self->running_pid;
  $pid && kill(0, $pid) && return; # pid points to running process

  # existing .lock file means another process came in ahead
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

  # remove the lock file when out of scope
  scope_guard { $lock->remove };

  # write pid to the pidfile
  my $file = path($self->filepath);
  $file->spew("$$\n");

  $self->start;

  # Create guard object that releases the pidfile once out of scope
  return guard {
    $self->stop;
    $file->append({truncate => 1});
  };
}

1;
