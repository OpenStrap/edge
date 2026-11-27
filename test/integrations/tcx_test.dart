import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/integrations/tcx.dart';
// ignore: depend_on_referenced_packages
import 'package:xml/xml.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 20, 7, 0, 0);
  test('HR-only workout: trackpoints with HR and no Position', () {
    final x = XmlDocument.parse(buildTcx(TcxActivity(
      sport: 'Other',
      start: t0,
      durationSec: 3,
      calories: 12,
      hr: [for (var i = 0; i < 3; i++) TcxHr(t0.add(Duration(seconds: i)), 100 + i)],
    )));
    expect(x.findAllElements('Activity').single.getAttribute('Sport'), 'Other');
    expect(x.findAllElements('Lap').length, 1);
    final pts = x.findAllElements('Trackpoint').toList();
    expect(pts.length, 3);
    expect(x.findAllElements('Position'), isEmpty);
    expect(pts.first.getElement('HeartRateBpm')!.getElement('Value')!.innerText, '100');
    expect(x.findAllElements('Time').first.innerText, '2026-11-20T07:00:00Z');
    expect(x.findAllElements('MaximumHeartRateBpm').single.innerText, '102');
  });

  test('GPS workout: position, altitude, nearest HR', () {
    final x = XmlDocument.parse(buildTcx(TcxActivity(
      sport: 'Running',
      start: t0,
      durationSec: 2,
      distanceM: 5.5,
      hr: [TcxHr(t0, 140)],
      gps: [TcxPoint(t0, 12.5, 77.5, 900), TcxPoint(t0.add(const Duration(seconds: 30)), 12.6, 77.6)],
    )));
    final pts = x.findAllElements('Trackpoint').toList();
    expect(pts.length, 2);
    expect(pts[0].findAllElements('LatitudeDegrees').single.innerText, '12.5');
    expect(pts[0].getElement('AltitudeMeters')!.innerText, '900.0');
    expect(pts[0].getElement('HeartRateBpm'), isNotNull);
    expect(pts[1].getElement('HeartRateBpm'), isNull);
    expect(x.findAllElements('DistanceMeters').single.innerText, '5.5');
  });

  test('sport mapping', () {
    expect(tcxSport('trail_running'), 'Running');
    expect(tcxSport('mountain_biking'), 'Biking');
    expect(tcxSport('yoga'), 'Other');
  });

  test('heart rate with no GPS fix stays in as HR-only points, in time order', () {
    final x = XmlDocument.parse(buildTcx(TcxActivity(
      sport: 'Running',
      start: t0,
      durationSec: 60,
      hr: [for (final s in [0, 20, 40]) TcxHr(t0.add(Duration(seconds: s)), 120 + s)],
      gps: [TcxPoint(t0, 12.5, 77.5)],
    )));
    final pts = x.findAllElements('Trackpoint').toList();
    expect(pts.length, 3);
    expect(pts[0].getElement('Position'), isNotNull);
    expect(pts[1].getElement('Position'), isNull);
    expect(pts[1].getElement('HeartRateBpm')!.getElement('Value')!.innerText, '140');
    expect(pts[2].getElement('Time')!.innerText, '2026-11-20T07:00:40Z');
  });

  test('indoor bike is Biking, and no Creator block is written', () {
    expect(tcxSport('indoor_bike'), 'Biking');
    expect(tcxSport('yoga'), 'Other');
    final x = XmlDocument.parse(
        buildTcx(TcxActivity(sport: 'Other', start: t0, durationSec: 1, hr: [TcxHr(t0, 90)])));
    expect(x.findAllElements('Creator'), isEmpty);
  });
}
