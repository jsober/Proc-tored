use Test2::Bundle::Extended;
use Proc::tored;

my $name = 'proc-tored-test';
my $dir  = '/tmp';

subtest 'service creation' => sub {
  my $proctor = service $name, in $dir, poll 0.5;
  is ref $proctor, 'Proc::tored::Manager', 'expected class';
  is $proctor->name, $name, 'expected name';
  is $proctor->dir, $dir, 'expected dir';
  is $proctor->poll_wait_time, 0.5, 'expected poll_wait_time';
};

subtest 'service' => sub {
  my $proctor = service $name, in $dir;
  my $pid; my $count = 0;
  run { $pid = running $proctor; ++$count < 4 } $proctor;
  is $count, 4, 'expected work completed';
  is $pid, $$, 'expected pid while running';
  is 0, running $proctor, 'no running pid';
};

subtest 'stop' => sub {
  my $proctor = service $name, in $dir;
  my $count = 0;
  run { ++$count < 4 or stop $proctor } $proctor;
  is $count, 4, 'expected work completed';
  is 0, running $proctor, 'no running pid';
};

subtest 'zap' => sub {
  my $proctor = service $name, in $dir;
  my $count = 0;
  run { ++$count < 4 or zap $proctor } $proctor;
  is $count, 4, 'expected work completed';
  is 0, running $proctor, 'no running pid';
};

done_testing;
