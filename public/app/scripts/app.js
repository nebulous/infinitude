'use strict';

angular
  .module('publicApp', [
    'ngCookies',
    'ngResource',
    'ngSanitize',
    'ngRoute',
		'objectEditor'
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
