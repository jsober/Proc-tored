use strict;
use warnings;
use Test2::Bundle::Extended;
use File::Slurp;

use Proc::tored;

ok my $proc = Proc::tored->new(name => 'proc-tored-test-' . $$, dir => '/tmp'), 'new';
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
      $proc->{is_running} = 0;
    }
    elsif ($i >= 10) {
      die 'backstop activated';
    }

    return 1;
  };

  ok $service = $proc->service($do_stuff), 'run service';
  is $i, 4, 'service stops when is_running is false';
};

done_testing;
