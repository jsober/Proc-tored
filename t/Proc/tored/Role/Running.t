our $dir = Path::Tiny->tempdir('temp.XXXXXX', CLEANUP => 1, EXLOCK => 0);
my $term = $dir->child("$$.term");

package Runner;
use Moo;
with 'Proc::tored::Role::Running';
1;

package main;
use Guard 'scope_guard';
use Test2::Bundle::Extended;
use Proc::tored::Role::Running;
use Path::Tiny 'path';
use Time::HiRes 'sleep';

skip_all 'could not create writable temp directory' unless -w $dir;

subtest 'basics' => sub {
  ok my $runner = Runner->new, 'new';
  ok !$runner->is_running, '!is_running';
  ok $runner->start, 'start';
  ok $runner->is_running, 'is_running';
  ok $runner->stop, 'stop';
  ok !$runner->is_running, '!is_running';
};

subtest 'signals' => sub {
  subtest 'term_file' => sub {
    ok my $runner = Runner->new(term_file => "$term"), 'new';
    ok !$runner->is_running, '!is_running';
    ok $runner->start, 'start';
    ok $runner->is_running, 'is_running';
    ok $runner->signal, 'signal';
    sleep 0.5; # give alarm callback time to run
    ok !$runner->is_running, '!is_running';
  };

  SKIP: {
    skip 'signals are not supported on this platform'
      if $Proc::tored::Role::Running::NOSIGNALS;

    subtest 'signals' => sub {
      # Restore existing sigterm handlers after completing the subtest
      my $existing = $SIG{TERM};
      scope_guard { $SIG{TERM} = $existing };

      # Set sigterm handler that sets a flag for testing
      my $handled = 0;
      my $handler = $SIG{TERM} = sub { $handled = 1 };

      ok my $runner = Runner->new, 'new';
      ok $runner->start, 'start';

      isnt $SIG{TERM}, $handler, 'handler overridden';

      ok $runner->signal($$), 'signal';
      ok !$runner->is_running, '!is_running';
      ok $handled, 'overridden handler called';
      is $SIG{TERM} || undef, $handler, 'overridden handler restored';
    };
  };
};

done_testing;
