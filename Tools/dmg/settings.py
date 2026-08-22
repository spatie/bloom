# dmgbuild settings for the Bloom disk image. The artwork in background.html is
# composed for a 660x400 content area with both icons on a row at y 190, so the
# window size, the icon size and the icon locations below move together with
# the artwork or not at all. Tools/dmg/build.sh passes the defines.

files = [defines.get('app', 'Bloom.app')]
symlinks = {'Applications': '/Applications'}
badge_icon = None
background = defines.get('background', 'background.tiff')

# window_rect is the window FRAME, and the frame includes the title bar, which
# is 32pt here: on the mounted image the window reports 660x432 while its
# scroll area reports 660x400, measured through System Events. So a true 400pt
# content area needs a 432pt frame. With (660, 400), which looks like the
# obvious value, the content area was 368pt, Finder had 32pt of artwork it
# could not show, and the window scrolled. That scroll was reported as a fault
# once already, so do not "fix" this back to matching the artwork size.
window_rect = ((200, 140), (660, 432))

default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13

# Finder centres each label on its icon's x. With this icon size and text
# size, both labels render their text at y 268.5..279.5 in background
# coordinates, measured off a mounted retina screenshot with the two labels
# agreeing to the pixel, and the artwork's light shelf is centred on y 274
# from that measurement. Move this row and the shelf moves with it.
icon_locations = {
    'Bloom.app': (197, 190),
    'Applications': (463, 190),
    # dmgbuild copies the background image to the volume root, and a Mac set
    # to show hidden files draws it like any other item. An item whose cell
    # (about 210pt wide at this icon size) reaches outside the 660x400 view
    # makes the window scrollable, so the file is parked inside the view here,
    # and then postprocess.py moves it into .Trashes and deletes this entry
    # from the built .DS_Store. The entry exists so that dmgbuild's own layout
    # pass leaves nothing at a Finder chosen default position.
    '.background.tiff': (550, 64),
}

format = 'UDZO'

# This works, and the bit is genuinely set in the shipped image: dmgbuild runs
# SetFile -a E on the app inside the writable volume, and GetFileInfo -aE
# reports 1 after conversion. If a label still reads "Bloom.app" anyway, that
# machine has the global Finder preference to show all filename extensions
# (AppleShowAllExtensions = 1), which overrides the per file bit for every
# file on the system; a default Mac shows "Bloom". This was chased five times
# before it was measured, so measure the preference before touching the image.
hide_extension = ['Bloom.app']
