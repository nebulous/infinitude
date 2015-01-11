'use strict';

angular.module('publicApp')
  .controller('MainCtrl', function ($scope, $http, $interval, $location) {
		$scope.debounce = 0;
		var reloadData = function() {
			if ($scope.debounce > 0) {
				$scope.debounce = $scope.debounce - 1;
				return;
			}
			$http.get('/systems.json').
				success(function(data) {
					$scope.systems = data;
					//console.log('systems:',$scope.systems);
				});
			$http.get('/status.json').
				success(function(data) {
					$scope.status = data.status[0];
					//console.log('status:',$scope.status);
				});
			$http.get('/notifications.json').
				success(function(data) {
					$scope.notifications = data.notifications[0];
					//console.log('status:',$scope.status);
				});
			/*$http.get('/energy.json').
				success(function(data) {
					$scope.energy = data.energy[0];
					//console.log('status:',$scope.status);
				});
			*/
		};

		$scope.$watch('systems', function(newValue,oldValue) {
			if (newValue!==oldValue) {
				// time rounding;
				/*
				var otmr = newValue.system[0].config[0].zones[0].zone[0].otmr[0];
				if (otmr) {
					var  min = otmr.replace(/^[0-9]+:/,'');
					var    m = (Math.round((min/15))*15 % 60);
					$scope.systems.system[0].config[0].zones[0].zone[0].otmr[0] = otmr.replace(/:.+$/,':'+m);
				}*/
				$scope.debounce = $scope.debounce + 1;
			}
		}, true);
		//$scope.$watch('systems.system[0].config[0].zones[0].zone[0]', function(newValue,oldValue) {
		//}, true);
		reloadData();
		$interval(reloadData,200000);

		$scope.isActive = function(route) {
			return route === $location.path();
		};
		$scope.save = function() {
			console.log('saving systems structure');
			$http.post('/systems/infinitude', $scope.systems)
				.success(function() { $scope.debounce = 0; })
				.error(function() {
					console.log('oh noes! save fail.');
				});
		};
  });
