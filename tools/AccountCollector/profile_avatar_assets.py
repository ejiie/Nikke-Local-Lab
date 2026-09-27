"""Blablalink getAvatar: icon ID -> resource/costume -> official small face artwork."""
import json
from pathlib import Path
from presentation_assets import download,normal_resource_uri,atomic,json_write,digest,PNG

def prepare(icon_id,output):
    if type(icon_id) is not int or icon_id<=0:raise ValueError('Invalid profile icon ID')
    output=Path(output)
    mapping=output/'catalog/character-avatar-map.json'
    logical='character/character_avatar_map.json'
    data=mapping.read_bytes() if mapping.exists() else download(normal_resource_uri(logical))
    rows=json.loads(data)
    row=next((r for r in rows if r['id']==icon_id),None)
    if row is None:
        data=download(normal_resource_uri(logical));rows=json.loads(data)
        row=next((r for r in rows if r['id']==icon_id),None)
    if row is None:raise ValueError('Unknown profile icon ID')
    atomic(mapping,data)
    resource,costume=int(row['resource_id']),int(row['costume_index'])
    url=normal_resource_uri(f'character/si/si_c{resource:03}_{costume:02}_s.png')
    relative=f'assets/account-avatars/{icon_id}.png'
    target=output/relative
    image=target.read_bytes() if target.exists() else download(url)
    if not image.startswith(PNG):raise ValueError('Invalid profile artwork')
    atomic(target,image)
    receipt=dict(iconId=icon_id,resourceId=resource,costumeIndex=costume,path='/editor/'+relative,
        url=url,sha256=digest(image),mappingUrl=normal_resource_uri(logical),mappingSha256=digest(data))
    json_write(output/f'catalog/account-avatar-{icon_id}.json',receipt)
    return receipt['path']
