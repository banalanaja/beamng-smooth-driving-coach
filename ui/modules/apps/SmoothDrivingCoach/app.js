(function () {
  'use strict';

  angular.module('beamng.apps')
    .directive('smoothDrivingCoach', [function () {
      return {
        template:
          '<div class="bngApp sdc-root">' +
            '<link type="text/css" rel="stylesheet" href="/ui/modules/apps/SmoothDrivingCoach/app.css">' +
            '<div class="sdc-main">' +
              '<div class="sdc-left">' +
                '<div class="sdc-radar-wrap">' +
                  '<canvas class="sdc-radar-canvas" width="160" height="160"></canvas>' +
                '</div>' +
                '<div class="sdc-incline-row">' +
                  '<span>P <span class="sdc-incline-val">{{ state.pitchStr }}</span></span>' +
                  '<span>R <span class="sdc-incline-val">{{ state.rollStr }}</span></span>' +
                '</div>' +
              '</div>' +
              '<div class="sdc-right">' +
                '<div class="sdc-header">' +
                  '<div class="sdc-score-block">' +
                    '<span class="sdc-label">Suavidade</span>' +
                    '<span class="sdc-score-val" ng-class="scoreColorClass()">{{ state.scoreStr }}%</span>' +
                  '</div>' +
                  '<div class="sdc-metrics">' +
                    '<span>G <span class="sdc-metric-num">{{ state.gStr }}</span></span>' +
                    '<span>J <span class="sdc-metric-num" ng-class="zoneColorClass()">{{ state.jerkStr }}</span></span>' +
                  '</div>' +
                  '<div class="sdc-actions">' +
                    '<button class="sdc-icon-btn" title="Alerta sonoro (Mudo/Ativo)" ng-click="toggleMute($event)">' +
                      '{{ muted ? "🔇" : "🔊" }}' +
                    '</button>' +
                    '<button class="sdc-icon-btn" title="Zerar nota de suavidade" ng-click="resetScore($event)">' +
                      '↺' +
                    '</button>' +
                  '</div>' +
                '</div>' +
                '<div class="sdc-graph-wrap">' +
                  '<canvas class="sdc-graph-canvas" width="210" height="72"></canvas>' +
                  '<div class="sdc-graph-legend">' +
                    '<span class="sdc-legend-g">■ G-Force (0.5g)</span>' +
                    '<span class="sdc-legend-jerk">■ Tranco/Jerk (2g/s)</span>' +
                  '</div>' +
                '</div>' +
              '</div>' +
            '</div>' +
            '<div class="sdc-diag-bar" ng-class="diagBorderClass()">' +
              '<span class="sdc-diag-cat" ng-class="diagTextClass()">{{ state.category }}</span>' +
              '<span class="sdc-diag-text" title="{{ state.diagnosis }}">{{ state.diagnosis }}</span>' +
            '</div>' +
          '</div>',
        replace: true,
        restrict: 'EA',
        link: function (scope, element) {
          var streamsList = ['sensors', 'electrics'];
          StreamsManager.add(streamsList);

          var ensureVehicleExtension = function () {
            if (typeof bngApi !== 'undefined' && bngApi.activeObjectLua) {
              bngApi.activeObjectLua(
                'if not smoothDrivingCoach then extensions.loadAtRoot("lua/vehicle/extensions/auto/smoothDrivingCoach", "") end'
              );
            }
          };

          ensureVehicleExtension();

          scope.muted = localStorage.getItem('apps:smoothDrivingCoach.muted') === 'true';

          scope.state = {
            score: 100,
            scoreStr: '100',
            gHoriz: 0,
            gLon: 0,
            gLat: 0,
            gStr: '0.00g',
            jerkTotal: 0,
            jerkStr: '0.0g/s',
            pitchDeg: 0,
            rollDeg: 0,
            suspPitchDeg: 0,
            pitchStr: '+0.0°',
            rollStr: '+0.0°',
            zone: 'green',
            category: 'OK',
            diagnosis: 'Condução suave',
            diagSeverity: 'green'
          };

          scope.scoreColorClass = function () {
            if (scope.state.score >= 85) return 'sdc-zone-green';
            if (scope.state.score >= 65) return 'sdc-zone-amber';
            return 'sdc-zone-red';
          };

          scope.zoneColorClass = function () {
            if (scope.state.zone === 'red') return 'sdc-zone-red';
            if (scope.state.zone === 'amber') return 'sdc-zone-amber';
            return 'sdc-zone-green';
          };

          scope.diagTextClass = function () {
            if (scope.state.diagSeverity === 'red') return 'sdc-zone-red';
            if (scope.state.diagSeverity === 'amber') return 'sdc-zone-amber';
            return 'sdc-zone-green';
          };

          scope.diagBorderClass = function () {
            if (scope.state.diagSeverity === 'red') return 'sdc-border-red';
            if (scope.state.diagSeverity === 'amber') return 'sdc-border-amber';
            return 'sdc-border-green';
          };

          // Subtle Web Audio API synthesizer for non-distracting coaching beeps
          var audioCtx = null;
          var playAlertBeep = function (severity) {
            if (scope.muted) return;
            try {
              var AudioContextClass = window.AudioContext || window.webkitAudioContext;
              if (!AudioContextClass) return;
              if (!audioCtx) {
                audioCtx = new AudioContextClass();
              }
              if (audioCtx.state === 'suspended') {
                audioCtx.resume();
              }

              var now = audioCtx.currentTime;
              var osc = audioCtx.createOscillator();
              var gain = audioCtx.createGain();
              osc.connect(gain);
              gain.connect(audioCtx.destination);

              if (severity === 'red') {
                osc.type = 'triangle';
                osc.frequency.setValueAtTime(440, now);
                osc.frequency.setValueAtTime(330, now + 0.055);
                gain.gain.setValueAtTime(0.001, now);
                gain.gain.exponentialRampToValueAtTime(0.085, now + 0.01);
                gain.gain.exponentialRampToValueAtTime(0.001, now + 0.13);
                osc.start(now);
                osc.stop(now + 0.135);
              } else {
                osc.type = 'sine';
                osc.frequency.setValueAtTime(540, now);
                gain.gain.setValueAtTime(0.001, now);
                gain.gain.exponentialRampToValueAtTime(0.055, now + 0.01);
                gain.gain.exponentialRampToValueAtTime(0.001, now + 0.075);
                osc.start(now);
                osc.stop(now + 0.08);
              }
            } catch (e) {
              // Ignore audio errors if context is blocked
            }
          };

          scope.toggleMute = function ($event) {
            if ($event && $event.stopPropagation) $event.stopPropagation();
            scope.muted = !scope.muted;
            localStorage.setItem('apps:smoothDrivingCoach.muted', scope.muted ? 'true' : 'false');
          };

          scope.resetScore = function ($event) {
            if ($event && $event.stopPropagation) $event.stopPropagation();
            scope.state.score = 100;
            scope.state.scoreStr = '100';
            scope.state.category = 'OK';
            scope.state.diagnosis = 'Condução suave';
            scope.state.diagSeverity = 'green';
            if (typeof bngApi !== 'undefined' && bngApi.activeObjectLua) {
              bngApi.activeObjectLua('if smoothDrivingCoach then smoothDrivingCoach.resetScore() end');
            }
          };

          // Setup Radar Canvas ("Copo d'Água" / G-Ball + Tilt Horizon)
          var radarCanvas = element[0].querySelector('.sdc-radar-canvas');
          var rCtx = radarCanvas.getContext('2d');
          var trail = [];
          var maxTrail = 28;
          var maxRadarG = 0.50; // 0.50g full scale for smooth driving precision (inner ring = 0.25g)
          var radarRadius = 72;

          var drawRadar = function (gLat, gLon, jerkTotal, pitchDeg, rollDeg, zone) {
            var w = radarCanvas.width;
            var h = radarCanvas.height;
            rCtx.setTransform(1, 0, 0, 1, 0, 0);
            rCtx.clearRect(0, 0, w, h);
            rCtx.setTransform(w / 160, 0, 0, h / 160, w / 2, h / 2);

            // Outer background circle (vanilla gForcesDebug style)
            rCtx.fillStyle = 'rgba(0, 0, 0, 0.38)';
            rCtx.strokeStyle = 'rgba(63, 63, 63, 0.65)';
            rCtx.lineWidth = 1.5;
            rCtx.beginPath();
            rCtx.arc(0, 0, radarRadius, 0, 2 * Math.PI, false);
            rCtx.fill();
            rCtx.stroke();

            // Inner comfort ring (0.25g threshold)
            var innerR = radarRadius * 0.5;
            rCtx.strokeStyle = 'rgba(168, 221, 115, 0.35)';
            rCtx.lineWidth = 1.2;
            rCtx.beginPath();
            rCtx.arc(0, 0, innerR, 0, 2 * Math.PI, false);
            rCtx.stroke();

            // Subtle artificial horizon line representing Pitch & Roll
            var pitchOffset = Math.max(-1, Math.min(1, pitchDeg / 20)) * (radarRadius * 0.55);
            var rollRad = (rollDeg * Math.PI) / 180;
            var horizHalfSpan = radarRadius * 0.65;
            var hx1 = -Math.cos(rollRad) * horizHalfSpan;
            var hy1 = pitchOffset - Math.sin(rollRad) * horizHalfSpan;
            var hx2 = Math.cos(rollRad) * horizHalfSpan;
            var hy2 = pitchOffset + Math.sin(rollRad) * horizHalfSpan;

            rCtx.strokeStyle = 'rgba(255, 165, 63, 0.28)';
            rCtx.lineWidth = 1.5;
            rCtx.beginPath();
            rCtx.moveTo(hx1, hy1);
            rCtx.lineTo(hx2, hy2);
            rCtx.stroke();

            // Crosshair axes
            rCtx.strokeStyle = 'rgba(63, 63, 63, 0.5)';
            rCtx.lineWidth = 1;
            rCtx.beginPath();
            rCtx.moveTo(-radarRadius, 0);
            rCtx.lineTo(radarRadius, 0);
            rCtx.moveTo(0, -radarRadius);
            rCtx.lineTo(0, radarRadius);
            rCtx.stroke();

            // Ring labels
            rCtx.fillStyle = 'rgba(192, 192, 192, 0.75)';
            rCtx.font = '9px "Overpass Mono", "Noto Sans Mono", monospace';
            rCtx.textAlign = 'left';
            rCtx.textBaseline = 'bottom';
            rCtx.fillText('0.25g', -innerR * 0.707, innerR * 0.707);
            rCtx.fillText('0.5g', -radarRadius * 0.707, radarRadius * 0.707);

            // Compute ball coordinates (clamped inside radar circle)
            var scale = radarRadius / maxRadarG;
            var rawPx = gLat * scale;
            var rawPy = -gLon * scale; // Forward accel (+gLon) moves ball down/up consistently
            var dist = Math.sqrt(rawPx * rawPx + rawPy * rawPy);
            var maxDist = radarRadius - 5;
            var px = dist > maxDist ? (rawPx / dist) * maxDist : rawPx;
            var py = dist > maxDist ? (rawPy / dist) * maxDist : rawPy;

            // Historic trail
            trail.push([px, py]);
            if (trail.length > maxTrail) {
              trail.shift();
            }
            if (trail.length > 1) {
              rCtx.lineWidth = 2;
              for (var i = 1; i < trail.length; i++) {
                var alpha = (i / trail.length) * 0.65;
                rCtx.strokeStyle = 'rgba(255, 255, 255, ' + alpha.toFixed(2) + ')';
                rCtx.beginPath();
                rCtx.moveTo(trail[i - 1][0], trail[i - 1][1]);
                rCtx.lineTo(trail[i][0], trail[i][1]);
                rCtx.stroke();
              }
            }

            // "Water cup" ripple ring when Jerk (tranco) spikes
            if (jerkTotal > 0.45) {
              var rippleRadius = Math.min(24, 6 + (jerkTotal / 2.0) * 16);
              var rippleColor = zone === 'red'
                ? 'rgba(255, 67, 67, 0.65)'
                : (zone === 'amber' ? 'rgba(255, 165, 63, 0.6)' : 'rgba(168, 221, 115, 0.45)');
              rCtx.strokeStyle = rippleColor;
              rCtx.lineWidth = 1.8;
              rCtx.beginPath();
              rCtx.arc(px, py, rippleRadius, 0, 2 * Math.PI, false);
              rCtx.stroke();
            }

            // Main G-Ball
            var ballColor = '#a8dd73';
            if (zone === 'red') ballColor = '#ff4343';
            else if (zone === 'amber') ballColor = '#ff6600';

            rCtx.fillStyle = 'rgba(0, 0, 0, 0.9)';
            rCtx.beginPath();
            rCtx.arc(px, py, 6.5, 0, 2 * Math.PI, false);
            rCtx.fill();

            rCtx.fillStyle = ballColor;
            rCtx.beginPath();
            rCtx.arc(px, py, 4.8, 0, 2 * Math.PI, false);
            rCtx.fill();
          };

          // Setup Real-Time SmoothieChart for G-Force & Jerk
          var graphCanvas = element[0].querySelector('.sdc-graph-canvas');
          var chart = null;
          var gSeries = null;
          var jerkSeries = null;
          var thresholdSeries = null;

          if (typeof SmoothieChart !== 'undefined' && typeof TimeSeries !== 'undefined') {
            chart = new SmoothieChart({
              minValue: 0.0,
              maxValue: 1.0,
              millisPerPixel: 22,
              interpolation: 'linear',
              grid: {
                fillStyle: 'rgba(0, 0, 0, 0.43)',
                strokeStyle: 'rgba(63, 63, 63, 0.45)',
                verticalSections: 2,
                millisPerLine: 1000,
                sharpLines: true
              },
              labels: { disabled: true }
            });

            gSeries = new TimeSeries();
            jerkSeries = new TimeSeries();
            thresholdSeries = new TimeSeries();

            chart.addTimeSeries(thresholdSeries, {
              strokeStyle: 'rgba(192, 192, 192, 0.28)',
              lineWidth: 1
            });
            chart.addTimeSeries(gSeries, {
              strokeStyle: '#A8DD73',
              fillStyle: 'rgba(168, 221, 115, 0.08)',
              lineWidth: 2
            });
            chart.addTimeSeries(jerkSeries, {
              strokeStyle: '#FF6600',
              lineWidth: 2
            });

            chart.streamTo(graphCanvas, 40);
          }

          var syncGraphCanvasSize = function () {
            var wrap = element[0].querySelector('.sdc-graph-wrap');
            if (wrap && graphCanvas) {
              var rect = wrap.getBoundingClientRect();
              if (rect.width > 20 && rect.height > 20) {
                graphCanvas.width = Math.floor(rect.width);
                graphCanvas.height = Math.floor(rect.height);
              }
            }
          };

          setTimeout(syncGraphCanvasSize, 80);

          var formatSignedDeg = function (degVal) {
            var v = Number(degVal) || 0;
            var sign = v >= 0 ? '+' : '';
            return sign + v.toFixed(1) + '°';
          };

          var lastEventSeq = 0;

          // Listen to telemetry from smoothDrivingCoach.lua
          scope.$on('SmoothDrivingCoachData', function (event, data) {
            if (!data) return;

            var now = Date.now();
            var gHoriz = Number(data.gHoriz) || 0;
            var gLon = Number(data.gLon) || 0;
            var gLat = Number(data.gLat) || 0;
            var jerkTotal = Number(data.jerkTotal) || 0;
            var pitchDeg = Number(data.pitchDeg) || 0;
            var rollDeg = Number(data.rollDeg) || 0;
            var score = Number(data.score);
            if (isNaN(score)) score = 100;

            if (gSeries && jerkSeries && thresholdSeries) {
              // Normalize: 0.50g -> 1.0 on chart; 2.0 G/s jerk -> 1.0 on chart; 0.5 = green limit
              gSeries.append(now, Math.min(1.0, gHoriz / 0.50));
              jerkSeries.append(now, Math.min(1.0, jerkTotal / 2.0));
              thresholdSeries.append(now, 0.50);
            }

            drawRadar(gLat, gLon, jerkTotal, pitchDeg, rollDeg, data.zone || 'green');

            if (data.eventSeq && data.eventSeq !== lastEventSeq) {
              lastEventSeq = data.eventSeq;
              if (data.diagSeverity === 'red' || data.diagSeverity === 'amber') {
                playAlertBeep(data.diagSeverity);
              }
            }

            scope.$evalAsync(function () {
              scope.state.score = score;
              scope.state.scoreStr = Math.round(score).toString();
              scope.state.gHoriz = gHoriz;
              scope.state.gLon = gLon;
              scope.state.gLat = gLat;
              scope.state.gStr = gHoriz.toFixed(2) + 'g';
              scope.state.jerkTotal = jerkTotal;
              scope.state.jerkStr = jerkTotal.toFixed(1) + 'g/s';
              scope.state.pitchDeg = pitchDeg;
              scope.state.rollDeg = rollDeg;
              scope.state.pitchStr = formatSignedDeg(pitchDeg);
              scope.state.rollStr = formatSignedDeg(rollDeg);
              scope.state.zone = data.zone || 'green';
              scope.state.category = data.category || 'OK';
              scope.state.diagnosis = data.diagnosis || 'Condução suave';
              scope.state.diagSeverity = data.diagSeverity || 'green';
            });
          });

          // Initial radar draw
          drawRadar(0, 0, 0, 0, 0, 'green');

          scope.$on('VehicleFocusChanged', function () {
            ensureVehicleExtension();
          });

          scope.$on('VehicleReset', function () {
            ensureVehicleExtension();
          });

          scope.$on('app:resized', function () {
            syncGraphCanvasSize();
            drawRadar(
              scope.state.gLat,
              scope.state.gLon,
              scope.state.jerkTotal,
              scope.state.pitchDeg,
              scope.state.rollDeg,
              scope.state.zone
            );
          });

          scope.$on('$destroy', function () {
            StreamsManager.remove(streamsList);
            if (chart) {
              chart.stop();
            }
            if (audioCtx && audioCtx.close) {
              audioCtx.close();
            }
          });
        }
      };
    }]);
})();
