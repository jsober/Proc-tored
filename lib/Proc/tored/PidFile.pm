package Proc::tored::PidFile;

use warnings;
use strict;
use Moo;
use Carp;
use Fcntl qw(:flock :seek :DEFAULT);
use Guard qw(guard);
use Path::Tiny qw(path);
use Time::HiRes qw(sleep);
use Types::Standard qw(InstanceOf);
use Try::Tiny;
use Proc::tored::Types -types;

has file_path => (
  is  => 'ro',
  isa => NonEmptyStr,
);

has file => (
  is  => 'lazy',
  isa => InstanceOf['Path::Tiny'],
);

sub _build_file { path(shift->file_path) }

sub is_running {
  my $self = shift;
  $self->running_pid == $$;
}

sub running_pid {
  my $self = shift;
  my $pid = $self->read_pid;
  return 0 unless $pid;
  return $pid if kill 0, $pid;
  return 0;
}

sub wait {
  my ($self, $timeout, $sleep) = @_;
  $sleep ||= 0.2;

  return if $self->is_running;

  my $pid = $self->running_pid || return 0;

  while (kill(0, $pid) && $timeout > 0) {
    sleep $sleep;
    $timeout -= $sleep;
  }

  !kill(0, $pid);
}

sub read_pid {
  my $self = shift;
  return 0 unless $self->file->is_file;
  my ($line) = $self->file->lines({count => 1, chomp => 1}) or return 0;
  my ($pid) = $line =~ /^(\d+)$/;
  return $pid || 0;
}

sub write_pid {
  my $self = shift;
  my $lock = $self->lock or return 0;
  return 0 if $self->running_pid;
  $self->file->spew("$$\n");
  return guard { $self->clear_pid };
}

sub clear_pid {
  my $self = shift;
  my $lock = $self->lock or return;
  return unless $self->is_running;
  $self->file->append({truncate => 1});
  try { $self->file->remove }
  catch { warn "error unlinking pid file: $_" }
}

#-------------------------------------------------------------------------------
# Creates a .lock file based on $self->pid_file. While the file exists, the
# lock is considered to be held. Returns a Guard that removes the file.
#-------------------------------------------------------------------------------
sub lock {
  my $self = shift;

  # Existing .lock file means another process came in ahead
  my $lock = path($self->file_path . '.lock');
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

  return guard {
    try { $lock->remove }
    catch { carp "unable to remove lock file: $_" }
  };
}

1;
