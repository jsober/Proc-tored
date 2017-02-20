package Proc::tored::Flag;
# ABSTRACT: Ties a runtime flag to the existence of a touch file

=head1 SYNOPSIS

  use Proc::tored::Flag;

  my $fnord = Proc::tored::Flag->new(touch_file_path => '/my/service/path');

  $fnord->set; # touch file created if not already there
  $fnord->is_set; # true

  $fnord->unset; # touch file removed if it exists
  $fnord->is_set; # false

  if ($fnord->is_set) {
    warn "forgot what to do";
    exit 1;
  }

=cut

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
