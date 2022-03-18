'use strict';
angular.module('infinitude')
  .controller('MainCtrl', function ($scope, $http, $interval, $timeout, $location) {
		const GLOBE_COLOR_LOADING='#16F';
		const GLOBE_COLOR_CONNECTED='#44E';
		const GLOBE_COLOR_UNSAVED_CHANGES='#F0F';
		const GLOBE_COLOR_ERROR='#E44';

		$scope.carbus = $scope.carbus||{};

		$scope.selectedZone = 0;

		$scope.systemsEdit = null;
		// Null indicates the "systems" data has never been copied to "systemsEdit"
		// False means the data has been copied and is currently the same as "systems"
		// True means the data has been copied and the user has edited it
		$scope.systemsEdited = null;

		$scope.empty = function(input) { console.log(input); };
		$scope.mkTime = function(input) {
			if (angular.equals({}, input)) { return '00:00'; }
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
				if (i % modul === 0) {
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
		$scope.reloadData = function(userInitiated) {
			if (userInitiated && $scope.systemsEdited) {
				if (confirm('This will erase your unsaved changes')) {
					$scope.systemsEdited = null;
				}
			}
			var keys = ['systems','status','notifications','energy'];
			angular.forEach(keys, function(key) {
				$scope.globeColor = GLOBE_COLOR_LOADING;
				$http.get('/'+key+'.json')
					.then(function(response) {
						var rkey = key;
						if (rkey === 'systems') {
							rkey = 'system';
							// If "systemsEdit" hasn't been populated or hasn't been edited, deep-copy
							// "systems" to it to provide a copy for the user to edit without having
							// the automatic refresh wipe the edits
							if ($scope.systemsEdited === false || $scope.systemsEdited === null) {
								$scope.systemsEdit = angular.copy(response.data[rkey][0]);
							}
						}
						//console.log(key,rkey,response.data);
						$scope[key] = store[key] = response.data[rkey][0];
						// If "systemsEdit" has been edited, don't switch away from the magenta globe
						if ($scope.systemsEdited !== true) {
							$scope.globeColor = GLOBE_COLOR_CONNECTED;
						}
						$timeout.cancel(globeTimer);
						globeTimer = $timeout(function() {
							$scope.globeColor = GLOBE_COLOR_ERROR;
						}, 4*60*1000);
					},
					function() {
						$scope.globeColor = GLOBE_COLOR_ERROR;
						console.log('oh noes!',arguments);
					});
			});
			window.localStorage.setItem('infinitude', angular.toJson(store));
		};

		$scope.$watch('systemsEdit', function() {
			if ($scope.systemsEdit !== null) {
				// If "systemsEdit" was not populated previously or the user undid all changes
				// (making "systemsEdit" equal to "systems" once again), mark the data as not
				// having been edited
				// If "systemsEdit" was already populated, this indicates a user edit
				if ($scope.systemsEdited === null || angular.equals($scope.systems, $scope.systemsEdit)) {
					$scope.systemsEdited = false;
					$scope.globeColor = GLOBE_COLOR_CONNECTED;
				} else if ($scope.systemsEdited === false) {
					$scope.systemsEdited = true;
					$scope.globeColor = GLOBE_COLOR_UNSAVED_CHANGES;
				}
			}
		}, true);

		$scope.reloadData(false);
		$interval($scope.reloadData, 3*60*1000, 0, true, false);

		$scope.isActive = function(route) {
			return route === $location.path();
		};

		$scope.save = function() {
			// Deep-copy "systemsEdit" back to "systems" so that any more
			// changes made before the next reload will appear correctly
			$scope.systems = angular.copy($scope.systemsEdit);
			var systems = { 'system':[$scope.systems] };
			//console.log('saving systems structure', systems);
			$http.post('/systems/infinitude', systems )
				.then(function() {
					setTimeout(function() {
						$scope.reloadData(false);
					}, 10*1000);
					$scope.systemsEdited = false;
					$scope.globeColor = GLOBE_COLOR_CONNECTED;
				},
				function() {
					console.log('oh noes! save fail.');
				});
		};

		$scope.selectZone = function(zone) {
			$scope.selectedZone = zone;
		};

		$scope.equals = function(a, b) {
			return angular.equals(a, b);
		}
	});
