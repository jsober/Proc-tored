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

sub _build_file {
  my $self = shift;
  path($self->touch_file_path);
}

has flag => (
  is  => 'ro',
  isa => Bool,
  default => 0,
);

sub set {
  my $self = shift;
  $self->{flag} = 1;
  return 1;
}

sub unset {
  my $self = shift;
  $self->{flag} = 0;
  return 1;
}

sub is_set {
  my $self = shift;

  if ($self->file->exists) {
    $self->unset;
  }

  $self->flag;
}

sub clear {
  my $self = shift;
  $self->file->remove;
}

sub signal {
  my $self = shift;
  $self->file->touch;
}

1;
