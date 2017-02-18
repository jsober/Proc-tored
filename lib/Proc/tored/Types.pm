package Proc::tored::Types;
# ABSTRACT: Type constraints used by Proc::tored

use strict;
use warnings;
use Proc::tored::Pool::Constants ':events';
use Types::Standard -types;
use Type::Utils -all;
use Type::Library -base,
  -declare => qw(
    NonEmptyStr
    Dir
  );

=head1 TYPES

=head2 NonEmptyStr

A C<Str> that contains at least one non-whitespace character.

=head2 Dir

A L</NonEmptyStr> that is a valid directory path.

=cut

declare NonEmptyStr, as Str, where { $_ =~ /\S/ };
declare Dir, as NonEmptyStr, where { -d $_ };

1;
