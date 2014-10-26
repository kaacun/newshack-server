@dir = "/root/newshack-server/"

worker_processes 2
working_directory @dir

listen 80

stderr_path File.expand_path('unicorn.log', File.dirname(__FILE__))
stdout_path File.expand_path('unicorn.log', File.dirname(__FILE__))
preload_app true
