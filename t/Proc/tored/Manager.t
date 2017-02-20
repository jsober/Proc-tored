use Test2::Bundle::Extended -target => 'Proc::tored::Manager';
use Path::Tiny 'path';

my $dir = Path::Tiny->tempdir('temp.XXXXXX', CLEANUP => 1, EXLOCK => 0);
skip_all 'could not create writable temp directory' unless -w $dir;

my $term = $dir->child("$$.term");


sub counter($\$%) {
  my ($proc, $acc, %flag) = @_;
  my $backstop = 10;
  my $count = 0;

  return sub {
    $$acc = ++$count;

    if ($count >= $backstop) {
      diag "backstop reached ($backstop)";
      $proc->stop;
      return;
    }

    return $flag{$count}->($count)
      if $flag{$count};

    return 1;
  };
}


ok my $proc = $CLASS->new(name => 'proc-tored-test-' . $$, dir => "$dir"), 'new';
is $proc->running_pid, 0, 'running_pid is 0 with no running process';
ok !$proc->is_running, '!is_running';
ok !$proc->is_stopped, '!is_stopped';
ok !$proc->is_paused, '!is_paused';

subtest 'start/stop' => sub {
  ok !$proc->is_stopped, '!is_stopped';
  ok !$proc->start, '!start';
  ok $proc->stop, 'stop';
  ok $proc->is_stopped, 'is_stopped';
  ok $proc->start, 'start';
  ok !$proc->is_stopped, '!is_stopped';
};

subtest 'pause/resume' => sub {
  ok !$proc->is_paused, '!is_paused';
  ok !$proc->resume, '!resume';
  ok $proc->pause, 'pause';
  ok $proc->is_paused, 'is_paused';
  ok $proc->resume, 'resume';
  ok !$proc->is_paused, '!is_paused';
};

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

subtest 'service' => sub {
  subtest 'start' => sub {
    $proc->clear_flags;

    my $acc = 0;
    my $counter = counter $proc, $acc, 3 => sub { 0 };
    ok $proc->service($counter), 'run service';
    is $acc, 3, 'service callback was called expected number of times';
    ok !$proc->is_stopped, '!is_stopped';
    ok !$proc->is_paused, '!is_paused';

    subtest 'negative path' => sub {
      my $lock = $proc->run_lock;

      $acc = 0;
      ok !$proc->service($counter), 'service returns false when cannot acquire lock';
      is $acc, 0, 'service callback is not called when service fails to acquire lock';
    };
  };

  subtest 'stop' => sub {
    $proc->clear_flags;

    my $acc = 0;
    my $counter = counter $proc, $acc, 3 => sub { $proc->stop };
    ok $proc->service($counter), 'run service';
    is $acc, 3, 'service self-terminates after being signalled';
  };
};

done_testing;
