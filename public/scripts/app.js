// Infinitude - Alpine.js application
(function() {
  'use strict';

  // --- Utility functions (replacing Angular filters) ---

  function toHex(str) {
    if (typeof str != 'string') return '';
    return str.split('').map(function(c) { return c.charCodeAt(0).toString(16).padStart(2, '0'); }).join(' ');
  }
  function fromHex(hexstr) {
    if (typeof hexstr != 'string') return '';
    return hexstr.replace(/ /g, '').split(/(\w\w)/g).filter(function(p) { return !!p; }).map(function(c) { return String.fromCharCode(parseInt(c, 16)); }).join('');
  }
  function subStr(str, start, len) {
    if (!str) return '';
    return str.substr(start, len);
  }
  function markDiff(str1, str2) {
    if (!str2) return str1;
    var indiff = false, out = '';
    for (var i = 0; i < str1.length; i++) {
      if (str1.charCodeAt(i) !== str2.charCodeAt(i) && !indiff) { indiff = true; out += '<span class="diff">'; }
      if (str1.charCodeAt(i) === str2.charCodeAt(i) && indiff) { indiff = false; out += '</span>'; }
      out += str1.substr(i, 1);
    }
    if (indiff) out += '</span>';
    return out;
  }
  function display(val) {
    if (val === undefined || val === null) return '';
    if (typeof val === 'object') return JSON.stringify(val, null, 2);
    return val;
  }
  function strings(str, min) {
    if (!str) return '';
    min = min || 4;
    var cnt = 0, instring = false, tmp = '', out = '';
    for (var i = 0; i < str.length; i++) {
      if (str.charCodeAt(i) >= 32 && str.charCodeAt(i) <= 127) { tmp += str.substr(i, 1); cnt++; if (cnt >= min) instring = true; }
      else { if (instring) out += tmp + '\n'; cnt = 0; instring = false; tmp = ''; }
    }
    if (instring) out += tmp;
    return out;
  }

  // Expose to templates
  window.appUtils = { toHex: toHex, fromHex: fromHex, subStr: subStr, markDiff: markDiff, strings: strings, display: display };

  // --- WebSocket URL helper ---
  function wsu(path) {
    var l = window.location;
    return ((l.protocol === 'https:') ? 'wss://' : 'ws://') + l.hostname + (((l.port !== '80') && (l.port !== '443')) ? ':' + l.port : '') + path;
  }

  var GLOBE_LOADING = '#16F';
  var GLOBE_CONNECTED = '#44E';
  var GLOBE_UNSAVED = '#F0F';
  var GLOBE_ERROR = '#E44';

  document.addEventListener('alpine:init', function() {
    Alpine.data('infinitude', function() {
      return {
        // Route state
        currentRoute: window.location.hash.replace('#', '') || '/',

        // Data from API
        systems: null,
        status: null,
        notifications: null,
        energy: null,
        systemsEdit: null,
        systemsEdited: null,  // null=never copied, false=clean copy, true=dirty
        selectedZone: 0,

        // UI state
        globeColor: GLOBE_LOADING,
        transferColor: '#5E5',

        // Serial / WebSocket
        rawSerial: 'Loading',
        frames: [],
        devices: {},
        state: {},
        carbus: {},
        history: {},

        // Serial filters
        srcFilter: '',
        dstFilter: '',
        cmdFilter: '',
        regFilter: '',
        samreqReg: '',


        // Timers (not reactive)
        _globeTimer: null,
        _transferTimer: null,

        init: function() {
          if (this._initialized) return;
          this._initialized = true;
          this.state = JSON.parse(window.localStorage.getItem('infinitude-serial-state') || '{}');
          this.reloadData(false);
          setInterval(this.reloadData.bind(this, false), 3 * 60 * 1000);
          this.initSerial();

          var self = this;
          window.addEventListener('hashchange', function() {
            self.currentRoute = window.location.hash.replace('#', '') || '/';
          });
        },

        isActive: function(route) { return route === this.currentRoute; },

        mkTime: function(input) {
          if (input && typeof input === 'object' && Object.keys(input).length === 0) return '00:00';
          return input;
        },

        typeofVar: function(v) { return typeof v; },

        equals: function(a, b) { return JSON.stringify(a) === JSON.stringify(b); },

        reloadData: function(userInitiated) {
          if (userInitiated && this.systemsEdited) {
            if (!confirm('This will erase your unsaved changes')) return;
            this.systemsEdited = null;
          }
          var self = this;
          var store = JSON.parse(window.localStorage.getItem('infinitude') || '{}');
          var keys = ['systems', 'status', 'notifications', 'energy'];
          keys.forEach(function(key) {
            if (self.systemsEdited !== true) self.globeColor = GLOBE_LOADING;
            fetch('/' + key + '.json')
              .then(function(r) { return r.json(); })
              .then(function(data) {
                var rkey = key === 'systems' ? 'system' : key;
                var val = data[rkey][0];
                if (key === 'systems') {
                  self.systems = val;
                  if (self.systemsEdited === null || self.systemsEdited === false) {
                    self.systemsEdit = JSON.parse(JSON.stringify(val));
                  }
                } else {
                  self[key] = val;
                }
                store[key] = val;
                if (self.systemsEdited !== true) self.globeColor = GLOBE_CONNECTED;
                clearTimeout(self._globeTimer);
                self._globeTimer = setTimeout(function() { self.globeColor = GLOBE_ERROR; }, 4 * 60 * 1000);
              })
              .catch(function() { self.globeColor = GLOBE_ERROR; });
          });
          try { window.localStorage.setItem('infinitude', JSON.stringify(store)); } catch(e) {}
        },

        markDirty: function() {
          if (this.systemsEdit !== null) {
            if (this.systemsEdited === null || this.equals(this.systems, this.systemsEdit)) {
              this.systemsEdited = false;
              this.globeColor = GLOBE_CONNECTED;
            } else if (this.systemsEdited === false) {
              this.systemsEdited = true;
              this.globeColor = GLOBE_UNSAVED;
            }
          }
        },

        save: function() {
          this.systems = JSON.parse(JSON.stringify(this.systemsEdit));
          var self = this;
          fetch('/systems/infinitude', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ system: [this.systemsEdit] })
          }).then(function() {
            setTimeout(function() { self.reloadData(false); }, 10000);
            self.systemsEdited = false;
            self.globeColor = GLOBE_CONNECTED;
          }).catch(function() { console.log('Save failed'); });
        },

        samreq: function(reg) {
          fetch('/api/samreq', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ register: reg })
          }).then(function(r) { return r.json(); }).then(function(d) { console.log(d.frame_hex); });
        },

        selectZone: function(zone) { this.selectedZone = zone; },

        // --- Gauge rendering (canvas-gauges) ---

        gaugeTypes: {
          temperature: {
            cls: 'LinearGauge',
            width: 80, height: 220,
            minValue: 30, maxValue: 100,
            units: '\u00B0',
            colorBarProgress: '#0000FF',
            colorBarProgressEnd: '#FF2010'
          },
          percentage: {
            cls: 'RadialGauge',
            minValue: 0, maxValue: 100,
            units: '%',
            colorBarProgress: '#00FF00',
            colorBarProgressEnd: '#FF0000'
          },
          rpm: {
            cls: 'RadialGauge',
            minValue: 0, maxValue: 1200,
            units: 'RPM',
            colorBarProgress: '#00FF00',
            colorBarProgressEnd: '#FF0000'
          },
          cfm: {
            cls: 'RadialGauge',
            minValue: 0, maxValue: 2000,
            units: 'CFM',
            colorBarProgress: '#00FF00',
            colorBarProgressEnd: '#FF0000'
          },
          hpStage: {
            cls: 'RadialGauge',
            minValue: 0, maxValue: 5,
            colorBarProgress: '#00FF00',
            colorBarProgressEnd: '#FF0000'
          },
          ehStage: {
            cls: 'RadialGauge',
            minValue: 0, maxValue: 3,
            colorBarProgress: '#00FF00',
            colorBarProgressEnd: '#FF0000'
          },
          damper: {
            cls: 'RadialGauge',
            minValue: 0, maxValue: 15,
            colorBarProgress: '#FF0000',
            colorBarProgressEnd: '#00FF00'
          }
        },

        renderGauge: function(el, value, typeName, overrides) {
          if (!el) return;
          var preset = this.gaugeTypes[typeName] || {};
          var opts = Object.assign({}, preset, overrides || {});
          if (!el._gauge) {
            var canvas = document.createElement('canvas');
            el.appendChild(canvas);
            var Cls = opts.cls === 'LinearGauge' ? LinearGauge : RadialGauge;
            el._gauge = new Cls(Object.assign({
              renderTo: canvas,
              width: 180, height: 180,
              minValue: 0, maxValue: 100,
              barWidth: 12,
              borderShadowWidth: 0,
              borders: false,
              valueBox: true,
              valueDec: 0,
              animateOnInit: true,
              animationDuration: 500,
              animationRule: 'linear'
            }, opts)).draw();
          }
          el._gauge.value = Number(value) || 0;
        },

        renderGauges: function() {
          if (!this.status || !this.status.zones || !this.status.zones[0]) return;
          var s = this.status, cb = this.carbus;
          if (s.zones[0].zone[0].rh)
            this.renderGauge(this.$refs.gaugeHumidity, s.zones[0].zone[0].rh[0], 'percentage', { title:'Humidity' });
          if (s.oat && (s.oat[0] || cb.outsideTemp)) {
            var oval = cb.outsideTemp || s.oat[0];
            if (s.cfgem && s.cfgem[0] === 'C') oval = (oval - 32) * 5 / 9;
            this.renderGauge(this.$refs.gaugeOutside, oval, 'temperature', { title:'Outside' });
          }
          if (s.odu && s.odu[0].type[0].includes('proteus'))
            this.renderGauge(this.$refs.gaugeHPStage, s.odu[0].opstat[0] === 'off' ? 0 : Number(s.odu[0].opstat[0].replace('Stage ','').replace('dehumidify','1')), 'hpStage', { title:'HP Stage' });
          if (s.idu && s.idu[0].type[0].includes('electric'))
            this.renderGauge(this.$refs.gaugeEHtStage, Number(s.idu[0].opstat[0].replace('off','0').replace('low','1').replace('med','2').replace('high','3')), 'ehStage', { title:'E. Ht. Stage' });
          if (cb.coilTemp)
            this.renderGauge(this.$refs.gaugeCoil, cb.coilTemp, 'temperature', { title:'Coil' });
          if (cb.airflowCFM || (s.idu && s.idu[0].cfm[0]))
            this.renderGauge(this.$refs.gaugeAirflow, cb.airflowCFM || s.idu[0].cfm[0], 'cfm', { title:'Airflow', maxValue: Number(this.systems.config[0].systemCFM[0]) });
          if (cb.blowerRPM)
            this.renderGauge(this.$refs.gaugeBlower, cb.blowerRPM, 'rpm', { title:'Blower speed' });
          if (s.filtrlvl)
            this.renderGauge(this.$refs.gaugeFilter, s.filtrlvl[0], 'percentage', { title:'Fltr. Usage' });
          if (this.systems && this.systems.config[0].cfgvent[0] && s.ventlvl)
            this.renderGauge(this.$refs.gaugeVent, s.ventlvl[0], 'percentage', { title:'Vent. Usage' });
        },

        renderZoneGauges: function(zi) {
          if (!this.status || !this.status.zones) return;
          var zone = this.status.zones[0].zone[zi];
          if (!zone || zone.enabled[0] !== 'on') return;
          this.renderGauge(this.$refs['gaugeZoneInside_' + zi], zone.rt[0], 'temperature', { title:'Inside' });
          this.renderGauge(this.$refs['gaugeZoneHeat_' + zi], zone.htsp[0], 'temperature', { title:'Heat Setpoint' });
          this.renderGauge(this.$refs['gaugeZoneCool_' + zi], zone.clsp[0], 'temperature', { title:'Cool Setpoint' });
          if (this.systems && this.systems.config[0].cfgzoning[0] === 'on' && zone.damperposition)
            this.renderGauge(this.$refs['gaugeZoneDamper_' + zi], zone.damperposition[0], 'damper', { title:'Dmpr. Pos.' });
        },

        // --- Serial / WebSocket ---

        initSerial: function() {
          var self = this;
          var ws = new WebSocket(wsu('/serial'));
          ws.onopen = function() { console.log('Socket open'); };
          ws.onclose = function() { console.log('Socket closed'); window.location.reload(); };
          ws.onerror = function(err) { console.log('Socket error', err); };
          ws.onmessage = function(m) {
            var frame = JSON.parse(m.data);
            if (typeof frame.cmd != 'string') { console.log(frame); return; }
            self.transferColor = '#4F4';
            clearTimeout(self._transferTimer);
            self._transferTimer = setTimeout(function() { self.transferColor = '#5E5'; }, 2000);

            var payloadBytes = frame.payload_raw.split('').map(function(c) { return c.charCodeAt(0); });
            var dv = new DataView(new Uint8Array(payloadBytes).buffer);
            self.history = JSON.parse(window.localStorage.getItem('tmpdat') || '{}');

            if (frame.cmd.match(/write|reply/)) {
              var address = (frame.reg_string || '').toUpperCase();
              var id = frame.cmd + frame.src + frame.dst + address;
              frame.Device = frame.cmd === 'reply' ? frame.src : frame.dst;
              self.devices[frame.Device] = 1;

              function busLog(key, value) {
                self.history[key] = self.history[key] || [{ key: key, values: [] }];
                self.history[key][0].values.push([frame.timestamp, value]);
                if (self.history[key][0].values.length > 500) self.history[key][0].values.shift();
                try { window.localStorage.setItem('tmpdat', JSON.stringify(self.history)); } catch(e) {}
              }

              if (frame.cmd == 'reply' && frame.src.match(/IndoorUnit/)) {
                if (address.match(/0306/)) { self.carbus.blowerRPM = dv.getInt16(1 + 3); busLog('blowerRPM', self.carbus.blowerRPM); }
                if (address.match(/0316/)) { self.carbus.airflowCFM = dv.getInt16(4 + 3); busLog('airflowCFM', self.carbus.airflowCFM); }
              }
              if (frame.cmd == 'reply' && frame.src.match(/OutdoorUnit/)) {
                if (address.match(/0302/)) { self.carbus.outsideTemp = dv.getInt16(2 + 3) / 16; }
                if (address.match(/3E01/)) {
                  self.carbus.outsideTemp = dv.getInt16(0 + 3) / 16;
                  self.carbus.coilTemp = dv.getInt16(2 + 3) / 16;
                  busLog('coilTemp', self.carbus.coilTemp);
                  busLog('outsideTemp', self.carbus.outsideTemp);
                }
              }

              var lastframe = (self.state[id] || {}).payload_raw;
              self.state[id] = self.state[id] || {};
              Object.assign(self.state[id], frame);
              self.state[id].history = self.state[id].history || [];
              if (lastframe !== frame.payload_raw) self.state[id].history.unshift(lastframe);
              if (self.state[id].history.length > 9) self.state[id].history.pop();
              try { window.localStorage.setItem('infinitude-serial-state', JSON.stringify(self.state)); } catch(e) {}
            }

            self.frames.push(frame);
            if (self.frames.length > 9) self.frames.shift();
          };
        },

        // --- Serial view helpers ---

        timeAgo: function(timestamp) {
          var seconds = Math.floor(Date.now() / 1000 - timestamp);
          if (seconds < 60) return seconds + 's ago';
          if (seconds < 3600) return Math.floor(seconds / 60) + 'm ago';
          if (seconds < 86400) return Math.floor(seconds / 3600) + 'h ago';
          return Math.floor(seconds / 86400) + 'd ago';
        },

        renderNodeTree: function(node, depth) {
          if (!node || typeof node !== 'object' || depth > 4) return '';
          depth = depth || 0;
          var html = '<table class="table table-striped table-bordered table-rounded"><tbody>';
          for (var k in node) {
            if (!node.hasOwnProperty(k)) continue;
            html += '<tr><th class="text-right">' + k + '</th>';
            if (typeof node[k] === 'string' || typeof node[k] === 'number') {
              html += '<td>' + node[k] + '</td>';
            } else if (typeof node[k] === 'object' && depth <= 3) {
              html += '<td>' + this.renderNodeTree(node[k], depth + 1) + '</td>';
            }
            html += '</tr>';
          }
          html += '</tbody></table>';
          return html;
        },

        serialFrames: function() {
          var self = this;
          return this.frames.filter(function(f) {
            return (!self.srcFilter || (f.src && f.src.includes(self.srcFilter))) &&
                   (!self.dstFilter || (f.dst && f.dst.includes(self.dstFilter))) &&
                   (!self.cmdFilter || (f.cmd && f.cmd.includes(self.cmdFilter))) &&
                   (!self.regFilter || (f.reg_string && f.reg_string.includes(self.regFilter)));
          });
        },

        sortedState: function() {
          return Object.values(this.state).sort(function(a, b) {
            return (a.Device || '').localeCompare(b.Device || '') ||
                   (a.cmd || '').localeCompare(b.cmd || '') ||
                   (a.reg_string || '').localeCompare(b.reg_string || '');
          });
        }
      };
    });
  });
})();
