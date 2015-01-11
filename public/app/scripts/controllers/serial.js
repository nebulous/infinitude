'use strict';

function wsu(s) {
	var l = window.location;
	return ((l.protocol === 'https:') ? 'wss://' : 'ws://') + l.hostname + (((l.port !== 80) && (l.port !== 443)) ? ':' + l.port : '') + s;
}

var serial;
angular.module('publicApp')
  .controller('SerialCtrl', function ($scope) {
		$scope.rawSerial = 'Loading';
		serial = serial || new WebSocket(wsu('/serial'));
		serial.onopen = function() { console.log('Socket open'); };
		serial.onclose = function() { console.log('Socket closed'); };
		serial.onmessage = function(m) {
			$scope.rawSerial += m.data;
			var slen = $scope.rawSerial.length;
			var max = 2048;
			if (slen>max) {
				$scope.rawSerial = $scope.rawSerial.substr(slen-max,max);
			}
			$scope.$apply();
		};
		//serial.send('oh hai');
	});
