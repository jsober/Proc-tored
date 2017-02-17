package Runner;
use Moo;
with 'Proc::tored::Role::Running';
1;

package main;
use Guard 'scope_guard';
use Test2::Bundle::Extended;
use Proc::tored::Role::Running;

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
  # Restore existing sigterm handlers after completing the subtest
  my $existing = $SIG{TERM};
  scope_guard { $SIG{TERM} = $existing };

  # Set sigterm handler that sets a flag for testing
  my $handled = 0;
  my $handler = $SIG{TERM} = sub { $handled = 1 };

  ok my $runner = Runner->new, 'new';
  ok $runner->start, 'start';

  isnt $SIG{TERM}, $handler, 'handler overridden post start';

  if ($^O eq 'MSWin32') {
    # Simulate a signal being received on mswin32+threads because only the parent
    # process receives signals (in this case, the parent is `prove`).
    $SIG{TERM}->();
  }
  else {
    kill 'TERM', $$;
  }

  ok !$runner->is_running, 'is_running post sigterm';
  ok $handled, 'overridden handler called on sigterm';
  is $SIG{TERM} || undef, $handler, 'overridden handler restored';
};

done_testing;
