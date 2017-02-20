package Proc::tored::Flag;
# ABSTRACT: thing

use strict;
use warnings;
use Moo;
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
  handles => {
    set    => 'touch',
    unset  => 'remove',
    is_set => 'exists',
  },
);

sub _build_file { path($_[0]->touch_file_path) }

1;
