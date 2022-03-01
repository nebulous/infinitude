'use strict';

angular
  .module('infinitude', [
    'ngCookies',
    'ngResource',
    'ngSanitize',
    'ngRoute',
    'yaru22.angular-timeago',
    'angular-dialgauge',
    'jkuri.timepicker',
    'chart.js'
  ])
  .config(function ($routeProvider, $locationProvider) {
    $routeProvider
      .when('/', {
        templateUrl: 'views/main.html'
      })
      .when('/profiles', {
        templateUrl: 'views/profiles.html'
      })
      .when('/schedules', {
        templateUrl: 'views/schedules.html'
      })
      .when('/serial', {
        templateUrl: 'views/serial.html'
      })
      .when('/about', {
        templateUrl: 'views/about.html'
      })
      .otherwise({
        redirectTo: '/'
      });

      $locationProvider.hashPrefix('');
  });
