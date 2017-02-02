`Proc::tored` is a perl module to make it simpler to manage a service using a pid file.
The name is a very poor pun on the work "proctor". You're welcome.

    use Proc::tored;

    my $proctor = Proc::tored->new(dir => '/tmp', name => 'my-service');

    # Call do_stuff while the service is running or until do_stuff returns false
    $proctor->service(\&do_stuff)
      or die sprintf('process %d is already running this service!', $proctor->running_pid);

    # Signal another process running this service to quit gracefully, throwing an
    # error if it does not self-terminate after 15 seconds.
    if (my $pid = $proctor->stop_running_process(15)) {
      die "process $pid is being stubborn!";
    }
