package Proc::tored::Machine;

use strict;
use warnings;
use Auto::Mata;
use Carp;
use Proc::tored::Flag;
use Proc::tored::Types qw(SignalList);
use Time::HiRes qw(sleep);
use Type::Utils qw(declare as where);
use Types::Standard qw(InstanceOf Dict Bool CodeRef);

use constant READY     => 'READY';
use constant PAUSED    => 'PAUSED';
use constant STOPPED   => 'STOPPED';
use constant SIGNALLED => 'SIGNALLED';
use constant RUNNING   => 'RUNNING';
use constant TERM      => 'TERM';

my $Flag = declare 'Flag', as InstanceOf['Proc::tored::Flag'];

my $Proctor = declare 'Proctor', as Dict[
  stopped  => $Flag,
  paused   => $Flag,
  traps    => SignalList,
  signalled => Bool,
  call     => CodeRef,
];

my $Stopped   = declare 'Stopped',   as $Proctor, where { $_->{stopped}->is_set };
my $Paused    = declare 'Paused',    as $Proctor, where { $_->{paused}->is_set };
my $Signalled = declare 'Signalled', as $Proctor, where { $_->{signalled} };
my $Running   = declare 'Running',   as ~$Paused & ~$Stopped & ~$Signalled;

sub new {
  my ($class, %param) = @_;
  my $stop  = $param{stop}  // croak 'expected parameter "stop"';
  my $pause = $param{pause} // croak 'expected parameter "pause"';
  my $traps = $param{traps};

  my $self = bless {
    stop    => Proc::tored::Flag->new(touch_file_path => $stop),
    pause   => Proc::tored::Flag->new(touch_file_path => $pause),
    traps   => $traps // [],
    machine => builder(),
  };

  bless $self, $class;
}

sub stop       { $_[0]->{stop}->set }
sub start      { $_[0]->{stop}->unset }
sub is_stopped { $_[0]->{stop}->is_set }
sub pause      { $_[0]->{pause}->set }
sub resume     { $_[0]->{pause}->unset }
sub is_paused  { $_[0]->{pause}->is_set }

sub clear_flags {
  my $self = shift;
  $self->start;
  $self->resume;
}

sub builder {
  machine {
    ready    READY;
    terminal TERM;

    transition READY, to PAUSED,    on $Paused;
    transition READY, to SIGNALLED, on $Signalled;
    transition READY, to STOPPED,   on $Stopped;
    transition READY, to RUNNING,   on $Running, with {
      my $me = $_;
      $SIG{$_} = sub { $me->{signalled} = 1 } foreach @{$me->{traps}};
      $_;
    };

    transition PAUSED, to RUNNING,   on ~$Paused;
    transition PAUSED, to SIGNALLED, on $Signalled;
    transition PAUSED, to STOPPED,   on $Stopped;
    transition PAUSED, to PAUSED,    on $Paused, with {
      sleep 0.2;
      $_;
    };

    transition RUNNING, to PAUSED,    on $Paused;
    transition RUNNING, to SIGNALLED, on $Signalled;
    transition RUNNING, to STOPPED,   on $Stopped;
    transition RUNNING, to RUNNING,   on $Running, with {
      unless ($_->{call}->()) {
        $_->{signalled} = 1;
      }

      $_;
    };

    transition SIGNALLED, to STOPPED, on $Signalled;

    transition STOPPED, to TERM, with {
      my $me = $_;
      undef $SIG{$_} foreach @{$me->{traps}};
      $_;
    };
  };
}

sub service {
  my ($self, $code) = @_;

  my $state = {
    stopped   => $self->{stop},
    paused    => $self->{pause},
    traps     => $self->{traps},
    call      => $code,
    signalled => 0,
  };

  my $fsm = $self->{machine}->();
  sub { $fsm->($state) };
};

1;
