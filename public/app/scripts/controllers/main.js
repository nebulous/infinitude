'use strict';
angular.module('infinitude')
  .controller('MainCtrl', function ($scope, $http, $interval, $timeout, $location) {
		$scope.debounce = 0;
		$scope.carbus = $scope.carbus||{};

		var store = angular.fromJson(window.localStorage.getItem('infinitude')) || {};


		var globeTimer;
		$scope.reloadData = function() {
			if ($scope.debounce > 0) {
				$scope.debounce = $scope.debounce - 1;
			}
			var keys = ['systems','status','notifications','energy'];
			angular.forEach(keys, function(key) {
				$scope.globeColor = '#16F';
				$http.get('/'+key+'.json').
					success(function(data) {
						var rkey = key;
						if (rkey === 'systems') { rkey = 'system'; }
						//console.log(key,rkey,data);
						$scope[key] = store[key] = data[rkey][0];

						$scope.globeColor = '#44E';
						$timeout.cancel(globeTimer);
						globeTimer = $timeout(function() { $scope.globeColor = '#E44' }, 4*60*1000);
					})
					.error(function() {
						$scope.globeColor = '#E44';
						console.log('oh noes!',arguments);
					});
			});
			window.localStorage.setItem('infinitude', angular.toJson(store));
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
		$scope.reloadData();
		$interval($scope.reloadData,3*60*1000);

		$scope.isActive = function(route) {
			return route === $location.path();
		};
		$scope.save = function() {
			var systems = { "system":[$scope.systems] };
			//console.log('saving systems structure', systems);
			$http.post('/systems/infinitude', systems )
				.success(function() { $scope.debounce = 0; })
				.error(function() {
					console.log('oh noes! save fail.');
				});
		};
  });
