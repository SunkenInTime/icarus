import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Path;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  final fixture=jsonDecode(File('test/fixtures/five_map_false_block_gaps_2026_09_14.json').readAsStringSync());
  final bundled=const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY');
  final root=bundled?null:Platform.environment['ICARUS_FALSE_BLOCK_MODELS'];
  for(final row in fixture['cases']) {
    for(final side in ['attack','defense']) {
      test('${row['id']} $side',(){
        final file=root==null?'assets/maps/${row['map']}_svg_height_$side.json.gz':'$root/${row['map']}/candidate-$side.json.gz';
        final model=SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(File(file).readAsBytesSync()))));
        final data=row['sides'][side];
        final origin=Offset((data['origin'][0] as num).toDouble(),(data['origin'][1] as num).toDouble());
        final target=Offset((data['target'][0] as num).toDouble(),(data['target'][1] as num).toDouble());
        final eye=(row['eyeMeters'] as num).toDouble();
        if(row['floorMeters']!=null) {
          expect(model.receiverContains(origin),isTrue);
          expect(model.receiverContains(target),isTrue);
          final support=model.supportForAbsoluteEyeElevation(origin,eye*100,toleranceCm:2);
          expect(support!=null||model.isGroundEyeElevation(origin,eye*100),isTrue,reason:'${row['id']} source standing level must resolve');
          final automatic=model.automaticSupportAt(origin);
          final automaticEye=automatic==null?model.groundEyeElevationAt(origin):(automatic.surfaceElevationAt(origin)!+model.defaultCameraHeightMeters);
          expect(automaticEye,closeTo(eye,.02),reason:'${row['id']} default level');
        }
        final delta=target-origin;final angle=math.atan2(delta.dy,delta.dx);
        final hit=model.castRay(origin:origin,directionRadians:angle,range:delta.distance,absoluteEyeElevationMeters:eye);
        expect(hit!=null,row['expectedBlocked'],reason:'${row['id']} ${hit?.wallId}');
        final cone=model.cone(origin:origin,directionRadians:angle,apertureRadians:math.pi/3,range:delta.distance+.2,absoluteEyeElevationMeters:eye);
        final visible=(cone.visibilityPath?.contains(target))??(Path()..addPolygon(cone.polygon,true)).contains(target);
        expect(visible,!(row['expectedBlocked'] as bool),reason:'${row['id']} projected wide cone');
      });
    }
  }
}
