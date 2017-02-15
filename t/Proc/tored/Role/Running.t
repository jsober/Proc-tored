package Runner;
use Moo;
with 'Proc::tored::Role::Running';
1;

package main;
use Test2::Bundle::Extended;
use Proc::tored::Role::Running;

bail_out('OS unsupported') if $^O eq 'MSWin32';

subtest 'basics' => sub {
  my $sigterm_handler = $SIG{TERM};
  ok my $runner = Runner->new, 'new';
  ok !$runner->is_running, 'is_running post new';
  ok $runner->start, 'start';
  ok $runner->is_running, 'is_running post start';
  ok $SIG{TERM}, 'SIGTERM handler installed';
  isnt $sigterm_handler, $SIG{TERM}, 'SIGTERM handler installed is new';
  ok $runner->stop, 'stop';
  ok !$runner->is_running, 'is_running post stop';
  is $SIG{TERM} || undef, $sigterm_handler, 'SIGTERM handler removed';
};

subtest 'sigterm' => sub {
  my $sigterm_handler = $SIG{TERM};
  my $runner = Runner->new;
  $runner->start;
  kill 'SIGTERM', $$;
  ok !$runner->is_running, 'is_running post sigterm';
  is $SIG{TERM} || undef, $sigterm_handler, 'SIGTERM handler removed';
};

done_testing;
