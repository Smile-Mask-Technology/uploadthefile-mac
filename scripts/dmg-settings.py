# dmgbuild settings for UploadTheFile.dmg (scripts/make-dmg.sh runs dmgbuild from the repository
# root with these). The window shows two items, the app on the left and the Applications folder on
# the right, over a light background picture; the licences ship inside the app.
#
# `defines` holds the -D values dmgbuild was given: app = the .app folder to put in the image.

# The disk image holds exactly these two items.
files = [(defines.get("app", "build/Upload the File.app"), "Upload the File.app")]
symlinks = {"Applications": "/Applications"}

# The volume's own icon.
icon = "Resources/AppIcon.icns"

# dmgbuild also finds Resources/DMG/background@2x.png next to this file and joins both into one
# multi-resolution picture. The picture stays light because Finder draws icon labels in black
# over a background picture, in Dark Mode too.
background = "Resources/DMG/background.png"

# 600 x 380 points below the title bar, which Finder counts in the window's height.
window_rect = ((200, 120), (600, 380 + 28))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
# Icon centres, in points from the top left of the window's content area.
icon_locations = {"Upload the File.app": (160, 180), "Applications": (440, 180)}
hide_extensions = ["Upload the File.app"]

format = "ULFO"
filesystem = "HFS+"
