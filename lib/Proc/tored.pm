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
  run { do_stuff() } $service
    or die 'existing process running under pid '
          . running $service;

  # Pause the running process
  pause $service;
  sleep 30;
  resume $service;

  # Terminate another running process, timing out after 15s
  zap $service, 15
    or die 'stuff_doer pid ' . running $service . ' is being stubborn';

=head1 DESCRIPTION

A C<Proc::tored> service is voluntarily managed by a pid file and touch files.

=head1 EXPORTED SUBROUTINES

All routines are exported by default.

=head2 service

Creates a new service. The name given to the service is used in the naming of
various files used to control the service.

=head2 in

Selects the location where the service will look for the pid file and touch
files used to control the service.

=head2 pid

Reads and returns the contents of the pid file. Does not check to determine
whether the pid is valid. Returns 0 if the pid file is not found or is empty.

=head2 running

Reads and returns the contents of the pid file. If the pid cannot be signaled
using `kill(0, $pid)`, returns 0.

=head2 zap

Blocks until a running service exits. Returns immediately if the L</running>
service is the current process.

=head2 run

Begins the service in the current process. The service, specified as a code
block, will be called until it returns false or the L</stopped> flag is set.

If the L</paused> flag is set, the loop will continue to run without executing
the code block until it has been L</resume>d.

=head2 stop

Sets the "stopped" flag for the service.

=head2 start

Clears the "stopped" flag for the service.

=head2 stopped

Returns true if the "stopped" flag has been set.

=head2 pause

Sets the "paused" flag for the service.

=head2 resume

Clears the "paused" flag for the service.

=head2 paused

Returns true if the "paused" flag has been set.

=cut

use parent 'Exporter';

our @EXPORT = qw(
  service
  in

  pid
  running
  zap
  run

  stop
  start
  stopped

  pause
  resume
  paused
);

sub service ($%)  { Proc::tored::Manager->new(name => shift, @_) }
sub in      ($;@) { dir => shift, @_ }

sub pid     ($)   { $_[0]->read_pid }
sub running ($)   { $_[0]->running_pid }
sub zap     ($;@) { shift->stop_wait(@_) }
sub run     (&$)  { $_[1]->service($_[0]) }

sub stop    ($)   { $_[0]->stop }
sub start   ($)   { $_[0]->start }
sub stopped ($)   { $_[0]->is_stopped }

sub pause   ($)   { $_[0]->pause }
sub resume  ($)   { $_[0]->resume }
sub paused  ($)   { $_[0]->is_paused }

1;
