'use strict';
angular.module('infinitude')
  .controller('MainCtrl', function ($scope, $http, $interval, $timeout, $location) {
		$scope.debounce = 0;
		$scope.carbus = $scope.carbus||{};

		$scope.empty = function(input) { console.log(input); };
		$scope.mkTime = function(input) {
			if (angular.equals({}, input)) return '00:00'
			return input;
		};

		var store = angular.fromJson(window.localStorage.getItem('infinitude')) || {};

		//charting
		if ($scope.history) {
			var labels = [];
			var lindat = [[],[]];
			angular.forEach($scope.history.coilTemp[0].values, function(v,i) {
				var valen = $scope.history.coilTemp[0].values.length;
				var modul = Math.round(valen/20); //20 data points
				if (i % modul == 0) {
					labels.push(new Date(1000*v[0]).toLocaleString());
					lindat[0].push(v[1]);
					lindat[1].push($scope.history.outsideTemp[0].values[i][1]);
				}
			});
			$scope.oduLabels = labels;
			$scope.oduSeries = ['CoilTemp','OutsideTemp'];
			$scope.oduData = lindat;
		}

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
				.success(function() {
					$scope.debounce = 0;
					setTimeout(function() { if ($scope.debounce == 0) $scope.reloadData(); }, 10*1000);
				})
				.error(function() {
					console.log('oh noes! save fail.');
				});
		};
  });
