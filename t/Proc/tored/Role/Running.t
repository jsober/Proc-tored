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

skip_all 'could not create writable temp directory' unless -w $dir;

ok my $runner = Runner->new(term_file => "$term"), 'new';
ok !$runner->is_running, '!is_running';
ok !$term->exists, 'no term file';
ok $runner->start, 'start';
ok $runner->is_running, 'is_running';
ok $runner->signal, 'signal';
ok $term->exists, 'term file created';
ok !$runner->is_running, '!is_running';
ok !$term->exists, 'term file removed';

done_testing;
