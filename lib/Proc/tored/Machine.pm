package Proc::tored::Machine;

use strict;
use warnings;
use Moo;
use Carp;
use Auto::Mata '!with';
use Proc::tored::Flag;
use Proc::tored::PidFile;
use Proc::tored::Types qw(SignalList);
use Time::HiRes qw(sleep);
use Type::Utils qw(declare as where);
use Types::Standard -types;

use constant READY  => 'READY';
use constant STATUS => 'STATUS';
use constant PAUSE  => 'PAUSE';
use constant STOP   => 'STOP';
use constant LOCK   => 'LOCK';
use constant RUN    => 'RUN';
use constant TERM   => 'TERM';

my $Lock    = InstanceOf['Guard'];
my $Flag    = InstanceOf['Proc::tored::Flag'];
my $PidFile = InstanceOf['Proc::tored::PidFile'];

my $Proctor = declare 'Proctor', as Dict[
  pidfile => $PidFile, # PidFile
  stopped => $Flag,    # Stop Flag
  paused  => $Flag,    # Pause Flag

  lock    => Bool,
  locked  => Maybe[$Lock],

  traps   => SignalList,   # list of signals to trap
  stop    => Bool,         # true when instructed to stop
  init    => Bool,         # true when initialized and ready to run
  call    => CodeRef,      # code ref to call while running
  finish  => Bool,         # true when last callback returned false
];

my $Stopped    = declare 'Stopped',    as $Proctor, where { $_->{stopped}->is_set || $_->{stop} };
my $NotStopped = declare 'NotStopped', as $Proctor & ~$Stopped;
my $Paused     = declare 'Paused',     as $Proctor, where { $_->{paused}->is_set };
my $NotPaused  = declare 'NotPaused',  as $Proctor & ~$Paused;
my $MayRun     = declare 'MayRun',     as $NotStopped & $NotPaused;
my $Unlocked   = declare 'Unlocked',   as $MayRun,  where { !$_->{lock} };
my $Locked     = declare 'Locked',     as $MayRun,  where { $_->{lock} && $_->{locked} };
my $LockFail   = declare 'LockFail',   as $MayRun,  where { $_->{lock} && !$_->{locked} };
my $Started    = declare 'Started',    as $Locked,  where { $_->{init} };
my $Running    = declare 'Running',    as $Started, where { !$_->{finish} };
my $Finished   = declare 'Finished',   as $Proctor, where { $_->{finish} };
my $Unfinished = declare 'Unfinished', as $Proctor, where { !$_->{finish} };

my $FSM = machine {
  ready READY;
  term  TERM;

  transition READY, to STATUS;

  # Initialization loop: STATUS -> LOCK -> STATUS|TERM
  # Attempts to acquire run lock using the pid file. If successful, sets up any
  # signal trapping requested and returns to STATUS. Otherwise, sets the
  # failure message and proceeds to TERM.
  transition STATUS, to LOCK, on $Unlocked, using {
    $_->{lock}   = 1;
    $_->{locked} = $_->{pidfile}->lock;
    $_;
  };

  transition LOCK, to STATUS, on $Locked, using {
    my $me = $_;

    foreach my $signal (@{$me->{traps}}) {
      $SIG{$signal} = sub {
        $me->{stop} = 1;
      };
    }

    $_->{init} = 1;
    $_;
  };

  transition LOCK, to TERM, on $LockFail;

  # Service loop: STATUS -> RUN -> STATUS|TERM
  # Calls the caller-supplied callback (I call that statement redundant) and
  # sets the 'finish' flag to true if the callback returns false. If 'finish'
  # is true, sets the completion message and proceeds to TERM. Otherwise,
  # returns to STATUS.
  transition STATUS, to RUN, on $Running, using {
    $_->{finish} = $_->{call}->() ? 0 : 1;
    $_;
  };

  transition RUN, to STATUS, on $Unfinished;
  transition RUN, to TERM, on $Finished;

  # Pause loop: STATUS -> PAUSE -> STATUS
  transition STATUS, to PAUSE, on $Paused;

  transition PAUSE, to STATUS, on $Paused, using {
    sleep 0.2;
    $_;
  };

  # Stop loop: STATUS -> STOP -> STATUS|TERM
  transition STATUS, to STOP, on $Stopped;

  transition STOP, to TERM, using {
    undef $SIG{$_} foreach @{$_->{traps}};
    $_->{init} = 0;
    $_;
  };
};

has pidfile_path => (is => 'ro', isa => Str, required => 1);
has stop_path    => (is => 'ro', isa => Str, required => 1);
has pause_path   => (is => 'ro', isa => Str, required => 1);
has traps        => (is => 'ro', isa => SignalList, default => sub {[]});

has pidfile => (
  is  => 'lazy',
  isa => $PidFile,
  handles => {
    read_pid    => 'read_file',
    running_pid => 'running_pid',
    is_running  => 'is_running',
  },
);

has stop_flag => (
  is  => 'lazy',
  isa => $Flag,
  handles => {
    stop       => 'set',
    start      => 'unset',
    is_stopped => 'is_set',
  },
);

has pause_flag => (
  is  => 'lazy',
  isa => $Flag,
  handles => {
    pause     => 'set',
    resume    => 'unset',
    is_paused => 'is_set',
  },
);

sub _build_pidfile { Proc::tored::PidFile->new(file_path => shift->pidfile_path) }
sub _build_stop_flag { Proc::tored::Flag->new(touch_file_path => shift->stop_path) }
sub _build_pause_flag { Proc::tored::Flag->new(touch_file_path => shift->pause_path) }

sub clear_flags {
  my $self = shift;
  $self->start;
  $self->resume;
}

sub run {
  my ($self, $code) = @_;

  my $acc = {
    pidfile => $self->pidfile,
    stopped => $self->stop_flag,
    paused  => $self->pause_flag,
    lock    => 0,
    locked  => undef,
    traps   => $self->traps,
    stop    => 0,
    init    => 0,
    call    => $code,
    finish  => 0,
  };

  my $service = $FSM->();

  $service->($acc);

  return $acc->{lock};
};

1;
