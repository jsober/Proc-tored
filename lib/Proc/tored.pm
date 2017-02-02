use strict;
use warnings;

package Proc::tored;
# ABSTRACT: Manage a process with its pid file

=head1 SYNOPSIS

  my $proctor = Proc::tored->new(dir => '/tmp', name => 'my-service');

  # Call do_stuff while the service is running or until do_stuff returns false
  $proctor->service(\&do_stuff)
    or die sprintf('process %d is already running this service!', $proctor->running_pid);

  # Signal another process running this service to quit gracefully, throwing an
  # error if it does not self-terminate after 15 seconds.
  if (my $pid = $proctor->stop_running_process(15)) {
    die "process $pid is being stubborn!";
  }

=cut

use Moo;
use Carp;
use Guard qw(guard);
use Fcntl qw(:flock :seek :DEFAULT);
use Time::HiRes qw(sleep);
use Types::Standard qw(Str Bool Num is_CodeRef);
use Type::Utils qw(declare as where);

my $NonEmptyStr = declare, as Str, where { $_ =~ /\S/ };
my $Directory = declare, as $NonEmptyStr, where { -d $_ };

=head1 METHODS

=head2 new

Creates a new service object, which can be used to run the service and/or
signal another process to quit. The pid file is not created or accessed by this
method.

=over

=item dir

A valid directory path where the pid file is to be created or an existing pid
file is to be found.

=item name

The file name to be used when creating or accessing the service's associated
pid file.

=item poll_wait_time

Optionally pecifies the length of time (in fractional seconds) during which the
process will sleep when calling L</stop_running_service> with a C<timeout>.
Defaults to 0.2 seconds.

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

has poll_wait_time => (
  is  => 'ro',
  isa => Num,
  default => 0.2,
);

=head2 path

Returns the file system path created by concatenating the values of C<dir> and
C<name> that were passed to C<new>.

=cut

has path => (
  is  => 'lazy',
  isa => $NonEmptyStr,
  init_arg => undef,
);

sub _build_path {
  my $self = shift;
  join '/', $self->dir, $self->name;
}

=head2 is_running

Returns true while the service is running in the current process.

=cut

has is_running => (
  is  => 'ro',
  isa => Bool,
  default => 0,
  init_arg => undef,
);

=head2 service

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

=cut

sub running_pid {
  my $self = shift;
  my $path = $self->path;
  return 0 unless -f $path;

  sysopen my $fh, $path, O_RDONLY or croak "error opening $path: $!";
  flock $fh, LOCK_SH;

  if (defined(my $line = <$fh>)) {
    flock $fh, LOCK_UN;
    close $fh;

    chomp $line;
    my ($pid) = $line =~ /^(\d+)$/;

    return $pid || 0;
  }

  return 0;
}

=head2 stop_running_process

=cut

sub stop_running_process {
  my ($self, $timeout) = @_;
  my $sleep = $self->poll_wait_time;
  my $pid = $self->running_pid or return 0;

  if (kill('SIGTERM', $pid) > 0) {
    if ($timeout) {
      while (kill(0, $pid) > 0 && $timeout > 0) {
        sleep $sleep;
        $timeout -= $sleep;
      }
    }
  }

  kill(0, $pid) == 0 ? $pid : 0;
}

=head2 run_lock

=cut

sub run_lock {
  my $self = shift;
  my $path = $self->path;

  sysopen my $fh, $path, O_WRONLY|O_CREAT or croak "error opening $path: $!";

  # If another process has an exclusive lock, it should be considered to have
  # the run lock as well.
  unless (flock $fh, LOCK_EX|LOCK_NB) {
    close $fh;
    return;
  }

  # Write pid to pidfile with autoflush on so it will be immediately available
  # to other processes.
  do {
    truncate $fh, 0;       # clear pidfile contents
    seek $fh, 0, SEEK_SET; # return to beginning of the file
    local $| = 1;
    print $fh "$$\n" or die "error writing to pidfile: $!";
  };

  # Switch to shared lock
  flock $fh, LOCK_SH;

  # Mark service as running
  $self->{is_running} = 1;

  # Create guard object that releases the pidfile once out of scope
  my $guard = guard {
    $self->{is_running} = 0;
    flock $fh, LOCK_EX; # switch to exclusive lock for writing
    truncate $fh, 0;    # clear pidfile contents
    flock $fh, LOCK_UN; # unlock
    close $fh;          # close
  };

  # Set up sigterm handler
  my $sigterm_handler = $SIG{TERM};

  $SIG{TERM} = sub {
    $self->{is_running} = 0;
    $sigterm_handler->(@_) if $sigterm_handler;
  };

  return $guard;
}

1;
