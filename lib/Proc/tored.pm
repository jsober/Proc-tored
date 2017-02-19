package Proc::tored;
# ABSTRACT: Service management using a pid file and touch files

use strict;
use warnings;
require Exporter;
require Proc::tored::Manager;

=head1 SYNOPSIS

  use Proc::tored;

  my $service = service 'stuff-doer', in '/var/run';

  # Run service
  run { do_stuff() or stop $service } $service
    or die 'existing process running under pid '
          . running $service;

  # Terminate another running process, timing out after 15s
  zap $service, 15
    or die 'stuff_doer pid ' . running $service . ' is being stubborn';

=head1 DESCRIPTION

A C<Proc::tored> service is voluntarily managed by a pid file and touch files.

=head1 EXPORTED SUBROUTINES

C<Proc::tored> is an C<Exporter>. All routines are exported by default.

=head2 service

Defines the service by name. The pid file will be created as C<name.pid>.

  my $service = service 'thing', ...;

=head2 in

Sets the directory where the pid file will be created.

  my $service = service 'thing', in '/var/run';

=head2 run

Starts the service loop, calling the supplied code block until it either
returns false or the service is stopped (internally via L</stop> or externally
via L</zap>).

  run {
    my $task = get_next_task() or return;
    process_task($task);
    return 1;
  } $service;

=head2 stop

Tells the L</run> loop to shut down.

  run {
    my $task = get_next_task() or stop $service;
    process_task($task);
    return 1;
  } $service;

=head2 running

If the supplied service is running as another process (as found in the pid
file), returns the pid of that process. Returns 0 otherwise.

  zap $service if running $service;

=head2 zap

Signals a running instance of the service that it should self-terminate
(assuming it is also C<Proc::tored>). Accepts an optional C<$timeout> in
fractional seconds, causing C<zap> to wait up to C<$timeout> seconds for the
process to exit.

  zap $service, 30
    or die 'timed out after 30s waiting for service to exit';

=cut

use parent 'Exporter';

our @EXPORT = qw(
  service
  in
  run
  stop
  running
  zap
);

sub service ($%)  { Proc::tored::Manager->new(name => shift, @_) }
sub in      ($;@) { dir => shift, @_ }
sub pid     ($)   { $_[0]->read_pid }
sub running ($)   { $_[0]->running_pid }
sub run     (&$)  { $_[1]->service($_[0]) }
sub stop    ($)   { $_[0]->stop }
sub zap     ($;@) { shift->stop_running_process(@_) }
sub pause   ($)   { $_[0]->pause }
sub resume  ($)   { $_[0]->resume }
sub halt    ($)   { $_[0]->halt }

1;
