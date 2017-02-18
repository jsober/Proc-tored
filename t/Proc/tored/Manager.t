use Test2::Bundle::Extended -target => 'Proc::tored::Manager';
use Path::Tiny 'path';

my $dir = Path::Tiny->tempdir('temp.XXXXXX', CLEANUP => 1, EXLOCK => 0);
skip_all 'could not create writable temp directory' unless -w $dir;

my $term = $dir->child("$$.term");

ok my $proc = $CLASS->new(name => 'proc-tored-test-' . $$, dir => "$dir"), 'new';
ok !$proc->is_running, 'is_running false initially';
is $proc->running_pid, 0, 'running_pid is 0 with no running process';

subtest 'run_lock' => sub {
  my $path = path($proc->pid_file);
  my $lock =  $proc->run_lock;

  ok $lock, 'run lock';
  ok $path->exists, 'pidfile created';
  is $proc->running_pid, $$, 'running_pid returns current pid';
  ok $proc->is_running, 'is_running true';
  ok !$proc->run_lock, 'run_lock returns false when lock already held';

  undef $lock;

  ok $path->is_file, 'pidfile remains after guard out of scope';
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

subtest 'signal' => sub {
  my $i = 0;

  my $do_stuff = sub {
    # Increment test value
    if ($i < 3) {
      ++$i;
    }
    # Signal service to stop
    elsif ($i == 3) {
      $proc->signal($$);
    }
    # Failsafe
    elsif ($i > 300) {
      die 'backstop activated'; # backstop
    }

    return 1;
  };

  my $service = $proc->service($do_stuff);
  is $i, 3, 'service self-terminates after being signalled';
};

done_testing;
