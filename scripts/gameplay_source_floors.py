"""Identify render floors explicitly used as player complex collision."""
from functools import lru_cache
import hashlib
from pathlib import Path
import re
from audit_all_map_gameplay_levels import ROOT, read
from audit_floor_pawn_support import classify_support
from native_collision_defaults import (resolve_component, resolve_template, custom_pawn_default,
    resolve_native_mesh_component, block_all_dynamic_evidence)
from cooked_collision_evidence import no_simple_collision
from native_supplement_placement import supplement_placement


class SourceFloors:
    def __init__(self,name):
        self.name = name
        metadata=read(ROOT/f'supplemented-v2/world/{name}/geometry.json')
        self.objects=metadata['objects']
        audit=read(ROOT/f'native-material-audit/world/{name}/native-slot-audit.json')
        if metadata['baseGeometrySha256'] != audit['candidateGeometrySha256']:
            raise ValueError('Source geometry is not the audited native candidate')
        # Repeated instances can share a path. The audited face range identifies
        # the placed object, including the exporter's numeric name suffix.
        self.placements={r['firstFace']:r for r in audit['placements']}
        if len(self.placements) != len(audit['placements']):
            raise ValueError('Duplicate native placement face range')
        self.roots=[ROOT/f'native-material-audit/{folder}/properties/ShooterGame/Content' for folder in ['mesh-export','extra-mesh-export','inherited-mesh-export']]
        self.roots.append(ROOT/'completeness/supplement-native-mesh-export/properties/ShooterGame/Content')

    @lru_cache(maxsize=32)
    def level(self,path):
        return read(Path(path))

    @lru_cache(maxsize=4096)
    def placement(self, oid):
        obj = self.objects[oid]
        placement = self.placements.get(obj['firstFace'])
        if placement is None:
            placement = supplement_placement(obj, self.level, self.verify_source,
                self.template_roots())
        if placement is not None and any(placement[k] != obj[k] for k in ['path', 'faceCount']):
            raise ValueError('Native placement does not match the source object')
        return placement

    def template_roots(self):
        return [ROOT/f'{self.name}-native-instance-transforms-v1/properties/ShooterGame/Content',
            ROOT/f'{self.name}-native-template-parents-v1/properties/ShooterGame/Content',
            ROOT/'icebox-expanded-templates-v1/properties/ShooterGame/Content',
            ROOT/'tactical-visibility-revision/floor-support-effect-export-v1/properties/ShooterGame/Content']

    @lru_cache(maxsize=1024)
    def verify_source(self, path, expected):
        if expected and hashlib.sha256(Path(path).read_bytes()).hexdigest() != expected:
            raise ValueError('Native source changed after placement verification')

    @lru_cache(maxsize=4096)
    def object(self,oid):
        obj=self.objects[oid]
        placement=self.placement(oid)
        path=re.sub(r'\.\d+$','',obj['path']).lstrip('/')
        if placement is None:
            level_name,label,component_name=path.split('/')
            levelpath=ROOT/f'native-material-audit/resolved-component-export/properties/ShooterGame/Content/Maps/{level_name.split("_")[0]}/{level_name}.json'
            if not levelpath.exists():
                from gameplay_standing_volumes import package_path
                levelpath=package_path(f'/Game/Maps/{level_name.split("_")[0]}/{level_name}') or levelpath
            if not levelpath.exists():return dict(classification='unresolved-native-level')
            level=self.level(str(levelpath))
            actors=[r for r in level if re.sub(r'[^A-Za-z0-9_]','_',r.get('ActorLabel',r['Name']))==label and 'Component' not in r['Type']]
            if len(actors)!=1:return dict(classification='unresolved-native-actor')
            actor=actors[0]
            components=[(i,r) for i,r in enumerate(level) if r['Name']==component_name and f"PersistentLevel.{actor['Name']}'" in str(r.get('Outer'))]
            if len(components)!=1:return dict(classification='unresolved-native-component')
            index,component=components[0]
            mesh=component.get('Properties',{}).get('StaticMesh',{}).get('ObjectPath')
            if mesh is None:return dict(classification='unresolved-inherited-mesh')
            placement=dict(nativeLevel=str(levelpath),nativeComponentIndex=index,nativeActor=actor['Name'],nativeMesh=mesh.split('.')[0])
        self.verify_source(placement['nativeLevel'], placement.get('nativeLevelSha256'))
        level=self.level(placement['nativeLevel'])
        component=level[placement['nativeComponentIndex']]
        actor=next(r for r in level if r['Name']==placement['nativeActor'])
        component,template_evidence=resolve_template(component, self.template_roots())
        component,default_evidence=resolve_component(component,actor)
        if default_evidence is None and actor.get('Type') == 'Actor':
            component,default_evidence=resolve_native_mesh_component(component)
        engine_mesh = placement['nativeMesh'].startswith('/Engine/')
        relative=placement['nativeMesh'].removeprefix('/Engine/' if engine_mesh else '/Game/')+'.json'
        roots = [r.parent.parent / 'Engine/Content' for r in self.roots] if engine_mesh else self.roots
        meshpath=next((root/relative for root in roots if (root/relative).exists()),None)
        if meshpath is None:
            from gameplay_standing_volumes import package_path
            meshpath=package_path(placement['nativeMesh'])
        if meshpath is None:
            classification,basis,effective=classify_support(component,{},actor)
            return dict(classification=classification if classification.startswith('excluded') else 'unresolved-native-mesh')
        self.verify_source(str(meshpath), placement.get('nativeMeshSha256'))
        mesh=read(meshpath)
        bodies=[r for r in mesh if r['Type']=='BodySetup']
        if len(bodies)!=1:return dict(classification='unresolved-native-body')
        body=bodies[0].get('Properties',{})
        classification,basis,effective=classify_support(component,body,actor)
        simple_evidence=no_simple_collision(ROOT, meshpath, body,
            additional_exports=[ROOT/f'{self.name}-all-collision-v2', ROOT/f'{self.name}-all-collision-v1'])
        if simple_evidence is not None:
            classification='excluded-no-simple-player-shape'
        effective=effective or {}
        unwalkable=effective.get('WalkableSlopeOverride',{}).get('WalkableSlopeBehavior','').endswith('WalkableSlope_Unwalkable')
        meshobject=next(r for r in mesh if r['Type']=='StaticMesh')
        sections=meshobject.get('RenderData',{}).get('LODs',[{}])[0].get('Sections',[])
        return dict(classification=classification,unwalkable=unwalkable,basis=basis,
            sections=sections,nativeLevel=placement['nativeLevel'],nativeMesh=str(meshpath),
            nativeActor=placement['nativeActor'], nativeComponentIndex=placement['nativeComponentIndex'],
            sourcePrim=placement.get('sourcePrim'), sourceInstance=placement.get('sourceInstance'),
            bodySetup=body, effectiveBody=effective,
            nativeDefaultEvidence=default_evidence,
            nativePawnResponseEvidence=(custom_pawn_default(effective) or
                block_all_dynamic_evidence(effective, ROOT, self.verify_source)),
            templateEvidence=template_evidence,
            simpleCollisionEvidence=simple_evidence,
            cookedDataMetadata=bodies[0].get('CookedFormatData', {}))

    def face(self,oid,face):
        result=dict(self.object(oid))
        local=face-self.objects[oid]['firstFace']
        section=next((s for s in result.pop('sections',[]) if s['FirstIndex']//3<=local<s['FirstIndex']//3+s['NumTriangles']),None)
        result['physicalFloorConfirmed']=result['classification']=='declared-pawn-blocking-complex' and section is not None and section.get('bEnableCollision') is True
        return result
