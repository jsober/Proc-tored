use Test2::Bundle::Extended;
use Path::Tiny;
use Proc::tored;

my $dir = Path::Tiny->tempdir('temp.XXXXXX', CLEANUP => 1, EXLOCK => 0);
skip_all 'could not create writable temp directory' unless -w $dir;

my $name = 'proc-tored-test';

subtest 'service' => sub {
  my $proctor = service $name, in "$dir";
  is ref $proctor, 'Proc::tored::Manager', 'expected class';
  is $proctor->name, $name, 'expected name';
  is $proctor->dir, "$dir", 'expected dir';

  my $pid;
  my $count = 0;
  my $stop = 4;

  run { $pid = running $proctor; ++$count < $stop } $proctor;

  is $count, $stop, 'expected work completed';
  is $pid, $$, 'expected pid while running';
  is 0, running $proctor, 'no running pid';
};

subtest 'stop' => sub {
  my $proctor = service $name, in "$dir";
  my $count = 0;
  my $stop = 4;

  run { stop $proctor if ++$count == $stop; $count < 10 } $proctor;

  is $count, $stop, 'expected work completed';
  is running $proctor, 0, 'no running pid';
};

done_testing;
