"""Resolve verified native mesh defaults beneath serialized template overrides."""
import copy
import hashlib
import json


ENGINE_PRIVATE = ('https://github.com/chenyong2github/UnrealEngine/blob/'
    'c865e168d0935b8e5f4bd865ddcc1c733c8ce7cf/Engine/Source/Runtime/Engine/Private/')


def resolve_native_mesh_component(component):
    """Only exact native classes with no remaining archetype can supply defaults."""
    kind = component.get('Type')
    if (kind not in ('StaticMeshComponent', 'InstancedStaticMeshComponent',
                     'HierarchicalInstancedStaticMeshComponent')
            or component.get('Class') != f"UScriptClass'{kind}'" or component.get('Template')):
        return component, None
    result = copy.deepcopy(component)
    props = result.setdefault('Properties', {})
    inherited = []
    # UStaticMeshComponent calls SetCollisionProfileName(BlockAllDynamic),
    # whose override also sets bUseDefaultCollision=false. ISM and HISM retain these.
    if 'bUseDefaultCollision' not in props:
        props['bUseDefaultCollision'] = False
        inherited.append('bUseDefaultCollision')
    body = props.setdefault('BodyInstance', {})
    if 'CollisionProfileName' not in body:
        body['CollisionProfileName'] = 'BlockAllDynamic'
        inherited.append('BodyInstance.CollisionProfileName')
    return result, dict(kind=f'native-UE5.3-{kind}', fields=inherited,
        sources=[ENGINE_PRIVATE+'Components/StaticMeshComponent.cpp#L164',
                 ENGINE_PRIVATE+'Components/StaticMeshComponent.cpp#L2295',
                 *([ENGINE_PRIVATE+'InstancedStaticMesh.cpp#L2306'] if kind != 'StaticMeshComponent' else []),
                 *([ENGINE_PRIVATE+'HierarchicalInstancedStaticMesh.cpp#L1923']
                   if kind == 'HierarchicalInstancedStaticMeshComponent' else [])])


def resolve_template(component, roots, _chain=()):
    """Read the exact serialized archetype; instance fields retain priority."""
    reference = component.get('Template', {})
    pointer = reference.get('ObjectPath', '')
    if not pointer.startswith('/Game/'):
        return component, []
    package, index = pointer.rsplit('.', 1)
    relative = package.removeprefix('/Game/') + '.json'
    path = next((root / relative for root in roots if (root / relative).exists()), None)
    if path is None:
        if _chain:
            raise ValueError('Nested collision template is missing')
        return component, []
    identity = (str(path.resolve()), int(index))
    if identity in _chain:
        raise ValueError('Cyclic collision template inheritance')
    data = path.read_bytes()
    template = json.loads(data)[int(index)]
    expected = reference['ObjectName'].split("'")[1].split(':')[-1]
    if template['Name'] != expected or template['Type'] != component['Type']:
        raise ValueError('Collision component template identity differs from its reference')
    template, native_defaults = resolve_native_mesh_component(template)
    template, parents = resolve_template(template, roots, (*_chain, identity))

    def merge(base, override):
        result = copy.deepcopy(base)
        for key, value in override.items():
            result[key] = merge(result[key], value) if isinstance(value, dict) and isinstance(result.get(key), dict) else copy.deepcopy(value)
        return result

    result = copy.deepcopy(component)
    result['Properties'] = merge(template.get('Properties', {}), component.get('Properties', {}))
    evidence = dict(path=str(path), sha256=hashlib.sha256(data).hexdigest(),
                    objectIndex=int(index), name=template['Name'])
    if native_defaults:
        evidence['nativeClassDefaults'] = native_defaults
    return result, [*parents, evidence]


def block_all_dynamic_evidence(body, root, verify_source):
    """Bind the named profile to the extracted 13.05 config, including edits."""
    if body.get('CollisionProfileName') != 'BlockAllDynamic':
        return None
    # This extraction records collision sections and whole-file hashes from
    # all five engine/project/Windows config layers. Ascent's fresh extraction
    # produces the same bytes as this earlier map-independent configuration.
    path = root/'icebox-all-collision-v1/collision-configuration.json'
    expected = '38dda0acecc932861f52e5845d1d9b694785738cd803a6d2fd3f3575ddb8b674'
    verify_source(str(path), expected)
    return dict(kind='Valorant-13.05-collision-profile', profile='BlockAllDynamic',
        channel='Pawn', response='ECR_Block', configuration=dict(path=str(path), sha256=expected),
        basis='DefaultEngine.ini lines 1003 and 1044 retain default Pawn blocking. The profile edits change Level, Death Reaction and Fluid only; Windows layers add no collision-profile override.')


def custom_pawn_default(body):
    """A serialized Custom response array stores differences from engine defaults."""
    responses = body.get('CollisionResponses', {}).get('ResponseArray')
    if (body.get('CollisionProfileName') != 'Custom' or not isinstance(responses, list)
            or any(row.get('Channel') == 'Pawn' for row in responses)):
        return None
    source = ('https://github.com/chenyong2github/UnrealEngine/blob/'
              'c865e168d0935b8e5f4bd865ddcc1c733c8ce7cf/Engine/Source/Runtime/Engine/Private/')
    # UpdateResponseContainerFromArray starts from GetDefaultResponseContainer.
    # CollisionProfile resets it to Block and only permits custom game channels
    # to change defaults. Pawn is a predefined engine channel.
    return dict(kind='native-UE5.3-custom-response-array', channel='Pawn', response='ECR_Block',
        sources=[source+'PhysicsEngine/BodyInstance.cpp#L259',
                 source+'Collision/CollisionProfile.cpp#L372'])

SOURCE = ('https://github.com/chenyong2github/UnrealEngine/blob/'
          'c865e168d0935b8e5f4bd865ddcc1c733c8ce7cf/'
          'Engine/Source/Runtime/Engine/Private/StaticMeshActor.cpp#L24')


def resolve_component(component, actor):
    root = actor.get('Properties', {}).get('RootComponent', {}).get('ObjectName', '')
    expected = f".{actor['Name']}.StaticMeshComponent0'" if actor.get('Name') else None
    if (actor.get('Type') != 'StaticMeshActor' or component.get('Type') != 'StaticMeshComponent'
            or component.get('Name') != 'StaticMeshComponent0'
            or not expected or not root.endswith(expected) or component.get('Template')):
        return component, None
    result = copy.deepcopy(component)
    props = result.setdefault('Properties', {})
    inherited = []
    if 'bUseDefaultCollision' not in props:
        props['bUseDefaultCollision'] = True
        inherited.append('bUseDefaultCollision')
    body = props.setdefault('BodyInstance', {})
    if 'CollisionProfileName' not in body:
        body['CollisionProfileName'] = 'BlockAll'
        inherited.append('BodyInstance.CollisionProfileName')
    return result, dict(kind='native-UE5.3-StaticMeshActor-root', fields=inherited, source=SOURCE)
