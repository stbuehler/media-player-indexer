indexer for media-player-web
============================

Builds a json db for a media library (see <https://github.com/stbuehler/media-player-web>)

Copy config.yaml.example to config.yaml and edit it.

You can have as many sources as you want.
For each source you need the local path (can be mounted with sshfs too) and the
path the file will be reachable in the webbrowser with (relative to the index.html
of the media-player-web or absolute).

By default it uses a sqlite3 database (which should be good enough for this).


Use "bundle" to install the needed gem dependencies.
