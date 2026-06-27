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
        activeSchedulePeriods: {},  // "zi-di" -> period index or null
        activeScheduleCopy: null,    // "zi-di" or null

        // UI state
        darkMode: window.matchMedia('(prefers-color-scheme: dark)').matches,
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
          window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function(e) {
            self.darkMode = e.matches;
            self.rebuildGauges();
          });
        },

        isActive: function(route) { return route === this.currentRoute; },

        equals: function(a, b) { return JSON.stringify(a) === JSON.stringify(b); },

        getCurrentActivity: function(zi) {
          if (!this.status || !this.status.zones || !this.systemsEdit) return null;
          var zone = this.status.zones[0].zone[zi];
          if (!zone) return null;
          var name = zone.currentActivity[0];
          if (name === 'vacation') return null;
          var editZone = this.systemsEdit.config[0].zones[0].zone[zi];
          if (!editZone) return null;
          return editZone.activities[0].activity.find(function(a) { return a.id === name; });
        },

        adjustSetpoint: function(zi, field, delta) {
          var act = this.getCurrentActivity(zi);
          if (!act) return;
          var val = parseFloat(act[field][0]) || 0;
          act[field][0] = (val + delta * this.tempStep()).toFixed(this.tempDecimals());
          this.markDirty();
        },

        setZoneFan: function(zi, fan) {
          var act = this.getCurrentActivity(zi);
          if (!act) return;
          act.fan[0] = fan;
          this.markDirty();
        },

        adjustActivitySp: function(activity, field, delta) {
          if (!activity) return;
          var val = parseFloat(activity[field][0]) || 0;
          activity[field][0] = (val + delta * this.tempStep()).toFixed(this.tempDecimals());
          this.markDirty();
        },

        adjustVacSp: function(field, delta) {
          var val = parseFloat(this.systemsEdit.config[0][field][0]) || 0;
          this.systemsEdit.config[0][field][0] = (val + delta * this.tempStep()).toFixed(this.tempDecimals());
          this.markDirty();
        },

        isCelsius: function() {
          var cfgem = this.status && this.status.cfgem;
          return cfgem && cfgem[0] === 'C';
        },
        tempDecimals: function() { return this.isCelsius() ? 1 : 0; },
        tempStep:     function() { return this.isCelsius() ? 0.5 : 1; },
        // Convert raw °F from CarBus to display units. Do NOT use for API values
        // (status.oat, zone.rt, etc.) which are already in the user's unit.
        busToDisplay: function(f) { return this.isCelsius() ? (f - 32) * 5 / 9 : f; },

        getZoneTemp: function(zone) {
          if (!zone || !zone.rt || typeof zone.rt[0] !== 'string') return '--';
          return parseFloat(zone.rt[0]).toFixed(this.tempDecimals());
        },

        fmtSp: function(val) {
          return parseFloat(val).toFixed(this.tempDecimals());
        },

        isoToLocal: function(iso) {
          if (!iso) return '';
          var d = new Date(iso);
          if (isNaN(d.getTime())) return iso.replace(/:\d{2}(Z|[+-]\d{2}:?\d{2})?$/, '');
          var pad = function(n) { return String(n).padStart(2, '0'); };
          return d.getFullYear() + '-' + pad(d.getMonth()+1) + '-' + pad(d.getDate()) + 'T' + pad(d.getHours()) + ':' + pad(d.getMinutes());
        },
        localToIso: function(local) {
          if (!local) return '';
          // Snap minutes to nearest 15
          var m = parseInt(local.slice(14, 16));
          var snapped = Math.round(m / 15) * 15;
          if (snapped >= 60) snapped = 45;
          var pad = function(n) { return String(n).padStart(2, '0'); };
          local = local.slice(0, 14) + pad(snapped);
          var d = new Date(local);
          if (isNaN(d.getTime())) return local;
          return d.toISOString().replace('.000', '');
        },

        defaultVacDates: function() {
          var now = new Date();
          var m = Math.ceil((now.getMinutes() + 1) / 15) * 15;
          var start = new Date(now);
          start.setMinutes(m, 0, 0);
          if (m >= 60) start.setHours(start.getHours() + 1);
          var end = new Date(start.getTime() + 24 * 60 * 60 * 1000);
          var pad = function(n) { return String(n).padStart(2, '0'); };
          var fmt = function(d) { return d.getFullYear() + '-' + pad(d.getMonth()+1) + '-' + pad(d.getDate()) + 'T' + pad(d.getHours()) + ':' + pad(d.getMinutes()); };
          this.systemsEdit.config[0].vacstart = [fmt(start)];
          this.systemsEdit.config[0].vacend = [fmt(end)];
          this.markDirty();
        },

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
                  // Only update if data actually changed to avoid unnecessary repaints
                  if (JSON.stringify(self[key]) !== JSON.stringify(val)) {
                    self[key] = val;
                  }
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
            if (this.equals(this.systems, this.systemsEdit)) {
              this.systemsEdited = false;
              this.globeColor = GLOBE_CONNECTED;
            } else {
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

        _gaugeTypes: {
          temperature: {
            cls: 'LinearGauge',
            width: 80, height: 220,
            minValue: 30, maxValue: 100,
            majorTicks: [30, 40, 50, 60, 70, 80, 90, 100],
            units: '\u00B0',
            colorBarProgress: '#0000FF',
            colorBarProgressEnd: '#FF2010'
          },
          percentage: {
            cls: 'RadialGauge',
            minValue: 0, maxValue: 100,
            majorTicks: [0, 20, 40, 60, 80, 100],
            units: '%',
            colorBarProgress: '#00FF00',
            colorBarProgressEnd: '#FF0000'
          },
          rpm: {
            cls: 'RadialGauge',
            minValue: 0, maxValue: 1200,
            majorTicks: [0, 200, 400, 600, 800, 1000, 1200],
            units: 'RPM',
            colorBarProgress: '#00FF00',
            colorBarProgressEnd: '#FF0000'
          },
          cfm: {
            cls: 'RadialGauge',
            minValue: 0, maxValue: 2000,
            majorTicks: [0, 400, 800, 1200, 1600, 2000],
            units: 'CFM',
            colorBarProgress: '#00FF00',
            colorBarProgressEnd: '#FF0000'
          },
          hpStage: {
            cls: 'RadialGauge',
            minValue: 0, maxValue: 5,
            majorTicks: [0, 1, 2, 3, 4, 5],
            colorBarProgress: '#00FF00',
            colorBarProgressEnd: '#FF0000'
          },
          ehStage: {
            cls: 'RadialGauge',
            minValue: 0, maxValue: 3,
            majorTicks: [0, 1, 2, 3],
            colorBarProgress: '#00FF00',
            colorBarProgressEnd: '#FF0000'
          },
          damper: {
            cls: 'RadialGauge',
            minValue: 0, maxValue: 15,
            majorTicks: [0, 5, 10, 15],
            colorBarProgress: '#FF0000',
            colorBarProgressEnd: '#00FF00'
          }
        },

        gaugeType: function(name) {
          var t = this._gaugeTypes[name];
          if (!t) return {};
          if (name === 'temperature' && this.isCelsius()) {
            return Object.assign({}, t, {
              minValue: -1, maxValue: 45,
              majorTicks: [-1, 5, 10, 15, 20, 25, 30, 35, 40, 45],
              valueDec: 1
            });
          }
          return t;
        },

        gaugeTheme: function() {
          return this.darkMode
            ? { plateColor: '#1a1a2e', colorPlate: '#1a1a2e', colorMajorTicks: '#aaa', colorMinorTicks: '#555', colorTitle: '#ccc', colorUnits: '#888', colorNumbers: '#aaa', colorValueText: '#eee', colorValueBoxBackground: '#0c1520', colorValueBoxShadow: false, colorNeedle: '#ddd', colorNeedleEnd: '#999', colorBarStroke: '#333' }
            : { plateColor: '#ffffff', colorPlate: '#ffffff', colorMajorTicks: '#333', colorMinorTicks: '#bbb', colorTitle: '#333', colorUnits: '#777', colorNumbers: '#333', colorValueText: '#111', colorValueBoxBackground: '#f5f5f5', colorValueBoxShadow: false, colorNeedle: '#333', colorNeedleEnd: '#666', colorBarStroke: '#ccc' };
        },

        renderGauge: function(el, value, typeName, overrides) {
          if (!el) return;
          var preset = this.gaugeType(typeName);
          var opts = Object.assign({}, preset, overrides || {}, this.gaugeTheme());
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
          } else {
            Object.assign(el._gauge.options, opts);
            el._gauge.update();
          }
          el._gauge.value = Number(value) || 0;
        },

        rebuildGauges: function() {
          // Destroy all gauge canvases so they get recreated with new theme colors
          document.querySelectorAll('canvas').forEach(function(c) {
            var parent = c.parentElement;
            if (parent && parent._gauge) {
              parent._gauge.destroy();
              delete parent._gauge;
              parent.innerHTML = '';
            }
          });
        },

        renderGauges: function() {
          if (!this.status || !this.status.zones || !this.status.zones[0]) return;
          var s = this.status, cb = this.carbus;
          if (s.zones[0].zone[0].rh)
            this.renderGauge(this.$refs.gaugeHumidity, s.zones[0].zone[0].rh[0], 'percentage', { title:'Humidity' });
          if (s.oat && (s.oat[0] || cb.outsideTemp)) {
            // cb.outsideTemp is raw °F from CarBus; s.oat[0] is from API in user's unit
            var oval = cb.outsideTemp ? this.busToDisplay(cb.outsideTemp) : s.oat[0];
            this.renderGauge(this.$refs.gaugeOutside, oval, 'temperature', { title:'Outside' });
          }
          if (s.odu && s.odu[0].type[0].includes('proteus'))
            this.renderGauge(this.$refs.gaugeHPStage, s.odu[0].opstat[0] === 'off' ? 0 : Number(s.odu[0].opstat[0].replace('Stage ','').replace('dehumidify','1')), 'hpStage', { title:'HP Stage' });
          if (s.idu && s.idu[0].type[0].includes('electric'))
            this.renderGauge(this.$refs.gaugeEHtStage, Number(s.idu[0].opstat[0].replace('off','0').replace('low','1').replace('med','2').replace('high','3')), 'ehStage', { title:'E. Ht. Stage' });
          if (cb.coilTemp)
            this.renderGauge(this.$refs.gaugeCoil, this.busToDisplay(cb.coilTemp), 'temperature', { title:'Coil' });
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
          this.renderGauge(this.$refs['gaugeZoneInside_' + zi], Number(zone.rt[0]), 'temperature', { title:'Inside' });
          this.renderGauge(this.$refs['gaugeZoneHeat_' + zi], Number(zone.htsp[0]), 'temperature', { title:'Heat Setpoint' });
          this.renderGauge(this.$refs['gaugeZoneCool_' + zi], Number(zone.clsp[0]), 'temperature', { title:'Cool Setpoint' });
          if (this.systems && this.systems.config[0].cfgzoning[0] === 'on' && zone.damperposition)
            this.renderGauge(this.$refs['gaugeZoneDamper_' + zi], zone.damperposition[0], 'damper', { title:'Dmpr. Pos.' });
        },

        // --- Serial / WebSocket ---

        initSerial: function() {
          var self = this;
          try {
            var ws = new WebSocket(wsu('/serial'));
            ws.onopen = function() { console.log('Socket open'); };
            ws.onclose = function() { console.log('Socket closed'); };
            ws.onerror = function(err) { console.log('Socket error', err); };
          } catch(e) {
            console.log('WebSocket not available');
          }
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
        },

        // --- Schedule helpers ---

        timeToMinutes: function(timeStr) {
          if (!timeStr || typeof timeStr !== 'string') return 0;
          var parts = timeStr.split(':');
          return parseInt(parts[0]) * 60 + parseInt(parts[1]);
        },

        snapTime: function(timeStr) {
          var total = this.timeToMinutes(timeStr);
          var snapped = Math.round(total / 15) * 15;
          if (snapped >= 1440) snapped = 1425;
          var h = Math.floor(snapped / 60);
          var m = snapped % 60;
          return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m;
        },

        enablePeriod: function(day, periodIndex) {
          var period = day.period[periodIndex];
          if (!period || period.enabled[0] === 'on') return;
          var self = this;
          var thisTime = self.timeToMinutes(period.time[0]);
          // Find times of enabled periods before and after this one (by original order)
          var beforeTime = null, afterTime = null;
          for (var i = periodIndex - 1; i >= 0; i--) {
            if (day.period[i].enabled[0] === 'on') { beforeTime = self.timeToMinutes(day.period[i].time[0]); break; }
          }
          for (var j = periodIndex + 1; j < day.period.length; j++) {
            if (day.period[j].enabled[0] === 'on') { afterTime = self.timeToMinutes(day.period[j].time[0]); break; }
          }
          var defaultMin;
          if (beforeTime !== null && afterTime !== null) {
            defaultMin = Math.round((beforeTime + afterTime) / 2 / 15) * 15; // midpoint, snapped to 15min
          } else if (beforeTime !== null) {
            defaultMin = Math.min(beforeTime + 120, 1440); // 2 hours after previous
          } else if (afterTime !== null) {
            defaultMin = Math.max(afterTime - 120, 0); // 2 hours before next
          } else {
            defaultMin = 720; // noon
          }
          var h = Math.floor(defaultMin / 60);
          var m = defaultMin % 60;
          period.time = [(h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m];
          period.enabled = ['on'];
          this.markDirty();
        },

        firstDisabledPeriod: function(day) {
          if (!day || !day.period) return null;
          for (var i = 0; i < day.period.length; i++) {
            if (day.period[i].enabled[0] !== 'on') return i;
          }
          return null;
        },

        scheduleRangeStart: function(zone) {
          if (!zone || !zone.program || !zone.program[0] || !zone.program[0].day) return 240;
          var self = this;
          var minTime = 1440;
          zone.program[0].day.forEach(function(day) {
            if (!day.period) return;
            day.period.forEach(function(p) {
              if (p.enabled[0] === 'on') {
                var t = self.timeToMinutes(p.time[0]);
                if (t < minTime) minTime = t;
              }
            });
          });
          // Subtract 1 hour padding, round down to nearest hour, minimum 0
          return Math.max(0, Math.floor((minTime - 60) / 60) * 60);
        },

        scheduleItems: function(day, start) {
          if (!day || !day.period) return [];
          var START = start || 0;
          var RANGE = 1440 - START;
          if (RANGE <= 0) RANGE = 1440;
          var self = this;
          // Only return enabled periods, sorted by time
          var enabled = [];
          for (var i = 0; i < day.period.length; i++) {
            if (day.period[i].enabled[0] === 'on') {
              enabled.push({ period: day.period[i], index: i });
            }
          }
          enabled.sort(function(a, b) { return self.timeToMinutes(a.period.time[0]) - self.timeToMinutes(b.period.time[0]); });
          var items = [];
          for (var j = 0; j < enabled.length; j++) {
            var s = self.timeToMinutes(enabled[j].period.time[0]);
            var e = (j + 1 < enabled.length) ? self.timeToMinutes(enabled[j + 1].period.time[0]) : 1440;
            if (e > s) {
              items.push({
                index: enabled[j].index,
                activity: enabled[j].period.activity[0],
                time: enabled[j].period.time[0],
                enabled: true,
                left: (s - START) / RANGE * 100,
                width: (e - s) / RANGE * 100
              });
            }
          }
          return items;
        },

        // Sort enabled periods by time ascending, disabled to end, reassign slot IDs.
        // Optional zi/di to update activeSchedulePeriods index after sort.
        sortDayPeriods: function(day, zi, di) {
          if (!day || !day.period || day.period.length === 0) return;
          var self = this;
          var key = (zi !== undefined && di !== undefined) ? zi + '-' + di : null;
          var activeIdx = key ? self.activeSchedulePeriods[key] : null;
          var activePeriod = (activeIdx != null && activeIdx < day.period.length) ? day.period[activeIdx] : null;

          var sorted = day.period.slice().sort(function(a, b) {
            var aOn = a.enabled[0] === 'on';
            var bOn = b.enabled[0] === 'on';
            if (aOn !== bOn) return aOn ? -1 : 1;
            if (!aOn) return 0;
            return self.timeToMinutes(a.time[0]) - self.timeToMinutes(b.time[0]);
          });

          // Reassign slot IDs to match the new order
          for (var i = 0; i < sorted.length; i++) {
            sorted[i].id = [String(i + 1)];
          }

          day.period = sorted;

          // Track the active period to its new index
          if (activePeriod) {
            for (var j = 0; j < day.period.length; j++) {
              if (day.period[j] === activePeriod) {
                self.activeSchedulePeriods[key] = j;
                break;
              }
            }
          }
        },

        copyScheduleDay: function(zone, sourceDi, targetDi) {
          if (sourceDi === targetDi) return;
          var sourceDay = zone.program[0].day[sourceDi];
          zone.program[0].day[targetDi].period = JSON.parse(JSON.stringify(sourceDay.period));
          this.sortDayPeriods(zone.program[0].day[targetDi]);
          this.markDirty();
        },

        copyScheduleToDays: function(zone, sourceDi, dayIndices) {
          var self = this;
          dayIndices.forEach(function(di) {
            if (di !== sourceDi) self.copyScheduleDay(zone, sourceDi, di);
          });
        }
      };
    });
  });
})();
