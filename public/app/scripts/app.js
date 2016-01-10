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
  .config(function ($routeProvider) {
    $routeProvider
      .when('/', {
        templateUrl: 'views/main.html',
        controller: 'MainCtrl'
      })
      .when('/profiles', {
        templateUrl: 'views/profiles.html',
        controller: 'MainCtrl'
      })
      .when('/schedules', {
        templateUrl: 'views/schedules.html',
        controller: 'MainCtrl'
      })
      .when('/serial', {
        templateUrl: 'views/serial.html',
        controller: 'SerialCtrl'
      })
      .when('/about', {
        templateUrl: 'views/about.html',
        controller: 'MainCtrl'
      })
      .otherwise({
        redirectTo: '/'
      });
  });
