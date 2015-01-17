'use strict';

function wsu(s) {
	var l = window.location;
	return 'ws://10.0.8.31:8080'+s;
	return ((l.protocol === 'https:') ? 'wss://' : 'ws://') + l.hostname + (((l.port !== 80) && (l.port !== 443)) ? ':' + l.port : '') + s;
}

		var toHex = function (str) {
			var hex = '';
			for(var i=0;i<str.length;i++) {
				hex += ' '+("0" + str.charCodeAt(i).toString(16).toUpperCase()).substr(-2,2);
			}
			return hex;
		};

var serial;
angular.module('infinitude')
	.filter('markDiff', function() {
		return function (str1,str2) {
			if (!str2) return str1;
			var indiff = false;
			var out = '';

			for(var i=0;i<str1.length;i++) {
				if (str1.charCodeAt(i) != str2.charCodeAt(i) && indiff==false) {
					indiff = true;
					out+='<span class="diff">';
				}
				if (str1.charCodeAt(i) == str2.charCodeAt(i) && indiff==true) {
					indiff = false;
					out+='</span>';
				}
				out+=str1.substr(i,1);
			}
			if (indiff) out+="</span>";
			return out;
		}
	})
	.filter('subStr', function() {
		return function (str,start,len) {
			if (!str) return "";
			return str.substr(start,len);
		}
	})
	.filter('strings', function() {
		return function (str, min) {
			min = min || 4;
			var cnt = 0;
			var instring = false;
			var tmp = '';
			var out = '';

			for(var i=0;i<str.length;i++) {
				if (str.charCodeAt(i) == 0 && instring) {
					out+=tmp+"\n";
				}
				if (str.charCodeAt(i) >= 32 && str.charCodeAt(i)<=127) {
					tmp += str.substr(i,1);
					cnt += 1;
					if (cnt>=min) instring = true;
				} else {
					cnt = 0;
					instring = false;
					tmp = '';
				}
			}
			return out;
		}
	})
	.filter('toHex', function() {
		return toHex;
	})
  .controller('SerialCtrl', function ($scope,$rootScope) {
		$scope.rawSerial = 'Loading';
		$scope.frames = [];
		$scope.state = JSON.parse(window.localStorage.getItem("infinitude-serial-state")) || {};
		serial = serial || new WebSocket(wsu('/serial'));
		serial.onopen = function() { console.log('Socket open'); };
		serial.onclose = function() { console.log('Socket closed'); };
		serial.onmessage = function(m) {
			var frame = JSON.parse(m.data);


			var dataView = new jDataView(frame.data);
			$rootScope.carbus = $rootScope.carbus || {};

			if (frame.Function.match(/write|reply/)) {
				var address = toHex(frame.data.substring(0,3));
				var id = frame.SrcClass + frame.DstClass + address;

				if (frame.SrcClass == 'FanCoil') {
					if (address.match(/00 03 06/)) {
						$rootScope.carbus.blowerRPM = dataView.getInt16(1  +3);
					}
					if (address.match(/00 03 16/)) {
						$rootScope.carbus.airflowCFM = dataView.getInt16(4  +3);
					}
				}
				if (frame.SrcClass.match(/HeatPump/)) {
					if (address.match(/00 3E 01/)) {
						$rootScope.carbus.outsideTemp = dataView.getInt16(0  +3)/16;
						$rootScope.carbus.coilTemp = dataView.getInt16(2  +3)/16;
					}
				}

				var lastframe = $scope.state[id] || frame;
				lastframe = lastframe.data;

				$scope.state[id] = $scope.state[id] || {};
				angular.extend($scope.state[id],frame);
				$scope.state[id].history = $scope.state[id].history || [];

				if (lastframe !== frame.data) $scope.state[id].history.unshift(lastframe);
				if ($scope.state[id].history.length>9) $scope.state[id].history.pop();

				window.localStorage.setItem("infinitude-serial-state",JSON.stringify($scope.state));
			}


			$scope.frames.push(frame);
			$scope.framecount = $scope.frames.length;
			if ($scope.frames.length>9) $scope.frames.shift();
			$scope.rawSerial += m.data;
			var slen = $scope.rawSerial.length;
			var max = 2048;
			if (slen>max) {
				$scope.rawSerial = $scope.rawSerial.substr(slen-max,max);
			}
			$scope.$apply();
		};
	});
