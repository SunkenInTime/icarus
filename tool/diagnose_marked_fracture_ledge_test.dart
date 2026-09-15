import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
void main(){test('inspect marked screenshot observers',(){
 final m=SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(File('assets/maps/fracture_svg_height_attack.json.gz').readAsBytesSync()))));
 for(final p in [const Offset(300.156137,395.039829),const Offset(265.480526,313.927283),const Offset(286.532634,309.593025),const Offset(338.794115,270.926966),const Offset(324.834613,295.896976)]){
 final s=m.automaticSupportAt(p); print({'point':p.toString(),'receiver':m.receiverContains(p),'support':s?.id,'floor':s?.surfaceElevationAt(p)});
 }
 for(final target in [const Offset(280,290),const Offset(277,287),const Offset(294,260)]){
 const o=Offset(292.740602,309.493985);final d=target-o;final hit=m.castRay(origin:o,directionRadians:math.atan2(d.dy,d.dx),range:d.distance,supportId:m.automaticSupportAt(o)?.id);print({'solidTarget':target.toString(),'hit':hit?.wallId});
 }

});}
