import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
void main(){test('inspect reported spawn visibility and neighboring floors',(){
 final m=SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(File('assets/maps/fracture_svg_height_attack.json.gz').readAsBytesSync()))));
 final registration=jsonDecode(File('work/fracture-spawn-review-2026-09-14/registration.json').readAsStringSync());
 final points=(registration['points'] as Map).map((k,v)=>MapEntry(k.toString(),Offset((v[0] as num).toDouble(),(v[1] as num).toDouble())));
 final origin=points['observer']!;final support=m.automaticSupportAt(origin);
 final rows=<Map<String,dynamic>>[];
 for(final entry in points.entries){final p=entry.value;final s=m.automaticSupportAt(p);final delta=p-origin;
 final hit=delta.distance==0?null:m.castRay(origin:origin,directionRadians:math.atan2(delta.dy,delta.dx),range:delta.distance,supportId:support?.id);
 rows.add({'name':entry.key,'svg':[p.dx,p.dy],'receiver':m.receiverContains(p),'support':s?.id,'floor':s?.surfaceElevationAt(p),'groundEye':m.groundEyeElevationAt(p),'choices':[for(final c in m.supportsAt(p)){'id':c.id,'floor':c.surfaceElevationAt(p),'automatic':c.automaticStandingAllowed}],'hit':hit==null?null:{'wallId':hit.wallId,'distance':hit.distance}});
 }
 final cones=<Map<String,dynamic>>[];
 for(final degree in [95.0,97.0,100.0,105.0]){final c=m.cone(origin:origin,directionRadians:degree*math.pi/180,apertureRadians:103*math.pi/180,range:200,supportId:support?.id);cones.add({'degrees':degree,'eye':c.eyeElevationMeters,'polygon':[for(final p in c.polygon)[p.dx,p.dy]]});}
 File('work/fracture-spawn-review-2026-09-14/runtime-before.json').writeAsStringSync(jsonEncode({'points':rows,'cones':cones}));
 print(jsonEncode(rows));
});}
