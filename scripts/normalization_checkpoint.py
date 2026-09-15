"""Immutable generated geometry checkpoints, resumed through the same pack gate."""
import hashlib,json
from pathlib import Path
import numpy as np


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def save_checkpoint(out,source_path,warp_path,families,arrays,counts,certificates):
    out=Path(out);data_path=out.with_name(out.name+'-prepack-geometry.npz');meta_path=out.with_name(out.name+'-prepack-geometry.json')
    if data_path.exists() or meta_path.exists():raise FileExistsError(meta_path)
    assert all(np.asarray(value).dtype.kind!='O' for value in arrays.values())
    np.savez_compressed(data_path,**arrays)
    scripts=Path(__file__).parent
    generators=['build_split_normalized_wall_families.py','authored_region_cells.py','authored_wall_profile_cells.py','region_partition_certificate.py','finite_region_cells.py','finite_edge_owners.py','native_region_source.py','normalization_checkpoint.py']
    metadata=dict(format='icarus-normalized-wall-prepack-checkpoint-v1',candidateOutput=str(out),sourcePack=str(source_path),sourcePackSha256=sha(source_path),displayWarp=str(warp_path),displayWarpSha256=sha(warp_path),arrayFile=str(data_path),arraySha256=sha(data_path),generatorHashes={name:sha(scripts/name) for name in generators},families=families,familyDeclarationSha256=hashlib.sha256(json.dumps(families,sort_keys=True,separators=(',',':')).encode()).hexdigest(),counts=counts,sourceContainmentArithmeticCertificates=certificates,policy='Generated geometry/provenance only. Resumption must execute the same exact source-partition gate and pack writer; this checkpoint is not an accepted candidate.')
    meta_path.write_text(json.dumps(metadata,indent=2))
    return dict(metadataFile=str(meta_path),metadataSha256=sha(meta_path),arrayFile=str(data_path),arraySha256=metadata['arraySha256'])

def load_checkpoint(meta_path):
    meta_path=Path(meta_path);metadata=json.loads(meta_path.read_text());assert metadata['format']=='icarus-normalized-wall-prepack-checkpoint-v1'
    assert sha(metadata['arrayFile'])==metadata['arraySha256'];assert sha(metadata['sourcePack'])==metadata['sourcePackSha256'];assert sha(metadata['displayWarp'])==metadata['displayWarpSha256']
    assert hashlib.sha256(json.dumps(metadata['families'],sort_keys=True,separators=(',',':')).encode()).hexdigest()==metadata['familyDeclarationSha256']
    for name,digest in metadata['generatorHashes'].items():assert sha(Path(__file__).parent/name)==digest,('Generating helper changed',name)
    arrays=dict(np.load(metadata['arrayFile'],allow_pickle=False));binding=dict(metadataFile=str(meta_path),metadataSha256=sha(meta_path),arrayFile=metadata['arrayFile'],arraySha256=metadata['arraySha256'])
    return metadata,arrays,binding
