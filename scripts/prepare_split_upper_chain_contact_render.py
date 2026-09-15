"""Freeze the existing actual-SVG contact renderer for the new upper chain."""
from pathlib import Path
template=Path('scripts/render_split_vent_room_receiver_contacts.py');code=template.read_text()
code=code.replace('split-vent-room-receiver-contacts-native8x-v4','split-upper-vent-chain-contacts-native8x-v1').replace('split-vent-room-composed-standing-rays-v5','split-room-upper-chain-standing-rays-v2').replace('split-vent-room-raw-partition-v3','split-room-upper-chain-combined-raw-v2')
start=code.index('    cases=[');end=code.index('    for name,index,box in cases:',start)
code=code[:start]+'''    cases=[('172-middle',403,[286,165,296,175]),
        ('172-right-return',415,[294,165,302,174]),
        ('169-top',416,[278,99,287,106]),
        ('169-frame',426,[278,106,287,113]),
        ('169-170-corner',486,[278,136,289,145]),
        ('170-middle',500,[286,135,295,145]),
        ('170-171-corner',511,[294,135,303,145]),
        ('171-elevator-panel',516,[295,143,306,151]),
        ('171-wall-poster',520,[295,154,306,162]),
        ('171-172-corner',533,[295,164,306,173])]
'''+code[end:]
target=Path('scripts/render_split_upper_chain_contacts.py');assert not target.exists();target.write_text(code);print(str(target))
