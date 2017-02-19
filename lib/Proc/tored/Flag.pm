package Proc::tored::Flag;
# ABSTRACT: thing

use strict;
use warnings;
use Moo;
use Carp;
use Path::Tiny 'path';
use Types::Standard -types;

has touch_file_path => (
  is  => 'ro',
  isa => Str,
  required => 1,
);

has file => (
  is  => 'lazy',
  isa => InstanceOf['Path::Tiny'],
);

sub _build_file { path($_[0]->touch_file_path) }

has is_set => (
  is  => 'ro',
  isa => Bool,
  default => 0,
);

before is_set => sub { $_[0]->file->exists ? $_[0]->set : $_[0]->unset };

sub is_not_set {
  my $self = shift;
  return !$self->is_set;
}

sub set {
  my $self = shift;
  $self->file->touch;
  $self->{is_set} = 1;
  return 1;
}

sub unset {
  my $self = shift;
  $self->file->remove;
  $self->{is_set} = 0;
  return 1;
}

1;
