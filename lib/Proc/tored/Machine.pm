package Proc::tored::Machine;

use strict;
use warnings;
use Auto::Mata;
use Carp;
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

my $Lock = InstanceOf['Guard'];

my $Proctor = declare 'Proctor', as Dict[
  pidfile => Str,          # pid file path
  stopped => Str,          # stop file path
  paused  => Str,          # pause file path

  lock    => Bool,
  locked  => Maybe[$Lock],

  traps   => SignalList,   # list of signals to trap
  stop    => Bool,         # true when instructed to stop
  init    => Bool,         # true when initialized and ready to run
  call    => CodeRef,      # code ref to call while running
  finish  => Bool,         # true when last callback returned false
  msg     => Maybe[Str],   # message explaining why the service terminated
];

my $Stopped    = declare 'Stopped',    as $Proctor, where { -e $_->{stopped} || $_->{stop} };
my $NotStopped = declare 'NotStopped', as $Proctor & ~$Stopped;
my $Paused     = declare 'Paused',     as $Proctor, where { -e $_->{paused} };
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
  ready    READY;
  terminal TERM;

  transition READY, to STATUS;

  # Initialization loop: STATUS -> LOCK -> STATUS|TERM
  # Attempts to acquire run lock using the pid file. If successful, sets up any
  # signal trapping requested and returns to STATUS. Otherwise, sets the
  # failure message and proceeds to TERM.
  transition STATUS, to LOCK, on $Unlocked, with {
    $_->{lock}   = 1;
    $_->{locked} = Proc::tored::PidFile->new($_->{pidfile})->lock;
    $_;
  };

  transition LOCK, to STATUS, on $Locked, with {
    my $me = $_;

    foreach my $signal (@{$me->{traps}}) {
      $SIG{$signal} = sub {
        $me->{stop} = 1;
        $me->{msg}  = "Received $signal";
      };
    }

    $_->{init} = 1;
    $_;
  };

  transition LOCK, to TERM, on $LockFail, with {
    my $pid = Proc::tored::PidFile->new($_->{pidfile})->read_file;
    $_->{msg} = sprintf 'Another process is already running with pid %d', $pid;
  };

  # Service loop: STATUS -> RUN -> STATUS|TERM
  # Calls the caller-supplied callback (I call that statement redundant) and
  # sets the 'finish' flag to true if the callback returns false. If 'finish'
  # is true, sets the completion message and proceeds to TERM. Otherwise,
  # returns to STATUS.
  transition STATUS, to RUN, on $Running, with {
    $_->{finish} = $_->{call}->() ? 0 : 1;
    $_;
  };

  transition RUN, to STATUS, on $Unfinished;

  transition RUN, to TERM, on $Finished, with {
    $_->{msg} = 'Work complete';
    $_;
  };

  # Pause loop: STATUS -> PAUSE -> STATUS
  transition STATUS, to PAUSE, on $Paused;

  transition PAUSE, to STATUS, on $Paused, with {
    sleep 0.2;
    $_;
  };

  # Stop loop: STATUS -> STOP -> STATUS|TERM
  transition STATUS, to STOP, on $Stopped;

  transition STOP, to TERM, with {
    undef $SIG{$_} foreach @{$_->{traps}};
    $_->{init} = 0;
    $_;
  };
};

sub new {
  my ($class, %param) = @_;
  my $pidfile = $param{pidfile} || croak 'expected parameter "pidfile"';
  my $stop    = $param{stop}    || croak 'expected parameter "stop"';
  my $pause   = $param{pause}   || croak 'expected parameter "pause"';
  my $traps   = $param{traps}   || [];

  my $self = bless {
    stop       => $stop,
    pause      => $pause,
    pidfile    => $pidfile,
    stop_flag  => Proc::tored::Flag->new(touch_file_path => $stop),
    pause_flag => Proc::tored::Flag->new(touch_file_path => $pause),
    traps      => $traps,
  };

  bless $self, $class;
}

sub stop       { $_[0]->{stop_flag}->set }
sub start      { $_[0]->{stop_flag}->unset }
sub is_stopped { $_[0]->{stop_flag}->is_set }
sub pause      { $_[0]->{pause_flag}->set }
sub resume     { $_[0]->{pause_flag}->unset }
sub is_paused  { $_[0]->{pause_flag}->is_set }

sub clear_flags {
  my $self = shift;
  $self->start;
  $self->resume;
}

sub service {
  my ($self, $code) = @_;

  my $state = {
    pidfile => $self->{pidfile},
    stopped => $self->{stop},
    paused  => $self->{pause},
    lock    => 0,
    locked  => undef,
    traps   => $self->{traps},
    stop    => 0,
    init    => 0,
    call    => $code,
    finish  => 0,
    msg     => undef,
  };

  my $fsm = $FSM->();
  sub { $fsm->($state) };
};

1;
