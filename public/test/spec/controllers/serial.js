'use strict';

describe('Controller: SerialCtrl', function () {

  // load the controller's module
  beforeEach(module('publicApp'));

  var SerialCtrl,
    scope;

  // Initialize the controller and a mock scope
  beforeEach(inject(function ($controller, $rootScope) {
    scope = $rootScope.$new();
    SerialCtrl = $controller('SerialCtrl', {
      $scope: scope
    });
  }));

  it('should attach a list of awesomeThings to the scope', function () {
    expect(scope.awesomeThings.length).toBe(3);
  });
});
