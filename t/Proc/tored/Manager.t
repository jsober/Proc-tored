use Test2::Bundle::Extended -target => 'Proc::tored::Manager';
use File::Slurp;

bail_out 'OS unsupported' if $^O eq 'MSWin32';

ok my $proc = $CLASS->new(name => 'proc-tored-test-' . $$, dir => '/tmp'), 'new';
ok !$proc->is_running, 'is_running false initially';
is $proc->running_pid, 0, 'running_pid is 0 with no running process';

subtest 'run_lock' => sub {
  {
    ok my $lock = $proc->run_lock, 'acquire run lock';
    ok -f $proc->path, 'pidfile created';
    is read_file($proc->path), "$$\n", 'pidfile has expected contents';
    is $proc->running_pid, $$, 'running_pid returns current pid';
    ok $proc->is_running, 'is_running true';
    ok !$proc->run_lock, 'run_lock returns false when lock already held';
  };

  ok -f $proc->path, 'pidfile exists after guard out of scope';
  is read_file($proc->path), '', 'pidfile empty after guard out of scope';
  is $proc->running_pid, 0, 'running_pid returns 0 after guard out of scope';
  ok !$proc->is_running, 'is_running false after guard out of scope';
};

subtest 'run service' => sub {
  my $i = 0;
  my $do_stuff = sub { ++$i % 3 != 0 };

  ok my $service = $proc->service($do_stuff), 'run service';
  is $i, 3, 'service callback was called expected number of times';

  {
    my $lock = $proc->run_lock;
    ok !$proc->service($do_stuff), 'service returns false when cannot acquire lock';
    $i = 0; is $i, 0, 'service callback is not called when service fails to acquire lock';
  };
};

subtest 'stop service' => sub {
  my $service;

  my $i = 0;
  my $do_stuff = sub {
    if (++$i % 5 == 0) {
      return 0;
    }

    if ($i % 4 == 0) {
      $proc->stop;
    }
    elsif ($i >= 10) {
      die 'backstop activated';
    }

    return 1;
  };

  ok $service = $proc->service($do_stuff), 'run service';
  is $i, 4, 'service stops when is_running is false';
};

subtest 'sigterm' => sub {
  my $i = 0;

  my $do_stuff = sub {
    ++$i;
    kill 'SIGTERM', $$ if $i == 3;
    die 'backstop activated' if $i > 5; # backstop
    return 1;
  };

  my $service = $proc->service($do_stuff);
  is $i, 3, 'service self-terminates after SIGTERM received';
};

done_testing;
