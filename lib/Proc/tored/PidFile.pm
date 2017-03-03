package Proc::tored::PidFile;

use warnings;
use strict;
use Carp;
use Fcntl qw(:flock :seek :DEFAULT);
use Guard qw(guard);
use Path::Tiny qw(path);
use Time::HiRes qw(sleep);
use Try::Tiny;

sub new {
  my ($class, $file_path) = @_;
  bless { file => path($file_path) }, $class;
}

sub is_running {
  my $self = shift;
  $self->running_pid == $$;
}

sub running_pid {
  my $self = shift;
  my $pid = $self->read_file;
  return 0 unless $pid;
  return $pid if kill 0, $pid;
  return 0;
}

sub read_file {
  my $self = shift;
  return 0 unless $self->{file}->is_file;
  my ($line) = $self->{file}->lines({count => 1, chomp => 1}) or return 0;
  my ($pid) = $line =~ /^(\d+)$/;
  return $pid || 0;
}

sub write_file {
  my $self = shift;
  my $lock = $self->write_lock or return 0;
  return 0 if $self->running_pid;
  $self->{file}->spew("$$\n");
  return 1;
}

sub clear_file {
  my $self = shift;
  my $lock = $self->write_lock or return;
  return unless $self->is_running;
  $self->{file}->append({truncate => 1});
  try { $self->{file}->remove }
  catch { warn "error unlinking pid file: $_" }
}

sub lock {
  my $self = shift;
  return guard { $self->clear_file } if $self->write_file;
  return;
}

#-------------------------------------------------------------------------------
# Creates a .lock file based on $self->pid_file. While the file exists, the
# lock is considered to be held. Returns a Guard that removes the file.
#-------------------------------------------------------------------------------
sub write_lock {
  my $self = shift;

  # Existing .lock file means another process came in ahead
  my $lock = path("$self->{file}.lock");
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
