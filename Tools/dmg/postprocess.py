"""Hides the background image from the icon view, after dmgbuild has finished.

Run against the mount point of the writable image, before it is converted back
to read only:

    postprocess.py /Volumes/Bloom

Finder on a default Mac hides dot files, so .background.tiff at the volume
root is invisible there. A Mac set to show hidden files draws it as a greyed
item in the middle of the artwork, and every ordinary way of hiding a file was
tried on such a Mac and failed: a dot prefix, chflags hidden, and the legacy
Icon file name with its trailing carriage return were all drawn. The one name
Finder refuses to draw either way is .Trashes, so the image lives inside a
.Trashes folder and the view's background alias is rewritten to point there.
The alias is rebuilt rather than edited because it encodes the volume and path
it was created from.

The Iloc entry for the old root path is deleted as well. An item position
whose cell reaches outside the 660x400 view makes the window scrollable, and a
stale entry for a file that no longer exists is a trap for whoever measures
that next.
"""

import os
import shutil
import sys

from ds_store import DSStore
from mac_alias import Alias

volume = sys.argv[1]
os.makedirs(os.path.join(volume, '.Trashes'), exist_ok=True)
shutil.move(
    os.path.join(volume, '.background.tiff'),
    os.path.join(volume, '.Trashes', 'background.tiff'),
)

with DSStore.open(os.path.join(volume, '.DS_Store'), 'r+') as store:
    icvp = store['.']['icvp']
    icvp['backgroundImageAlias'] = Alias.for_file(
        os.path.join(volume, '.Trashes', 'background.tiff')
    ).to_bytes()
    store['.']['icvp'] = icvp
    del store['.background.tiff']['Iloc']
