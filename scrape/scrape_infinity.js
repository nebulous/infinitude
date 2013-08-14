var system = require('system');

if (system.args.length < 5) {
  console.info("You need to pass in username and password as arguments to this code.");
  phantom.exit();
}

var username = system.args[4];
var password = system.args[5];
var base_uri = 'https://www.myinfinitytouch.carrier.com/';

var casper = require('casper').create({
  verbose: false,
  logLevel: 'error'
});

casper.on('error', function(msg,backtrace) {
  this.echo("=========================");
  this.echo("ERROR:");
  this.echo(msg);
  this.echo(backtrace);
  this.echo("=========================");
});

casper.on("page.error", function(msg, backtrace) {
  this.echo("=========================");
  this.echo("PAGE.ERROR:");
  this.echo(msg);
  this.echo(backtrace);
  this.echo("=========================");
});

casper.start(base_uri + "MyLocations", function () {
  var loggedin = this.evaluate(function() {
    return $('a[href*="ogout"]:first').text().trim();
  }) ? true : false;
  if (!loggedin) {
    this.evaluate(function() { $('#RememberMe').attr('checked',true); });
    this.fill('form[action*="/Account/Login"]', { UsernameOrEmail: username, Password: password, RememberMe:true },true);
  }
});

casper.then(function() {
  var data = this.evaluate(function() {
    var output = {};
    $('.system_status thead tr th').map(function(i,o) { return $(this).text().replace(/\s+/,'').trim() }).each(function(i,key) {
      output[key] = $('.system_status tbody tr td:nth-child('+(i+1)+')').text().trim();
    });
    output["OutsideTemp"] = $('.system_status>span.temp').text().replace('Outside Temp:\s?','');
    output["TimeStamp"] = new Date().toJSON();
    return output;
  });
  this.echo(JSON.stringify(data));
  casper.exit();
});

casper.run();
