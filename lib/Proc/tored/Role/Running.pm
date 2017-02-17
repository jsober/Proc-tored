package Proc::tored::Role::Running;
# ABSTRACT: add running state and signal handling to services

use strict;
use warnings;
use Moo::Role;
use Carp;
use Path::Tiny 'path';
use Types::Standard -types;

=head1 SYNOPSIS

  package Some::Thing;
  use Moo;

  with 'Proc::tored::Running';

  sub run {
    my $self = shift;

    $self->start;

    while ($self->is_running) {
      do_stuff(...);
    }
  }

=head1 DESCRIPTION

Classes consuming this role are provided with controls to L</start> and
L</stop> voluntarily through the use of a touch file to signal the process to
self-terminate.

=head1 ATTRIBUTES

=head2 term_file

Specifies a file path that will be used as a touch file to signal the process
to self-terminate.

=cut

has term_file => (
  is  => 'ro',
  isa => Maybe[Str],
  required => 1,
);

has _path => (
  is  => 'lazy',
  isa => InstanceOf['Path::Tiny'],
);

sub _build__path { path(shift->term_file) }

has is_started => (
  is  => 'ro',
  isa => Bool,
  default => 0,
);

=head1 METHODS

=head2 is_running

Returns true while the service is running in the current process.

=cut

sub is_running {
  my $self = shift;

  if ($self->_path->exists) {
    $self->{is_started} = 0;
    $self->_path->remove;
  }

  return $self->is_started;
}

=head2 start

Flags the current process as I<running>. After calling this method,
L</is_running> will return true.

=cut

sub start {
  my $self = shift;
  return if $self->is_running;
  $self->_path->remove;
  $self->{is_started} = 1;
  return 1;
}

=head2 stop

Flags the current process as I<not running> and restores any previously
configured signal handlers. Once this method has been called, L</is_running>
will return false.

=cut

sub stop { $_[0]->{is_started} = 0; return 1 }

=head2 signal

Signals the process to stop running. If L</term_file> is set, this is done by
creating a touch file. Otherwise, the caller is required to specify the pid of
the process being signalled.

=cut

sub signal { shift->_path->touch }

1;
