# Window layout for the DMG, read by dmgbuild (pip install dmgbuild).
# package.sh passes app=<path to the .app>.
import os

app = defines["app"]
name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

background = "builtin-arrow"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 120), (600, 380))
default_view = "icon-view"
icon_size = 112
text_size = 13
icon_locations = {name: (150, 190), "Applications": (450, 190)}
