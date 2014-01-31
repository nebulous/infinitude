#!/usr/bin/env perl

package Infinitude;
use Web::Simple __PACKAGE__;
use Plack::Middleware::TemplateToolkit;
use WWW::Wunderground::API;
use Cache::FileCache;
use XML::Simple;
use DateTime;
use Data::Dumper;

sub default_config {
  tt=>{
    time_zone=>'America/New_York',
    forecast_ping=>240,
    status_ping=>60
  },
  wunderground=>{
      location=>'22152', 
      api_key=>($ENV{WUNDERGROUND_KEY} || 'your wunderground key'), 
      auto_api=>1,
      cache=>Cache::FileCache->new({ namespace=>'infinitude', default_expires_in=>60*240 }) #Any cache should do.
  }
}

sub dispatch_request {
  my ($self, $env) = @_;

  my $wunderground = new WWW::Wunderground::API($self->config->{wunderground});

  #Mangle Internet-bound request to self
  #Plack::App::Proxy and friends may do this better
  if ($env->{HTTP_HOST} !~ /$env->{SERVER_NAME}/) {
    $env->{HTTP_HOST} = $env->{SERVER_NAME}.':'.$env->{SERVER_PORT};
    $env->{PATH_INFO} =~ s|http://[^/]+||;
    $env->{REQUEST_URI} =~ s|http://[^/]+||;
    $self->redispatch_to($env->{REQUEST_URI});
  }

  #GET /Alive?sn=1234W0003210
  sub (/Alive + ?sn=) {
    [ 200, [ 'Content-type', 'text/plain' ], [ 'alive' ] ]
  },
  #GET http://128.11.138.31/weather/22152/forecast
  sub (GET + /weather/:zip/forecast) {
    my ($self, $param) = @_;
    $env->{'tt.template'} = 'forecast.xml';
    $env->{'tt.vars'}{dt} = DateTime->now(time_zone=>'GMT');
    $env->{'tt.vars'}{zip} = $param->{zip};
    $wunderground->location($param->{zip});
    $wunderground->forecast10day;
    $env->{'tt.vars'}{wunderground} = $wunderground;
    open(F,">root/weather.txt"); print F Dumper($wunderground->data); close(F);
    return;
  },


  #sync process:
  # POST /systems/id/status
  #   server has changes?
  #     false: return
  #     true:
  #       GET /systems/id  (full config returned from server)
  #       POST /systems/id (full config posted back to server)
  #       POST /notifications



  #GET http://128.11.138.31/systems/2500W003210
  # This is called after /systems/2500W003210/status returns <serverHasChanges>true</serverHasChanges>
  sub (GET + /systems/:system_id) {
    #TODO: return full config according to server. For now, return an empty reply and move on.
    return [ 200, [], [] ];
  },
  #POST http://128.11.138.31/systems/2500W003210
  sub (POST + /systems/:system_id + %data=) {
    my ($self, $system_id, $data) = @_;
    open(F,">root/systems.txt"); print F Dumper(XMLin($data)); close(F);
    [ 200, [], [] ]
  },
  #POST http://128.11.138.31/systems/2500W003210/status
  sub (POST + /systems/:system_id/status + %data=) {
    my ($self, $system_id, $data) = @_;
    open(F,">root/status.txt"); print F Dumper(XMLin($data)); close(F);
    $env->{'tt.vars'}{ping_rate} = 120;
    #TODO: setup web interface and return serverHasChanges: true
    $env->{'tt.template'} = 'status.xml';
    return;
  },
  #POST http://128.11.138.31/systems/2500W003210/notifications
  sub (POST + /systems/:system_id/notifications + %data=) {
    my ($self, $system_id, $data) = @_;
    open(F,">root/notifications.txt"); print F Dumper(XMLin($data)); close(F);
    [ 200, [], [] ]
  },
  sub (GET + /) {
    $env->{'tt.template'} = 'index.html';
    return;
  },
  sub () {
    my $self = shift;
    my $env = shift;
    return $env->{'tt.template'} 
      ? Plack::Middleware::TemplateToolkit->new(INCLUDE_PATH=>'root', vars=>$self->config->{tt})
      : [ 405, [ 'Content-type', 'text/plain' ], [ 'Method not allowed' ] ];
  }
}

Infinitude->run_if_script;
