#!/usr/bin/env perl

package Infinitude;
use Web::Simple 'Infinitude';
use Plack::Middleware::TemplateToolkit;

use URI::Encode qw/uri_encode uri_decode/;
use XML::Simple;
use DateTime;

use Data::Dumper;
sub dispatch_request {
  my ($self, $env) = @_;
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
    $env->{'tt.vars'}{dt} = DateTime->now(time_zone=>'GMT');
    $env->{'tt.template'} = 'forecast.xml';
    return;
  },
  #POST http://128.11.138.31/systems/2512W003720
  sub (POST + /systems/:system_id + %data=) {
    my ($self, $system_id, $data) = @_;
    open(F,">root/systems.txt"); print F Dumper(XMLin($data)); close(F);
    [ 200, [], [] ]
  },
  #POST http://128.11.138.31/systems/2512W003720/status
  sub (POST + /systems/:system_id/status + %data=) {
    my ($self, $system_id, $data) = @_;
    print STDERR "---------------- status ------------------\n";
    open(F,">root/status.txt"); print F Dumper(XMLin($data)); close(F);
    $env->{'tt.vars'}{ping_rate} = 120; 
    $env->{'tt.template'} = 'status.xml';
    return;
  },
  #POST http://128.11.138.31/systems/2512W003720/notifications
  sub (/systems/:system_id/notifications) {
    [ 200, [], [] ]
  },
  sub (/test) {
    $env->{'tt.template'} = 'forecast.xml';
    $env->{'tt.vars'}{dt} = DateTime->now(time_zone=>'GMT');
    return;
  },
  sub (GET + /) {
    $env->{'tt.template'} = 'index.html';
    return;
  },
  sub () {
    my $self = shift;
    my $env = shift;
    print STDERR "Fallback called\n";
    return $env->{'tt.template'} 
      ? Plack::Middleware::TemplateToolkit->new(INCLUDE_PATH=>'root')
      : [ 405, [ 'Content-type', 'text/plain' ], [ 'Method not allowed' ] ];
  }
}

Infinitude->run_if_script;
