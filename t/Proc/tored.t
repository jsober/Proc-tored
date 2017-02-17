use Test2::Bundle::Extended;
use Path::Tiny;
use Proc::tored;

my $name = 'proc-tored-test';
my $dir = Path::Tiny->tempdir('temp.XXXXXX', CLEANUP => 1, EXLOCK => 0);
skip_all 'could not create writable temp directory' unless -w $dir;

subtest 'service creation' => sub {
  my $proctor = service $name, in $dir;
  is ref $proctor, 'Proc::tored::Manager', 'expected class';
  is $proctor->name, $name, 'expected name';
  is $proctor->dir, $dir, 'expected dir';
};

subtest 'service' => sub {
  my $proctor = service $name, in $dir;
  my $pid;
  my $count = 0;
  my $stop = 10;
  run { $pid = running $proctor; ++$count < $stop } $proctor;
  is $count, $stop, 'expected work completed';
  is $pid, $$, 'expected pid while running';
  is 0, running $proctor, 'no running pid';
};

subtest 'stop' => sub {
  my $proctor = service $name, in $dir;
  my $count = 0;
  my $stop = 10;
  run { ++$count < $stop or stop $proctor } $proctor;
  is $count, $stop, 'expected work completed';
  is 0, running $proctor, 'no running pid';
};

subtest 'zap' => sub {
  my $proctor = service $name, in $dir;
  my $count = 0;
  my $stop = 10;
  my $zapped = 0;

  run {
      if (++$count == $stop) {
        $zapped = zap $proctor;
      }
      die "backstop" if $count > $stop * 2;
      return $count;
    } $proctor;

  ok $zapped, 'zapped';
  is $count, $stop, 'expected work completed';
  is 0, running $proctor, 'no running pid';
};

done_testing;
