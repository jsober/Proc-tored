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
use Types::Standard qw(Str InstanceOf Dict Bool CodeRef);

use constant READY   => 'READY';
use constant STATUS  => 'STATUS';
use constant PAUSED  => 'PAUSED';
use constant STOPPED => 'STOPPED';
use constant START   => 'START';
use constant RUNNING => 'RUNNING';
use constant FINISH  => 'FINISH';
use constant TERM    => 'TERM';

my $Flag = declare 'Flag', as Str;

my $Proctor = declare 'Proctor', as Dict[
  traps   => SignalList, # list of signals to trap
  stopped => $Flag,      # stop file flag
  paused  => $Flag,      # pause file flag
  stop    => Bool,       # true when instructed to stop
  init    => Bool,       # true when initialized and ready to run
  call    => CodeRef,    # code ref to call while running
  result  => Bool,       # result of last call to code ref
];

my $Stopped  = declare 'Stopped',  as $Proctor, where { -e $_->{stopped} || $_->{stop} };
my $Paused   = declare 'Paused',   as $Proctor, where { -e $_->{paused} };
my $MayRun   = declare 'MayRun',   as ~$Paused & ~$Stopped;
my $PreInit  = declare 'PreInit',  as $MayRun,  where { !$_->{init} };
my $Init     = declare 'Init',     as $MayRun,  where { $_->{init} };
my $Running  = declare 'Running',  as $Init,    where { $_->{result} };
my $Finished = declare 'Finished', as $Init,    where { !$_->{result} };

my $FSM = machine {
  ready    READY;
  terminal TERM;

  transition READY, to STATUS;

  transition STATUS, to PAUSED,  on $Paused;
  transition STATUS, to STOPPED, on $Stopped;
  transition STATUS, to START,   on $PreInit;
  transition STATUS, to RUNNING, on $Running;
  transition STATUS, to FINISH,  on $Finished;

  transition START, to RUNNING, on $PreInit, with {
    my $me = $_;
    $SIG{$_} = sub { $me->{stop} = 1 } foreach @{$me->{traps}};
    $_->{init} = 1;
    $_;
  };

  transition RUNNING, to STATUS, on $Proctor, with {
    $_->{result} = $_->{call}->() ? 1 : 0;
    $_;
  };

  transition FINISH, to STATUS, on $Proctor, with { $_->{stop} = 1; $_ };

  transition PAUSED, to STATUS, on $Paused, with {
    sleep 0.2;
    $_;
  };

  transition STOPPED, to TERM, with {
    undef $SIG{$_} foreach @{$_->{traps}};
    $_->{init} = 0;
    $_;
  };
};

sub new {
  my ($class, %param) = @_;
  my $stop  = $param{stop}  // croak 'expected parameter "stop"';
  my $pause = $param{pause} // croak 'expected parameter "pause"';
  my $traps = $param{traps};

  my $self = bless {
    stop       => $stop,
    pause      => $pause,
    stop_flag  => Proc::tored::Flag->new(touch_file_path => $stop),
    pause_flag => Proc::tored::Flag->new(touch_file_path => $pause),
    traps      => $traps // [],
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
    stopped => $self->{stop},
    paused  => $self->{pause},
    traps   => $self->{traps},
    call    => $code,
    init    => 0,
    stop    => 0,
    result  => 0,
  };

  my $fsm = $FSM->();
  sub { $fsm->($state) };
};

1;
