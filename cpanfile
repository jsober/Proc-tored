requires 'Carp'            => 0;
requires 'Fcntl'           => 0;
requires 'Time::HiRes'     => 0;
requires 'Guard'           => 0;
requires 'Moo'             => 0;
requires 'Moo::Role'       => 0;
requires 'Type::Tiny'      => 0;
requires 'Types::Standard' => 0;

on test => sub {
  requires 'File::Slurp' => 0;
  requires 'Test2::Bundle::Extended' => 0;
};