'use strict';
function wsu(s) {
	var l = window.location;
	//var x = 'ws://10.0.8.31:80'+s;
	//return x;
	return ((l.protocol === 'https:') ? 'wss://' : 'ws://') + l.hostname + (((l.port !== 80) && (l.port !== 443)) ? ':' + l.port : '') + s;
}

var toHex = function (str) {
	var hex = '';
	for(var i=0;i<str.length;i++) {
		hex += ' '+('0' + str.charCodeAt(i).toString(16).toUpperCase()).substr(-2,2);
	}
	return hex;
};

var serial;
angular.module('infinitude')
	.filter('markDiff', function() {
		return function (str1,str2) {
			if (!str2) { return str1; }
			var indiff = false;
			var out = '';
			for(var i=0;i<str1.length;i++) {
				if (str1.charCodeAt(i) !== str2.charCodeAt(i) && indiff===false) {
					indiff = true;
					out+='<span class="diff">';
				}
				if (str1.charCodeAt(i) === str2.charCodeAt(i) && indiff===true) {
					indiff = false;
					out+='</span>';
				}
				out+=str1.substr(i,1);
			}
			if (indiff) { out+='</span>'; }
			return out;
		};
	})
	.filter('subStr', function() {
		return function (str,start,len) {
			if (!str) { return ''; }
			return str.substr(start,len);
		};
	})
	.filter('strings', function() {
		return function (str, min) {
			min = min || 4;
			var cnt = 0;
			var instring = false;
			var tmp = '';
			var out = '';
			for(var i=0;i<str.length;i++) {
				if (str.charCodeAt(i) === 0 && instring) {
					out+=tmp+'\n';
				}
				if (str.charCodeAt(i) >= 32 && str.charCodeAt(i)<=127) {
					tmp += str.substr(i,1);
					cnt += 1;
					if (cnt>=min) { instring = true; }
				} else {
					cnt = 0;
					instring = false;
					tmp = '';
				}
			}
			return out;
		};
	})
	.filter('toHex', function() {
		return toHex;
	})
  .controller('SerialCtrl', function ($scope,$rootScope) {
//		alert('started');
		$scope.rawSerial = 'Loading';
		$scope.frames = [];
		$scope.state = angular.fromJson(window.localStorage.getItem('infinitude-serial-state')) || {};
		serial = serial || new WebSocket(wsu('/serial'));
		serial.onopen = function() { console.log('Socket open'); };
		serial.onclose = function() { console.log('Socket closed'); };
		serial.onmessage = function(m) {
			var frame = angular.fromJson(m.data);

			var dataView = new jDataView(frame.data);
			$rootScope.carbus = $rootScope.carbus || {};
			$rootScope.history = $rootScope.history || angular.fromJson(window.localStorage.getItem('tmpdat')) || {};

			if (frame.Function.match(/write|reply/)) {
				var address = toHex(frame.data.substring(0,3));
				var id = frame.Function + frame.SrcClass + frame.DstClass + address;

				var busLog = function(key,value) {
					$rootScope.history[key] = $rootScope.history[key] || [{ 'key':key, values:[] }];
					value = $rootScope.carbus[key];
					$rootScope.history[key][0].values.push([frame.timestamp,value]);
					if ($rootScope.history[key][0].values.length>500) {
						$rootScope.history[key][0].values.shift();
					}
					window.localStorage.setItem('tmpdat',angular.toJson($rootScope.history));
				};

				// Break this out into config once others publish their registers.
				// Are you reading this? Then you're probably one of those people.
				if (frame.SrcClass === 'FanCoil') {
					if (address.match(/00 03 06/)) {
						$rootScope.carbus.blowerRPM = dataView.getInt16(1  +3);
						busLog('blowerRPM');
					}
					if (address.match(/00 03 16/)) {
						$rootScope.carbus.airflowCFM = dataView.getInt16(4  +3);
						busLog('airflowCFM');
					}
				}
				if (frame.SrcClass.match(/HeatPump/)) {
					if (address.match(/00 3E 01/)) {
						$rootScope.carbus.outsideTemp = dataView.getInt16(0  +3)/16;
						$rootScope.carbus.coilTemp = dataView.getInt16(2  +3)/16;
						busLog('coilTemp');
						busLog('outsideTemp');
					}
				}

				var lastframe = $scope.state[id] || frame;
				lastframe = lastframe.data;

				$scope.state[id] = $scope.state[id] || {};
				angular.extend($scope.state[id],frame);
				$scope.state[id].history = $scope.state[id].history || [];

				if (lastframe !== frame.data) { $scope.state[id].history.unshift(lastframe); }
				if ($scope.state[id].history.length>9) { $scope.state[id].history.pop(); }

				window.localStorage.setItem('infinitude-serial-state',angular.toJson($scope.state));
			}

			$scope.frames.push(frame);
			if ($scope.frames.length>9) { $scope.frames.shift(); }

			$scope.$apply();
		};
	});
